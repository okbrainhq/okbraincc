# OKBrainCC Local Models Runtime Design

Status: Design / research only. No code changes are included in this document.

## 1. Goal

Add a local AI runtime to OKBrainCC that:

- Runs `qwen3.5:4b` and Qwen3 embedding models locally without depending on Ollama.
- Uses `llama.cpp` or a similar native runtime directly inside the OKBrainCC app lifecycle.
- Exposes an Ollama-compatible HTTP API, with `ollama serve`-style binding behavior.
- Provides setup, update, model download, logging, and start/stop UI similar to the existing OKProxy section.
- Unloads idle model memory after 5 minutes by default.

## 2. Research summary

### 2.1 Runtime choice

`llama.cpp` is the best default runtime because it is a lightweight C/C++ inference stack with broad hardware support, including Apple Silicon via Metal and Accelerate, CPU execution, CUDA, Vulkan, and other GPU backends. [source](https://qwen.readthedocs.io/en/latest/run_locally/llama.cpp.html)

`llama-server` already exposes OpenAI-compatible endpoints including `/v1/chat/completions`, `/v1/completions`, `/v1/responses`, `/v1/embeddings`, and `/v1/models`. [source](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)

`llama-server` supports binding via `--host` and `--port`, model aliases via `--alias`, embedding mode via `--embedding`, and embedding pooling via `--pooling`. [source](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)

`llama-server` supports router mode with `--models-dir`, dynamic model loading and unloading via `/models/load` and `/models/unload`, and request routing by the request `model` field. [source](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)

`llama-server` supports an idle sleep mode with `--sleep-idle-seconds`; when sleeping, the model and KV cache are unloaded from RAM, and a new incoming task reloads the model. [source](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)

### 2.2 Ollama API behavior to emulate

Ollama model names follow a `model:tag` format, and tags default to `latest` when omitted. [source](https://github.com/ollama/ollama/blob/main/docs/api.md)

Ollama provides `/api/generate`, `/api/chat`, `/api/embed`, `/api/tags`, `/api/ps`, `/api/show`, `/api/pull`, and `/api/version`. [source](https://github.com/ollama/ollama/blob/main/docs/api.md)

Ollama keeps models loaded for 5 minutes by default, and its `keep_alive` request parameter can override how long a model stays loaded after a `/api/generate` or `/api/chat` request. [source](https://docs.ollama.com/faq)

Ollama can preload a model by sending an empty `/api/generate` or `/api/chat` request, and can unload a model by sending an empty prompt/messages request with `keep_alive: 0`. [source](https://github.com/ollama/ollama/blob/main/docs/api.md)

Ollama binds to `127.0.0.1:11434` by default, and the bind address can be changed with `OLLAMA_HOST`. [source](https://docs.ollama.com/faq)

### 2.3 Qwen3.5 4B model

The Ollama `qwen3.5:4b` library page lists the model as `qwen35` architecture, 4.66B parameters, Q4_K_M quantization, and a 3.4GB model blob. [source](https://ollama.com/library/qwen3.5:4b)

Qwen3.5 includes a Small series with 0.8B, 2B, 4B, and 9B models, and Unsloth lists Qwen3.5 4B GGUFs for llama.cpp-compatible local inference. [source](https://unsloth.ai/docs/models/qwen3.5)

Unsloth lists Qwen3.5 4B 4-bit memory requirements around 5.5GB of total RAM/VRAM/unified memory. [source](https://unsloth.ai/docs/models/qwen3.5)

Qwen3.5 Small models have reasoning disabled by default; reasoning can be enabled through llama-server chat template kwargs such as `{"enable_thinking": true}`. [source](https://unsloth.ai/docs/models/qwen3.5)

Unsloth notes that Qwen3.5 GGUFs use separate `mmproj` vision files and recommends llama.cpp-compatible backends for those GGUFs. [source](https://unsloth.ai/docs/models/qwen3.5)

### 2.4 Qwen3 embedding model

The Qwen3 Embedding series includes 0.6B, 4B, and 8B text embedding models. [source](https://huggingface.co/Qwen/Qwen3-Embedding-4B-GGUF)

Qwen3-Embedding-0.6B has a 32K sequence length and 1024 embedding dimensions; Qwen3-Embedding-4B has a 32K sequence length and 2560 embedding dimensions; Qwen3-Embedding-8B has a 32K sequence length and 4096 embedding dimensions. [source](https://huggingface.co/Qwen/Qwen3-Embedding-4B-GGUF)

The Qwen3 Embedding model card recommends running llama.cpp embeddings with `--pooling last`, and a llama-server embedding service with `--embedding --pooling last -ub 8192`. [source](https://huggingface.co/Qwen/Qwen3-Embedding-4B-GGUF)

Ollama has a `qwen3-embedding` library page for embedding models in 0.6B, 4B, and 8B sizes. [source](https://ollama.com/library/qwen3-embedding)

## 3. Existing OKBrainCC patterns to reuse

The current app already has an OKProxy setup and process-control pattern:

- `OKProxySettings` stores repository, install path, local Node.js path, defaults, and validation.
- `OKProxyCommandRunner` installs prerequisites, downloads/clones the dependency, runs setup, captures output, and exposes shell helpers.
- `OKProxyClientStore` owns settings, install status, busy status, process lifecycle, auto-start, logs, and cleanup on app termination.
- `OKProxyClientView` exposes setup, configuration, controls, log tail, and operation output sections.

The local AI feature should mirror this shape, but replace Node.js/repo setup with a native `llama.cpp` runtime installer and model downloader.

## 4. Recommended architecture

### 4.1 High-level components

Use three layers:

- Public Ollama-compatible API server inside OKBrainCC.
  - Binds to the user-configured host/port.
  - Default: `127.0.0.1:11434` for Ollama compatibility.
  - Translates Ollama API requests to llama.cpp worker requests.
  - Also passes through `/v1/*` OpenAI-compatible requests where possible.

- llama.cpp worker manager.
  - Starts dedicated `llama-server` worker processes on private loopback ports.
  - Uses one worker profile for the chat model and one worker profile for the embedding model.
  - Applies model-specific flags cleanly, especially `--embedding --pooling last` for Qwen3 Embedding.
  - Owns idle timers, explicit unloads, and app-termination cleanup.

- Setup and model manager.
  - Installs or updates `llama-server`.
  - Downloads GGUF model files and optional `mmproj` files.
  - Verifies file size and checksum when available.
  - Maintains a local model manifest and installation state.

### 4.2 Why not expose llama-server directly?

`llama-server` already provides OpenAI-compatible APIs, but it does not provide the Ollama `/api/*` surface. A public OKBrainCC proxy is still required for Ollama compatibility.

A direct `llama-server` router is attractive, but the first implementation should use explicit worker profiles because the chat model and embedding model need different runtime flags. This also makes Ollama `keep_alive`, `/api/ps`, and immediate unload semantics easier to implement.

Router mode can be a later optimization after validating model-specific presets for mixed chat and embedding models.

## 5. Process topology

Default topology:

- OKBrainCC public API server:
  - Host: `127.0.0.1`
  - Port: `11434`
  - Exposes Ollama-compatible `/api/*` and OpenAI-compatible `/v1/*`.

- Private chat worker:
  - Host: `127.0.0.1`
  - Dynamic port, for example `11435`.
  - Command profile: `llama-server --model <qwen3.5 GGUF> --alias qwen3.5:4b --host 127.0.0.1 --port <port> --jinja ...`

- Private embedding worker:
  - Host: `127.0.0.1`
  - Dynamic port, for example `11436`.
  - Command profile: `llama-server --model <qwen3-embedding GGUF> --alias qwen3-embedding --host 127.0.0.1 --port <port> --embedding --pooling last -ub 8192 ...`

Workers should be started on demand. A worker is considered active only when a request requires its model.

## 6. Storage layout

Recommended local storage:

- `~/.okbraincc/local-ai/bin/llama.cpp/<version>/`
  - `llama-server`
  - `llama-cli`
  - version metadata

- `~/.okbraincc/local-ai/models/`
  - `qwen3.5-4b/`
  - `qwen3-embedding-0.6b/`
  - `qwen3-embedding-4b/`

- `~/.okbraincc/local-ai/manifests/`
  - `models.json`
  - `downloads.json`

- `~/.okbraincc/local-ai/logs/`
  - `api.log`
  - `qwen3.5-4b.log`
  - `qwen3-embedding.log`
  - `setup.log`

- `~/.okbraincc/local-ai/tmp/`
  - partial downloads
  - checksum files

This keeps AI assets separate from OKProxy and avoids writing into Ollama's `~/.ollama` model store.

## 7. Setup UX design

Add a new sidebar section, for example `Local AI Server` or `Local Models`.

### 7.1 Header

Show:

- Current API URL, for example `http://127.0.0.1:11434`.
- Runtime status: missing, ready, starting, running, stopping, failed.
- Model status chips: not downloaded, downloaded, loading, loaded, sleeping/unloaded.

### 7.2 Runtime setup section

Mirror OKProxy's setup UI:

- Runtime path.
- Installed llama.cpp version.
- Buttons:
  - Download & Install llama.cpp
  - Update llama.cpp
  - Refresh
  - Open Runtime Folder

Installer behavior:

- Prefer downloading a prebuilt llama.cpp release matching macOS architecture.
- Verify the archive checksum when the upstream release provides a checksum.
- Fallback option: build from source with CMake for development or unsupported release assets.
- Detect `llama-server --version` after install.

### 7.3 Model downloads section

Model cards:

- `qwen3.5:4b`
  - Required for chat and generate APIs.
  - Default quantization: Q4-class quant for practical local memory use.
  - Optional `mmproj` download for image inputs.

- `qwen3-embedding`
  - Required for `/api/embed` and `/v1/embeddings`.
  - Default size decision should be explicit:
    - 0.6B for lower memory and faster local use.
    - 4B for better quality and still practical local use on stronger machines.

Each card should show:

- Source repo and file pattern.
- Estimated size.
- Download progress.
- Verify status.
- Buttons:
  - Download
  - Cancel
  - Delete
  - Open Model Folder

### 7.4 Server controls section

Fields:

- Bind host: default `127.0.0.1`.
- Port: default `11434`.
- Idle unload timeout: default `300` seconds.
- Max loaded models: default `1` or `2`, based on memory strategy.
- Auto start on app launch.
- Optional API key.

Buttons:

- Start Server
- Stop Server
- Restart
- Copy API URL
- Open Logs

### 7.5 Logs and operation output

Reuse the OKProxy visual pattern:

- Latest API log lines.
- Latest worker log lines.
- Setup/download operation output.
- Download progress messages.

## 8. Model manifest design

Use a local model manifest rather than hardcoding model details across the app.

### 8.1 Chat model manifest

Logical model:

- Ollama name: `qwen3.5:4b`
- Aliases: `qwen3.5`, `qwen3.5:latest`, `qwen3.5-4b`
- Runtime type: chat/completion
- Preferred sources:
  - Primary candidate: `unsloth/Qwen3.5-4B-GGUF`, because Unsloth publishes Qwen3.5 4B GGUFs and documents llama.cpp usage. [source](https://unsloth.ai/docs/models/qwen3.5)
  - Alternative candidate: a vetted Q4_K_M GGUF publisher such as `bartowski/Qwen_Qwen3.5-4B-GGUF` or `lmstudio-community/Qwen3.5-4B-GGUF`, if product wants exact Q4_K_M parity.
- Default runtime flags:
  - `--jinja`
  - `--alias qwen3.5:4b`
  - Qwen3.5 recommended sampling defaults surfaced through request options, not forced globally.
  - Optional `--mmproj <mmproj-F16.gguf>` when multimodal support is enabled.

Decision needed: pin the exact GGUF repo, quant, file name, and checksum before implementation. Do not rely on Ollama's internal blob format.

### 8.2 Embedding model manifest

Logical model:

- Ollama name: `qwen3-embedding`
- Aliases: `qwen3-embedding:latest`, `qwen3-embedding:0.6b`, `qwen3-embedding:4b`
- Runtime type: embedding
- Preferred sources:
  - `Qwen/Qwen3-Embedding-0.6B-GGUF` for default low-memory install.
  - `Qwen/Qwen3-Embedding-4B-GGUF` for higher-quality install.
- Default runtime flags:
  - `--embedding`
  - `--pooling last`
  - `--embd-normalize 2`
  - `-ub 8192`
  - `--alias qwen3-embedding`

Decision needed: choose whether default `qwen3-embedding` maps to 0.6B or 4B. The UI can support both, but the API alias needs one default.

## 9. Ollama-compatible API design

### 9.1 Endpoint compatibility target

MVP should support:

- `GET /`
- `GET /api/version`
- `GET /api/tags`
- `POST /api/show`
- `GET /api/ps`
- `POST /api/generate`
- `POST /api/chat`
- `POST /api/embed`
- `POST /api/embeddings`
- `POST /api/pull`
- `DELETE /api/delete`
- `/v1/models`
- `/v1/chat/completions`
- `/v1/completions`
- `/v1/embeddings`

Unsupported or later endpoints:

- `/api/create`
- `/api/copy`
- `/api/push`
- `/api/blobs/*`
- Image generation APIs

Unsupported endpoints should return explicit errors, not silent wrong behavior.

### 9.2 `/api/chat` mapping

Input:

- `model`
- `messages`
- `stream`
- `format`
- `options`
- `keep_alive`
- `tools`
- `think`

Behavior:

- Resolve Ollama model name to a local manifest entry.
- Ensure the model is downloaded.
- Start or wake the matching chat worker.
- Map to `/v1/chat/completions` on the worker.
- Translate OpenAI SSE chunks into Ollama newline-delimited JSON chunks when `stream` is true.
- Aggregate chunks into one Ollama response when `stream` is false.
- Map `format: "json"` or schema formats to the closest llama.cpp/OpenAI-compatible response format.
- Map common `options` values such as `temperature`, `top_p`, `top_k`, `num_predict`, `num_ctx`, and `stop`.

### 9.3 `/api/generate` mapping

Input:

- `model`
- `prompt`
- `suffix`
- `system`
- `template`
- `raw`
- `stream`
- `format`
- `options`
- `keep_alive`

Behavior:

- Empty prompt and no generation content should preload the model.
- Empty prompt with `keep_alive: 0` should unload the model.
- Normal prompt should map to `/v1/completions` or llama.cpp `/completion`.
- If `system` or chat formatting is needed, the proxy may map to `/v1/chat/completions` with a synthetic single user message.

### 9.4 `/api/embed` mapping

Input:

- `model`
- `input`
- `truncate`
- `options`
- `keep_alive`
- `dimensions`

Behavior:

- Resolve to the embedding worker.
- Start or wake the embedding worker with `--embedding --pooling last`.
- Map to `/v1/embeddings`.
- Return Ollama-shaped `embeddings` arrays.
- If `dimensions` is requested, either support verified truncation/renormalization for Qwen3 Embedding MRL or return a clear unsupported error until validated.

### 9.5 `/api/pull` mapping

Behavior:

- Do not call Ollama.
- Resolve the requested model to the OKBrainCC manifest.
- Download GGUF files from configured sources.
- Stream Ollama-style progress JSON objects.
- Return `{"status":"success"}` at completion.

### 9.6 `/api/ps` mapping

Behavior:

- Return locally loaded or sleeping worker status.
- Include `expires_at` based on the proxy's idle timer.
- Include model names using Ollama aliases, not GGUF file names.

## 10. Idle unload and keep_alive design

Default idle unload: 300 seconds.

Recommended behavior:

- Treat `/api/chat`, `/api/generate`, `/api/embed`, and `/v1/*` inference requests as activity.
- Do not reset idle timers for `/api/version`, `/api/tags`, `/api/ps`, logs, or health checks.
- For `keep_alive` omitted, use the configured default of 300 seconds.
- For `keep_alive: 0`, unload immediately after request completion, or immediately when the request is an empty preload/unload request.
- For positive duration values, set that model's idle deadline to that duration.
- For negative duration values, pin the model until the user stops the server, unpins it, or the app exits.

Implementation options:

- Primary: proxy-owned idle scheduler.
  - The proxy schedules unloads and calls worker unload/sleep endpoints if available.
  - If a worker cannot unload cleanly, terminate the worker process.

- Safety backup: start llama-server workers with `--sleep-idle-seconds 300`.
  - This provides a runtime-level fallback unload if the proxy misses an idle deadline.
  - Be careful with pinned or long `keep_alive` requests because a fixed llama.cpp sleep timeout can unload earlier than a custom Ollama-style duration.

For precise Ollama semantics, the proxy-owned scheduler should be the source of truth.

## 11. Security design

- Default bind must be `127.0.0.1`, not `0.0.0.0`.
- If the user selects a non-loopback bind address, show a warning and require an API key.
- Keep private llama.cpp workers bound to `127.0.0.1` only.
- Do not enable llama-server built-in tools by default, because the server docs describe local filesystem tools exposed through `--tools`. [source](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
- Detect port conflicts, especially when Ollama is already running on `11434`.
- Keep Hugging Face tokens optional and never log token values.
- Avoid shelling user-controlled model names directly; resolve only through manifest entries.

## 12. Error and status model

Statuses should be separate for runtime, API server, and each model.

Runtime status:

- Missing
- Installing
- Ready
- Updating
- Failed

API server status:

- Disabled
- Stopped
- Starting
- Running
- Stopping
- Failed

Model status:

- Not downloaded
- Downloading
- Verifying
- Downloaded
- Loading
- Loaded
- Sleeping / unloaded
- Failed

Common user-facing errors:

- Runtime missing.
- Model not downloaded.
- Port already in use.
- Unsupported model alias.
- Download failed.
- Checksum mismatch.
- Worker failed to become healthy.
- Request uses unsupported Ollama endpoint.

## 13. Testing plan

Setup tests:

- Runtime install detects architecture and installs the expected binary.
- Runtime update replaces old binaries safely.
- Model download resumes partial downloads.
- Model verification catches truncated files.
- Port conflict detection works when Ollama or another service owns `11434`.

API compatibility tests:

- `GET /api/version` returns an Ollama-shaped version response.
- `GET /api/tags` lists installed models with Ollama names.
- `POST /api/chat` works in streaming and non-streaming modes.
- `POST /api/generate` works in streaming and non-streaming modes.
- Empty `/api/generate` preloads the model.
- Empty `/api/generate` with `keep_alive: 0` unloads the model.
- `POST /api/embed` returns one vector for one input and multiple vectors for multiple inputs.
- `/v1/chat/completions` and `/v1/embeddings` work as pass-through APIs.

Resource tests:

- Model unload happens after 300 seconds of inference inactivity.
- Health/status polling does not reset the idle timer.
- App quit stops the public API server and worker processes.
- Repeated start/stop cycles do not leave orphaned `llama-server` processes.

## 14. Implementation phases

Phase 1: Design and model pinning

- Finalize GGUF source, quant, file names, and checksums.
- Choose default `qwen3-embedding` size.
- Decide whether Qwen3.5 vision via `mmproj` is MVP or later.

Phase 2: Setup system

- Add local AI models/settings/store/view types mirroring OKProxy patterns.
- Add llama.cpp installer/update flow.
- Add model download/delete/verify flow.

Phase 3: Runtime process management

- Add public API server lifecycle.
- Add worker process lifecycle.
- Add idle scheduler and app-termination cleanup.

Phase 4: API compatibility

- Implement `/api/version`, `/api/tags`, `/api/show`, `/api/ps`.
- Implement `/api/chat`, `/api/generate`, `/api/embed`, `/api/embeddings`.
- Implement `/api/pull` using the local downloader.
- Add `/v1/*` pass-through.

Phase 5: Hardening

- Add port conflict handling.
- Add API key support for non-loopback binds.
- Add download checksum enforcement.
- Add integration tests with curl and common Ollama/OpenAI clients.

## 15. Open decisions

- Exact source for `qwen3.5:4b` GGUF: Unsloth has strong llama.cpp documentation and `mmproj` support, while other publishers may provide exact Q4_K_M parity.
- Default embedding model size: 0.6B is friendlier for most machines; 4B provides higher-quality vectors.
- Vision support: Qwen3.5 is multimodal, but supporting Ollama `images` needs `mmproj` download, request conversion, and tests.
- Whether to use llama.cpp router mode in the first implementation or only after the explicit worker model is stable.
- Whether `dimensions` for `/api/embed` should be supported immediately via Qwen3 Embedding MRL behavior or rejected until validated.
