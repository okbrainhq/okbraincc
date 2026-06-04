# OKBrainCC Local MLX Runtime Design — OpenAI-Compatible API Only

Status: Design / research only. No implementation code is included in this document.

Research date: 2026-06-03.
Last updated: 2026-06-03.

## 1. Updated scope

The previous MLX design considered Ollama-compatible endpoints, model downloads, setup/download UI, and Ollama-like model management.

The updated requirement is smaller:

- Run already-available local MLX models inside OKBrainCC.
- Provide an OpenAI-compatible API for communicating with those models.
- Do not implement Ollama-compatible `/api/*` endpoints.
- Do not implement model download, pull, model-card, or download-progress features.
- Do not shell out to Ollama.
- Do not use `llama.cpp` for this design.
- Keep model lifecycle management minimal but safe.
- Optionally unload idle models after a configurable timeout, default 5 minutes.

This means the product is not trying to behave like `ollama serve`; it is trying to expose a small local OpenAI-style server backed by MLX.

## 2. Executive recommendation

This is feasible and significantly easier than the earlier Ollama-compatible/download design.

Recommended approach:

- Use `MLX Swift` + `MLX Swift LM` directly in OKBrainCC on Apple Silicon macOS.
- Implement a small HTTP API server in OKBrainCC that supports only selected OpenAI-compatible endpoints.
- Configure models by local path or known Hugging Face-style model ID if already cached.
- Start with one chat model and one embedding model.
- Keep API behavior intentionally narrow and predictable.

Recommended initial model configuration:

| API model name | Local MLX model candidate | Role |
| --- | --- | --- |
| `qwen3.5:4b` | `mlx-community/Qwen3.5-4B-OptiQ-4bit` or local equivalent path | Chat/completions |
| `qwen3-embedding` | `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` or local equivalent path | Embeddings |

The API should not download these automatically. If a configured model path is missing, return a normal OpenAI-shaped error and show the missing path in OKBrainCC diagnostics.

## 3. Feasibility summary

### 3.1 MLX fit

MLX is suitable for Apple Silicon local inference. It supports Swift APIs through `MLX Swift`, and LLM integrations through `mlx-swift-lm`.

Important implementation notes:

- OKBrainCC must target Apple Silicon for this backend.
- SwiftPM command-line limitations around Metal shaders mean final builds should be validated with Xcode or `xcodebuild`.
- Direct MLX introduces real package/platform dependencies into OKBrainCC.
- A stable `mlx-swift-lm` release or commit should be pinned.

### 3.2 Existing server reference

Python `mlx_lm.server` exposes an OpenAI-like API and can be used as a behavior reference, but OKBrainCC should not rely on it as the production API server.

Reason:

- OKBrainCC can implement a much smaller API subset.
- Avoiding the Python server keeps the runtime native.
- The public API can match OKBrainCC's security, logging, lifecycle, and app-state requirements.

### 3.3 Model support

Qwen3.5 chat/generation support is plausible through MLX Swift LM because Qwen/Qwen3.5 model families are represented in the MLX Swift LM ecosystem.

Qwen3 embeddings are also plausible through the embedding support in MLX Swift LM, especially for the 0.6B model.

Prototype validation is still required for:

- Exact `qwen3.5:4b` local model path/config.
- Chat template correctness.
- Streaming token behavior.
- Qwen3 embedding output dimension.
- Memory release after unload.

## 4. API surface

### 4.1 Required endpoints

Implement only these endpoints first:

| Endpoint | Method | Purpose | Required for MVP |
| --- | --- | --- | --- |
| `/v1/models` | `GET` | List configured local models | Yes |
| `/v1/chat/completions` | `POST` | Chat completion | Yes |
| `/v1/embeddings` | `POST` | Embeddings | Yes |
| `/health` | `GET` | Internal/local health check | Recommended |

Optional later:

| Endpoint | Method | Purpose |
| --- | --- | --- |
| `/v1/completions` | `POST` | Legacy prompt completion |
| `/metrics` | `GET` | Local diagnostics, disabled by default |

Do not implement:

- `/api/chat`
- `/api/generate`
- `/api/embed`
- `/api/pull`
- `/api/tags`
- `/api/show`
- `/api/ps`
- Ollama `keep_alive` compatibility syntax as a public contract

### 4.2 API compatibility target

The goal is OpenAI-compatible enough for clients that allow a custom base URL:

```text
base_url = http://127.0.0.1:<configured-port>/v1
api_key = any non-empty local placeholder, or omitted if the client allows it
model = qwen3.5:4b
```

Compatibility level:

- Match OpenAI request and response shapes for common fields.
- Support non-streaming chat completions.
- Support streaming chat completions via Server-Sent Events.
- Support embeddings with single string or array input.
- Return OpenAI-shaped error objects.

This does not need exact parity with every OpenAI parameter.

## 5. Request and response behavior

### 5.1 `GET /v1/models`

Return configured model aliases, not downloaded model inventory.

Example model entries:

- `qwen3.5:4b`
- `qwen3-embedding`

Each entry should include:

- `id`
- `object: "model"`
- `created`
- `owned_by: "okbraincc"`

If a configured path is missing, either:

- Hide the model by default, or
- Include it with diagnostic metadata only if a debug setting is enabled.

Recommendation: list only usable models for API clients, and show missing models in the OKBrainCC UI/logs.

### 5.2 `POST /v1/chat/completions`

Required request fields:

- `model`
- `messages`

Supported optional fields for MVP:

- `stream`
- `temperature`
- `top_p`
- `max_tokens`
- `stop`
- `seed`, only if MLX backend supports it cleanly

Ignored or unsupported initially:

- `tools`
- `tool_choice`
- `response_format`
- `logprobs`
- `top_logprobs`
- `presence_penalty`
- `frequency_penalty`
- multimodal content arrays

Unsupported fields should either be ignored with a warning in logs or rejected if they are likely to change output semantics. For early API reliability, reject `tools`, `response_format`, and multimodal content with a clear error.

Response shape:

- `id: chatcmpl-...`
- `object: chat.completion`
- `created`
- `model`
- `choices[0].message.role: assistant`
- `choices[0].message.content`
- `choices[0].finish_reason`
- `usage`, if token counts are available

If token counts are not reliably available at first, return best-effort counts or omit `usage` only if clients tolerate it. Recommendation: provide best-effort prompt/completion token counts from tokenizer output.

### 5.3 Streaming chat completions

When `stream: true`, return Server-Sent Events:

```text
data: {"id":"...","object":"chat.completion.chunk","choices":[{"delta":{"role":"assistant"},"index":0}]}

data: {"id":"...","object":"chat.completion.chunk","choices":[{"delta":{"content":"..."},"index":0}]}

data: [DONE]
```

Implementation notes:

- Flush each token or small token batch promptly.
- Stop streaming when the client disconnects.
- Cancel MLX generation on disconnect if cancellation is supported.
- Do not run two generations concurrently on the same model unless the model lane is explicitly made concurrent-safe.

### 5.4 `POST /v1/embeddings`

Required request fields:

- `model`
- `input`

Supported input forms:

- String
- Array of strings

Response shape:

- `object: "list"`
- `data[*].object: "embedding"`
- `data[*].embedding: [Float]`
- `data[*].index`
- `model`
- `usage`, if token counts are available

Embedding dimensions should match the selected model:

| Model | Expected dimensions |
| --- | --- |
| Qwen3 Embedding 0.6B | 1024 |
| Qwen3 Embedding 4B | 2560 |
| Qwen3 Embedding 8B | 4096 |

For MVP, use one configured embedding model alias such as `qwen3-embedding`.

## 6. Runtime architecture

### 6.1 Preferred MVP architecture: in-process actor

For the smaller OpenAI-only scope, start with an in-process runtime actor.

Components:

- `LocalOpenAIServer`
  - Binds local HTTP server.
  - Routes `/v1/*` requests.
  - Serializes OpenAI-shaped responses.

- `MLXModelRegistry`
  - Holds configured model aliases and local paths.
  - Validates model availability at startup or on first use.

- `MLXChatRuntime`
  - Loads the chat model lazily.
  - Applies chat templates.
  - Runs generation.
  - Streams token deltas.

- `MLXEmbeddingRuntime`
  - Loads embedding model lazily.
  - Runs batch embedding.
  - Returns normalized vectors where appropriate.

- `LocalAIStateStore`
  - Tracks server state, model loaded state, last request time, errors, and settings.

Why in-process first:

- No download manager.
- No Ollama compatibility layer.
- Smaller API surface.
- Easier debugging inside the app.
- Fastest path to a useful local API.

### 6.2 Helper process option

A helper process is still useful if reliable memory release becomes a hard requirement.

Use a helper process if:

- In-process unload does not release enough unified/Metal memory.
- Model crashes should not crash the UI app.
- Long-running inference must be isolated.
- You want strict idle unload by process termination.

Recommendation:

- MVP: in-process actor.
- Production hardening: add helper process only if memory tests prove it is needed.

## 7. Model configuration

### 7.1 No download manager

The app should not download models in this design.

Instead, provide settings for local model paths:

| Setting | Example |
| --- | --- |
| Chat model alias | `qwen3.5:4b` |
| Chat model path | `/Users/<user>/Models/mlx/Qwen3.5-4B-OptiQ-4bit` |
| Embedding model alias | `qwen3-embedding` |
| Embedding model path | `/Users/<user>/Models/mlx/Qwen3-Embedding-0.6B-4bit-DWQ` |

The UI can include:

- Choose Folder.
- Validate Model.
- Test Chat.
- Test Embedding.
- Open Logs.

But it should not include:

- Download buttons.
- Pull progress.
- Hugging Face auth.
- Model-card downloader.
- Delete downloaded model flow.

### 7.2 Model validation

Validation should check:

- Directory exists.
- Required config/tokenizer files exist.
- MLX Swift LM can load the model metadata.
- For chat: a short test prompt can generate a few tokens.
- For embeddings: a test string returns the expected dimension.

Validation should not load the full model on every app start unless the user enables eager validation.

### 7.3 Model aliases

The API should use aliases so client configs stay stable even if local paths change.

Initial aliases:

- `qwen3.5:4b`
- `qwen3-embedding`

Optional aliases:

- `qwen3-embedding:0.6b`
- `qwen3-embedding:4b`
- `qwen3-embedding:8b`

## 8. Lifecycle and idle unload

### 8.1 Loading policy

Default:

- Lazy-load a model on first request.
- Keep it loaded while active.
- Track last-used time per model lane.

Optional setting:

- Preload chat model when server starts.
- Preload embedding model when server starts.

### 8.2 Idle unload policy

Even without Ollama compatibility, idle unload is still useful.

Default:

- Unload each loaded model after 5 minutes of no requests.

Rules:

- Do not unload during active generation or embedding computation.
- Reset idle timer after each request finishes.
- If a new request arrives while unload is scheduled, cancel unload.
- If unload fails to release memory acceptably, log it and expose status in UI.

No public `keep_alive` compatibility is required for MVP.

Optional OpenAI-compatible extension:

- Support a non-standard header such as `X-OKBrainCC-Keep-Alive-Seconds` only for OKBrainCC-controlled clients.
- Do not rely on this for third-party OpenAI compatibility.

### 8.3 State machine

Per model lane:

| State | Meaning |
| --- | --- |
| `unconfigured` | No local path configured |
| `missing` | Configured path does not exist |
| `available` | Path exists but model is not loaded |
| `loading` | Model is loading |
| `loaded` | Model is ready |
| `busy` | Request in progress |
| `idleWaiting` | Loaded and waiting for idle unload |
| `unloading` | Runtime is releasing model resources |
| `failed` | Last operation failed |

## 9. HTTP binding and security

Default binding:

- Host: `127.0.0.1`
- Port: choose an OKBrainCC-specific default unless the product wants OpenAI clients to use a fixed known port.

Recommendation:

- Do not use `11434` by default because that implies Ollama compatibility.
- Use a clearly OKBrainCC-specific local port, for example `11535`, unless there is an existing app convention.

Security rules:

- Bind to loopback only by default.
- Require explicit confirmation for `0.0.0.0` or LAN addresses.
- If non-loopback binding is enabled, require a local API key.
- Accept `Authorization: Bearer <token>` for clients that require an API key shape.
- Allow a placeholder key only on loopback if the user enables no-auth local mode.
- Never expose internal model paths in normal API responses.
- Include detailed model path errors only in local UI/logs.

## 10. UI requirements

The UI should be much smaller than the earlier OKProxy/Ollama-style setup.

Add a `Local AI` / `Local OpenAI API` section with:

### 10.1 Server controls

- API status: stopped, starting, running, failed.
- Base URL, for example `http://127.0.0.1:11535/v1`.
- Start Server.
- Stop Server.
- Restart Server.
- Start on app launch.
- Copy Base URL.
- Copy sample OpenAI client config.

### 10.2 Model settings

- Chat model alias.
- Chat model folder picker.
- Embedding model alias.
- Embedding model folder picker.
- Validate Chat Model.
- Validate Embedding Model.
- Test Chat.
- Test Embedding.

### 10.3 Runtime controls

- Loaded chat model status.
- Loaded embedding model status.
- Unload Chat Model.
- Unload Embedding Model.
- Unload All.
- Idle unload timeout, default 5 minutes.

### 10.4 Logs

- API log.
- Runtime log.
- Validation log.
- Copy/export log actions.

No download UI is needed.

## 11. Error behavior

Use OpenAI-shaped errors.

Recommended error object:

```json
{
  "error": {
    "message": "Model 'qwen3.5:4b' is not configured",
    "type": "invalid_request_error",
    "param": "model",
    "code": "model_not_configured"
  }
}
```

Common errors:

| Code | Meaning |
| --- | --- |
| `model_not_configured` | Alias has no local path |
| `model_not_found` | Configured path is missing |
| `model_load_failed` | MLX could not load model |
| `invalid_messages` | Chat messages are malformed |
| `unsupported_parameter` | Request includes unsupported feature |
| `context_length_exceeded` | Input is too long |
| `runtime_busy` | Concurrency limit reached |
| `generation_cancelled` | Client disconnected or request cancelled |

## 12. Concurrency model

MVP recommendation:

- One active chat generation at a time per chat model.
- One active embedding batch at a time per embedding model.
- Chat and embeddings may run concurrently only after memory/performance testing.

If a lane is busy:

- Queue with a short bounded queue, or
- Return `429` / `runtime_busy`.

Recommendation for MVP:

- Use a small queue of 1-2 pending requests.
- Add request timeout and cancellation.
- Reject additional requests cleanly.

## 13. Testing plan

### 13.1 Unit tests

- OpenAI request decoding.
- OpenAI response serialization.
- Error serialization.
- Model alias/path resolution.
- Idle timeout state transitions.
- Unsupported parameter handling.

### 13.2 Integration tests

- Start server on loopback.
- `GET /v1/models` returns configured usable aliases.
- Non-streaming `/v1/chat/completions` returns valid response shape.
- Streaming `/v1/chat/completions` returns SSE chunks and `[DONE]`.
- `/v1/embeddings` returns expected vector dimensions.
- Missing model path returns OpenAI-shaped error.
- Idle unload triggers after shortened test timeout.

### 13.3 Memory tests

- Measure memory before model load.
- Measure memory after first completion.
- Measure memory after idle unload.
- Decide whether helper-process isolation is needed.

## 14. Implementation difficulty

Compared with the previous Ollama-compatible/download design, this is much easier.

Estimated difficulty:

| Scope | Difficulty | Rough estimate |
| --- | --- | --- |
| Minimal non-streaming chat + models endpoint | Medium-low | 3-5 days |
| Add embeddings + validation UI | Medium | 1 week |
| Add streaming SSE + idle unload | Medium | 1-2 weeks |
| Production hardening with cancellation, queueing, auth, memory tests | Medium | 2-3 weeks |
| Helper-process isolation if needed | Medium-high | Additional 1-2 weeks |

The hardest pieces are:

- Correct chat template handling.
- Token streaming/cancellation.
- Memory release after unload.
- Embedding pooling/normalization correctness.
- Compatibility with common OpenAI-client assumptions.

The HTTP routing itself is straightforward.

## 15. Implementation phases

### Phase 0 — MLX validation harness

Goals:

- Load configured local `qwen3.5:4b` MLX model.
- Generate a short non-streaming response.
- Load configured local Qwen3 embedding model.
- Produce one embedding and verify dimensions.
- Measure memory before/after unload.

Exit criteria:

- Both models work from local paths.
- Basic unload behavior is understood.

### Phase 1 — OpenAI API MVP

Goals:

- Add local HTTP server.
- Add `GET /v1/models`.
- Add non-streaming `POST /v1/chat/completions`.
- Add OpenAI-shaped errors.
- Add basic settings for model aliases and local folders.

Exit criteria:

- A generic OpenAI-compatible client can send one local chat request.

### Phase 2 — Embeddings + streaming

Goals:

- Add `POST /v1/embeddings`.
- Add `stream: true` SSE for chat completions.
- Add runtime cancellation on disconnect.
- Add model validation buttons.

Exit criteria:

- Chat and embeddings work with common OpenAI-style clients.

### Phase 3 — Lifecycle hardening

Goals:

- Add idle unload timer.
- Add unload buttons.
- Add bounded request queue.
- Add local API key option.
- Add memory tests.

Exit criteria:

- Runtime is stable enough for daily use inside OKBrainCC.

### Phase 4 — Optional helper-process runtime

Only do this if memory release or crash isolation is inadequate in-process.

Goals:

- Move MLX model loading/inference to a bundled helper.
- Keep public OpenAI API server in OKBrainCC.
- Terminate helper after idle timeout for strict memory release.

## 16. Final recommendation

Build the smaller OpenAI-compatible MLX API first.

Do not build:

- Ollama-compatible endpoints.
- Model downloads.
- `/api/pull`.
- OKProxy-style installer flows.
- Broad model registry/manifest features.

Do build:

- Local model path configuration.
- `GET /v1/models`.
- `POST /v1/chat/completions`.
- `POST /v1/embeddings`.
- SSE streaming for chat.
- Basic validation/test UI.
- Idle unload after 5 minutes.
- Clear OpenAI-shaped errors.

This gives OKBrainCC a practical local OpenAI-compatible API with far less complexity than an Ollama-compatible runtime.
