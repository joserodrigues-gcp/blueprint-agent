# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import contextlib
import os
from collections.abc import AsyncIterator

from a2a.server.tasks import InMemoryTaskStore
from dotenv import find_dotenv, load_dotenv
from fastapi import FastAPI
from google.adk.cli.fast_api import get_fast_api_app
from google.adk.runners import Runner

from blueprint_agent.app_utils import services
from blueprint_agent.app_utils.a2a import attach_a2a_routes
from blueprint_agent.app_utils.reasoning_engine_adapter import (
    attach_reasoning_engine_routes,
)

load_dotenv()
# Settings that belong to this machine only.
#
# They are kept out of .env because `agents-cli deploy` copies .env onto the deployed
# runtime. GOOGLE_APPLICATION_CREDENTIALS is the clearest example: it points at a local
# credentials file, which on the runtime would override its own service account.
#
# find_dotenv looks for the file relative to this module rather than the current
# directory, so it resolves the same wherever the server is started from. It returns an
# empty string when there is no such file — the case in the deployed image, where
# load_dotenv then does nothing.
load_dotenv(find_dotenv(".env.secrets"))
otel_to_cloud = os.environ.get(
    "GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY", ""
).lower() in ("true", "1")
allow_origins = (
    os.getenv("ALLOW_ORIGINS", "").split(",") if os.getenv("ALLOW_ORIGINS") else None
)

AGENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


@contextlib.asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    # The agent is imported inside the lifespan so that it is built after the
    # environment and telemetry above are in place.
    #
    # Its runner uses the shared session and artifact services from services.py, so a
    # session started on any of the three surfaces is visible to the other two.
    from blueprint_agent.agent import app as adk_app
    from blueprint_agent.agent import root_agent

    runner = Runner(
        app=adk_app,
        session_service=services.get_session_service(),
        artifact_service=services.get_artifact_service(),
        auto_create_session=True,
    )
    # Put on app.state so the reasoning_engine routes can use the same runner.
    app.state.runner = runner
    app.state.agent_app_name = adk_app.name
    await attach_a2a_routes(
        app,
        agent=root_agent,
        runner=runner,
        task_store=InMemoryTaskStore(),
        rpc_path=f"/a2a/{adk_app.name}",
    )
    yield


app: FastAPI = get_fast_api_app(
    agents_dir=AGENT_DIR,
    web=True,
    artifact_service_uri=services.ARTIFACT_SERVICE_URI,
    allow_origins=allow_origins,
    session_service_uri=services.SESSION_SERVICE_URI,
    otel_to_cloud=otel_to_cloud,
    lifespan=lifespan,
)
app.title = "blueprint-agent"
app.description = "API for interacting with the Agent blueprint-agent"


# Adds a third set of routes, in the shape the reasoning_engine SDK expects. They run
# beside the native adk_api ones and let the Agent Platform console playground drive
# this agent.
attach_reasoning_engine_routes(app)


# Main execution
if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
