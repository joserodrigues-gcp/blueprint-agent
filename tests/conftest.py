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
"""Give the tests the same environment the app gets.

`blueprint_agent/fast_api_app.py` calls `load_dotenv()` at import, but pytest
does not — so under a bare `uv run pytest` the model configuration is simply
absent, `google-genai` falls back to API-key mode, and every test that reaches
the model fails with `ValueError: No API key was provided`. The failure names
an API key, which points away from the actual cause.

`load_dotenv` does not overwrite variables that are already set, so a CI runner
or an inline `MODEL=... pytest` still wins over the file.
"""

from dotenv import find_dotenv, load_dotenv

# find_dotenv walks up from this file rather than from the working directory, which is
# what `load_dotenv()` in fast_api_app.py resolves to as well. `.env.secrets` holds the
# machine-local half (see .env.secrets.example) and is absent on CI, where find_dotenv
# returns "" and load_dotenv has nothing to load.
load_dotenv(find_dotenv(".env"))
load_dotenv(find_dotenv(".env.secrets"))
