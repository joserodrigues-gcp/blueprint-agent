# blueprint-agent

A reference implementation of a [Google ADK](https://adk.dev/) agent deployed to **Agent
Runtime**, part of the [Gemini Enterprise Agent
Platform](https://cloud.google.com/products/gemini-enterprise-agent-platform). Generated with
`agents-cli` 1.4.0 and then made deliberate.

The agent logic is intentionally trivial — two stub tools behind a single Gemini model.
Everything worth copying is around it.

## What this repo demonstrates

| Pattern | Where |
|---------|-------|
| One FastAPI process serving the ADK web UI, A2A, and the `reasoning_engine` contract — all sharing a single session store | `blueprint_agent/fast_api_app.py`, `app_utils/services.py` |
| An A2A agent card that stays consumable by v0.3 clients (Gemini Enterprise registration) while serving v1.0 | `app_utils/a2a.py` |
| Serving the `{class_method, input}` contract by hand, so the console playground works against a container-built engine | `app_utils/reasoning_engine_adapter.py` |
| Message content routed to GCS and joined back to Cloud Logging metadata in BigQuery, never captured in spans | `deployment/terraform/single-project/telemetry.tf` |
| Terraform creating the engine, then deliberately not reconciling it, so deploys don't fight `apply` | `deployment/terraform/single-project/service.tf` |
| `.env` tracked in git, because deploy treats it as the declared source for the engine's environment | [Configuration](#configuration) |

## Repository layout

```
blueprint-agent/
├── blueprint_agent/
│   ├── agent.py                          # Model, instruction, and tools
│   ├── fast_api_app.py                   # Server entry point; wires every serving surface
│   └── app_utils/
│       ├── a2a.py                        # A2A agent card and JSON-RPC routes
│       ├── reasoning_engine_adapter.py   # Console playground / Gemini Enterprise contract
│       └── services.py                   # Process-wide session and artifact services
├── deployment/terraform/
│   ├── single-project/                   # APIs, IAM, bucket, engine, telemetry pipeline
│   └── shared/                           # Placeholder archive, log schema, completions SQL
├── tests/
│   ├── unit/                             # Fast, no cloud calls
│   ├── integration/                      # Agent invocation and full server end-to-end
│   └── eval/                             # Dataset, metrics, and LLM-as-judge config
├── Dockerfile                            # What Agent Runtime builds
├── .env                                  # Tracked on purpose — see Configuration
├── agents-cli-manifest.yaml              # Scaffold decisions
└── AGENTS.md                             # Guidance for coding agents working in this repo
```

## Getting started

Needs [uv](https://docs.astral.sh/uv/getting-started/installation/), the [Google Cloud
SDK](https://cloud.google.com/sdk/docs/install) with application default credentials
(`gcloud auth application-default login`), and Terraform ≥ 1.0 for the infrastructure.

```bash
uvx google-agents-cli setup     # install agents-cli and its skills, if needed
agents-cli install              # sync dependencies into .venv
agents-cli playground           # local server with the ADK web UI, auto-reloads on save
```

Point `.env` at your own project first — `GOOGLE_CLOUD_PROJECT` is the one value that must
change when cloning this repo. Add packages with `uv add <package>`; ADK's own CLI is available
as `uv run adk` for anything `agents-cli` doesn't wrap.

## The agent

`blueprint_agent/agent.py` defines a single `Agent` with two simulated tools, `get_weather` and
`get_current_time`, wrapped in an `App` named `blueprint_agent`. The model comes from the
`MODEL` environment variable, defaulting to `gemini-3.5-flash-lite`, with three retry attempts
configured on the client.

The `App` name is load-bearing: it becomes the A2A route (`/a2a/blueprint_agent`) and the app
identifier in ADK's session store. Renaming it means updating the manifest, `pyproject.toml`,
the `Dockerfile`, and the tests together.

## Serving surfaces

`fast_api_app.py` builds one FastAPI application and attaches every protocol to it, so a single
container answers all of them on port 8080.

| Surface | Endpoints | Client |
|---------|-----------|--------|
| ADK web UI and REST | `/dev-ui/`, `/run_sse`, `/apps/...` | `agents-cli playground`, direct HTTP callers |
| A2A | `/a2a/blueprint_agent`, card at `/a2a/blueprint_agent/.well-known/agent-card.json` | Other agents; Gemini Enterprise A2A registration |
| `reasoning_engine` | `/api/reasoning_engine`, `/api/stream_reasoning_engine` | Agent Platform console playground; Gemini Enterprise via ADK registration |

All three share one session service and one artifact service, registered under a `shared://`
URI scheme in `app_utils/services.py`. A conversation started through any surface is visible
from the others.

Both services choose their backing store from the environment at startup:

- **Sessions** — `SESSION_SERVICE_URI` if set; otherwise Agent Platform managed sessions
  (`VertexAiSessionService`) when `GOOGLE_CLOUD_AGENT_ENGINE_ID` is present; otherwise in-memory.
- **Artifacts** — GCS when `LOGS_BUCKET_NAME` is set (Terraform sets it on the engine);
  otherwise in-memory.

So the same code runs locally with no cloud dependencies and on Agent Runtime with managed
persistence, without a branch in the agent itself.

## Testing and evaluation

```bash
uv run pytest tests/unit tests/integration    # unit and integration
agents-cli lint                               # ruff check, ruff format, codespell, ty
agents-cli eval run                           # run the eval dataset and grade the traces
```

`tests/eval/` holds the dataset (`datasets/basic-dataset.json`), the metric configuration
(`eval_config.yaml`), and a local LLM-as-judge (`response_quality.py`). The judge model is
configured separately from the agent model, via `JUDGE_MODEL` — a grader that moves with the
agent makes scores incomparable across runs. `agents-cli eval --help` lists the rest of the
loop: `compare` for regression diffs, `analyze` for failure clustering, `optimize` for prompt
tuning.

The end-to-end tests start a real server on port 8000; they fail as `Server failed to start` if
something else holds it. The eval dataset is still the generator's three scaffold cases, so it
exercises the pipeline rather than grading this agent.

## Deployment

```bash
gcloud config set project <your-project-id>
agents-cli deploy
```

Deployment is produced by two independent mechanisms that do not coordinate with each other:

| Mechanism | Command | Creates |
|-----------|---------|---------|
| **Terraform** — provisions the surrounding infrastructure | `terraform apply -var-file=vars/env.tfvars` in `deployment/terraform/single-project/` | Enabled APIs, the application service account and its roles, the logs bucket, the BigQuery telemetry pipeline, and the Agent Runtime engine itself — initially holding a placeholder source archive (`deployment/terraform/shared/dummy_source.b64`) |
| **`agents-cli deploy`** — ships the agent code | `agents-cli deploy` | Packages the working tree, builds `Dockerfile` via Cloud Build, and replaces the engine's source and image |

The two do not conflict because `service.tf` declares
`lifecycle { ignore_changes = [spec[0].container_spec, spec[0].source_code_spec, spec[0].deployment_spec] }`
on the engine. After creation, Terraform no longer reconciles the engine's contents, so a
subsequent `terraform apply` will not revert a deployed agent to the placeholder source.

**Whichever mechanism creates the engine first determines its machine shape**, and the other's
values are never applied — see [Settings that cannot be
changed](#settings-that-cannot-be-changed-after-the-engine-is-created).

Deploy packages the working tree using `.gcloudignore` if present, falling back to
`.gitignore`. A file the container needs but git ignores will be missing from the build.

## Configuration

Settings are distributed across four layers, each owning a distinct concern. **Identify the
owning layer before changing a value** — editing the wrong layer has no effect and reports no
error.

| Layer | Owns | Takes effect |
|-------|------|--------------|
| [`agents-cli-manifest.yaml`](agents-cli-manifest.yaml) | Scaffold decisions: deployment target, A2A, session type, region | When `agents-cli` regenerates project files |
| [`deployment/terraform/single-project/vars/env.tfvars`](deployment/terraform/single-project/vars/env.tfvars) | Target project, region, and the naming prefix for every provisioned resource | On `terraform apply` |
| [`.env`](.env) | Agent runtime behaviour (model, backend, location) | Locally on import; on the engine at each `agents-cli deploy` |
| `agents-cli deploy` flags | Machine shape, identity, and networking of the deployed engine | Per invocation only — not persisted |

### 1. `agents-cli-manifest.yaml` — scaffold state

Records what the scaffold generated: `deployment_target: agent_runtime`, `is_a2a: true`,
`session_type: in_memory`, `region`, and the CLI version the project was generated against.
It is read by `agents-cli`, not by Google Cloud.

Change these by re-running `agents-cli scaffold enhance` with the corresponding flags rather
than editing the file, so that the generated files and the manifest stay consistent.

### 2. `vars/env.tfvars` — infrastructure identity

Three values drive everything Terraform creates:

| Variable | Current value | Scope |
|----------|---------------|-------|
| `project_id` | `tim-platform-lab` | Target Google Cloud project |
| `region` | `us-central1` | Region for the bucket, dataset, connection, and engine |
| `project_name` | `blueprint-agent` | Naming prefix for the service account, logs bucket, BigQuery dataset, log sink, and the engine's display name |

Changing `project_name` does not rename resources — it provisions a parallel set under new
names, and the engine's display name is also what `agents-cli deploy` matches on to decide
between create and update.

> **Note:** the scaffold defaulted `region` to `us-east1` in `variables.tf`, contradicting this
> file and the manifest. That default is reachable whenever no `-var-file` is passed — which is
> what `agents-cli infra single-project` does — so it is removed rather than corrected: `region`
> now behaves like `project_id`, supplied or refused, never guessed.

### 3. `.env` — agent runtime behaviour

`.env` is tracked rather than ignored, because it serves two roles: local configuration, and the
declared source for the deployed engine's environment. Secrets belong in `.env.secrets`, which
stays untracked and local — notably `GOOGLE_APPLICATION_CREDENTIALS`, which must not ride along
to an engine that has its own service account.

| Key | Purpose |
|-----|---------|
| `GOOGLE_CLOUD_PROJECT` | Project for local runs. Stripped before deploy — Agent Runtime reserves it and injects its own |
| `GOOGLE_CLOUD_LOCATION` | Model endpoint (`global`), **not** the engine's region |
| `GOOGLE_GENAI_USE_ENTERPRISE` | Routes the model call through Agent Platform rather than the Gemini Developer API. Supersedes `GOOGLE_GENAI_USE_VERTEXAI` |
| `MODEL` | Agent model, read by `blueprint_agent/agent.py` |
| `JUDGE_MODEL` | LLM-as-judge model for `agents-cli eval`, read by `tests/eval/response_quality.py` |

**Environment variables are merged, never replaced.** Precedence, highest first:

```
--secrets  >  --update-env-vars  >  .env  >  values already on the deployed engine
```

Because the engine's existing values form the lowest layer, **removing a key from `.env` does
not remove it from a deployed engine** — the previous value persists until a REST `PATCH`
clears it. Tracking `.env` in git is what makes this merge-only channel reviewable.

**The eleven telemetry keys live in `service.tf`'s `deployment_spec.env`**, which is create-only
— editing one there later reports `0 to change`. That merge is what keeps them reachable: **to
change one on a running engine, add that single key to `.env` and redeploy**, or pass
`--update-env-vars` for a one-off. Two of them also change local behaviour, since `.env`
configures both: `GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY` gates `otel_to_cloud` in
`fast_api_app.py:41`, and `OTEL_INSTRUMENTATION_GENAI_COMPLETION_HOOK` without its
bucket-derived base path makes every local run log `…UPLOAD_BASE_PATH is required but not set`.

`agents-cli deploy` also supplies overridable defaults when the corresponding keys are absent:
`AGENT_VERSION` (from `pyproject.toml`), `GOOGLE_GENAI_USE_VERTEXAI=true`,
`GOOGLE_CLOUD_LOCATION=global`, `GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY=true`,
`OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=NO_CONTENT`, and
`ADK_CAPTURE_MESSAGE_CONTENT_IN_SPANS=false`.

The deprecated spelling there, and in `service.tf`, is left alone deliberately: the engine ends
up with both names set to true, readers prefer the new one, and a warning fires only if the two
*disagree*. Renaming would change nothing and cost a divergence.

### 4. `agents-cli deploy` flags — deployed engine shape

These are the only way to change CPU, memory, or scaling on an existing engine, since Terraform
stops reconciling `deployment_spec` after creation. They are not persisted anywhere: re-pass
any flag whose value you want to keep.

| Flag | Default on create | Effect |
|------|-------------------|--------|
| `--cpu` / `--memory` | `1` / `4Gi` | Per-instance size. On redeploy, omitting **both** preserves the live values; supplying one fills the other from the live spec |
| `--min-instances` / `--max-instances` | `1` / `10` | Scaling floor and ceiling. A floor of 1 keeps an instance warm, and billable, while idle |
| `--concurrency` | `8` | Simultaneous requests served per instance |
| `--service-account` | — | Identity the engine runs as. Terraform provisions `blueprint-agent-app@…` for this purpose |
| `--update-env-vars` | — | `KEY=VALUE,KEY=VALUE`; overrides `.env` |
| `--secrets` | — | `ENV=SECRET` or `ENV=SECRET:VERSION` from Secret Manager; highest precedence |
| `--service-name` | `blueprint-agent` | Display name to match on. A new name creates a separate engine rather than updating this one |
| `--region` | `us-central1` | Must be a real region; `global` is rejected for Agent Runtime |
| `--build-args` | — | `KEY=VALUE` pairs passed to the image build. `Dockerfile` accepts `AGENT_VERSION` |
| `--network-attachment`, `--dns-peering-domain`, `--dns-peering-project`, `--dns-peering-network` | — | Private Service Connect into a VPC, with optional DNS peering |
| `--dry-run`, `--no-wait`, `--status`, `--list` | off | Preview the request, return before completion, poll a pending deploy, enumerate deployments |

### Settings that cannot be changed after the engine is created

Decide these before the first deploy; adopting one later means a new engine under a different
`--service-name`.

- **`--agent-identity`** (certificate-bound tokens) and **`--agent-gateway-egress` /
  `--agent-gateway-ingress`** (binding an existing gateway, whose root CA is injected at image
  build time). Both bind at build, so neither can be added to a running engine.
- **Terraform's `deployment_spec` sizing and `env` blocks.** On a fresh project, `terraform
  apply` before `agents-cli deploy`: apply first and deploy takes the update path, keeping
  4 CPU / 8 GiB / concurrency 9; deploy first and the CLI's create defaults (1 / 4 GiB / 8) win
  permanently, since `ignore_changes` stops Terraform from correcting them. `app_sa_roles` is
  the exception — IAM sits outside `ignore_changes` and keeps applying.

`agents-cli deploy` does not send `spec.agentCard`, so the Agent Registry entry is a `CUSTOM`
one with no skills or JSON-RPC address. The runtime still serves a valid card over HTTP.

### Divergences from the scaffold, and what an `agents-cli` upgrade does to them

`agents-cli scaffold upgrade` regenerates template-owned files, and **the merge keeps our side
and drops the template's** — so the risk is not a reverted local change, it is an upstream
improvement disappearing without a word. 1.4.0's `GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY`
gate on `otel_to_cloud` is exactly what a keep-ours merge would have discarded.

Two rules follow. **Prefer changing a value over deleting or adding a block** — a changed value
merges against a recognisable template line, where a deleted block is an invisible hole a future
template addition falls into. And **keep only divergences whose reversal would change
behaviour**, since a cosmetic one costs the same merge conflict and buys nothing.

The inventory is measured, not remembered — generate a pristine scaffold and diff it:

```bash
agents-cli create blueprint-agent -a adk -o /tmp/pristine -d agent_runtime \
  --session-type in_memory --cicd-runner skip --agent-guidance-filename AGENTS.md \
  --no-agent-gateway -dir blueprint_agent --region us-central1 -y
diff -rq /tmp/pristine/blueprint-agent .
```

Sixteen files differ from a pristine 1.4.0 tree; three more are ours alone. The Terraform and
ignore-file departures also carry a `DIVERGES FROM THE SCAFFOLD` comment at the point of change.
Ranked by what an upgrade could cost:

| File | Divergence | Cost if the merge keeps ours |
|------|------------|------------------------------|
| `fast_api_app.py` | `attach_reasoning_engine_routes(app)`; `otel_to_cloud` read from env rather than hardcoded `True` | **Highest** — additions inside a file the template actively develops. Diff it every upgrade |
| `test_server_e2e.py` | `test_reasoning_engine_stream`; the fixture closes its pipes | New tests hide new template tests that would have replaced them |
| `pyproject.toml` | `google-cloud-aiplatform[agent-engines,evaluation]`, `protobuf`; `**/node_modules,**/vendor` added to codespell's skip list | **Reverted, not kept** — `[project.dependencies]` is the one section treated as template-owned |
| `response_quality.py` | Judge model configurable; AFC warning silenced | Loses template improvements to the rubric |
| `service.tf` | Comment only: the env block is create-only, and one rebranded word | None — no value differs from the template |
| `variables.tf` | `region` default removed; `telemetry_logs_filter` annotated as unused | Low, but re-check: restoring `us-east1` reintroduces a silent wrong-region build |
| `agent.py` | `MODEL` read from the environment, default `gemini-3.5-flash-lite` | Low, and deliberate — the scaffold hardcodes a different model |
| `.gitignore`, `.env`, `.env.example`, `agents-cli-manifest.yaml`, `vars/env.tfvars`, `iam.tf`, `reasoning_engine_adapter.py`, `README.md`, `uv.lock` | This project's identity, ignore rules, comments, and prose | None — all of it is meant to be local |

**Ours alone:** `deployment/terraform/single-project/backend.tf` (state in GCS, using the bucket
and prefix `infra cicd` would pick), `deployment/terraform/bootstrap-state-bucket.sh`, and
`tests/conftest.py`.

Not local additions, despite appearances: `app_utils/reasoning_engine_adapter.py` and `a2a.py`'s
`_resolve_app_url` both ship in 1.4.0. So does the `terraform fmt` drift in `apis.tf`, `iam.tf`,
and `telemetry.tf`, left unformatted so an upgrade diff stays readable.

**After `agents-cli scaffold upgrade`:** re-run the diff above rather than trusting the merge,
then `terraform plan -var-file=vars/env.tfvars` — a plan proposing changes to an existing
engine's `deployment_spec` means `ignore_changes` was dropped.

## Observability

Telemetry is deliberately split in two, so that message content never enters traces or log
payloads while still being queryable alongside them.

| Stream | Path | Lands in |
|--------|------|----------|
| **Metadata** — token counts, tool names, trace IDs, and *references* to the message files | OpenTelemetry → Cloud Logging → log sink | BigQuery table `aiplatform_googleapis_com_reasoning_engine_stdout`, day-partitioned |
| **Content** — the prompts and responses themselves | OpenTelemetry completion hook → JSONL upload | `gs://<project>-blueprint-agent-logs/completions/`, exposed as the BigQuery external table `completions` |

`completions_view` rejoins them — matching each log's `messages_ref_uri` against the external
table's `_FILE_NAME`, unnesting message parts, and de-duplicating twice, once within a trace and
once across traces, because every request re-sends the full history. Query it for one row per
message part with tokens, tool calls, and trace IDs attached.

Terraform pre-creates the log table with a fixed schema (`shared/genai_logs_schema.json`) rather
than waiting for Cloud Logging to infer one, so the view is valid from the first apply.

Environment variables in `service.tf` control the split:

| Variable | Value | Effect |
|----------|-------|--------|
| `OTEL_INSTRUMENTATION_GENAI_COMPLETION_HOOK` | `upload` | Send message content to object storage |
| `OTEL_INSTRUMENTATION_GENAI_UPLOAD_BASE_PATH` | `gs://…/completions` | Where it goes |
| `OTEL_INSTRUMENTATION_GENAI_UPLOAD_FORMAT` | `jsonl` | Format the external table expects |
| `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT` | `NO_CONTENT` | Keep content out of log payloads |
| `ADK_CAPTURE_MESSAGE_CONTENT_IN_SPANS` | `false` | Keep content out of Cloud Trace spans |
| `GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY` | `true` | Required — also gates `otel_to_cloud` in `fast_api_app.py` |

## Interoperability

This agent speaks the [A2A Protocol](https://a2a-protocol.org/). Inspect the card and exercise
the JSON-RPC endpoint with the [A2A Inspector](https://github.com/a2aproject/a2a-inspector).

To register a deployed agent with Gemini Enterprise:

```bash
agents-cli publish gemini-enterprise
```

The served card advertises both a v1.0 and a v0.3 JSON-RPC interface, because Gemini
Enterprise's registration validator still requires the v0.3 card shape.

## Reference

- [ADK documentation](https://adk.dev/)
- [`AGENTS.md`](AGENTS.md) — development phases and operating rules for coding agents in this
  repo
