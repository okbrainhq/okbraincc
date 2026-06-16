# OkBrainCC

macOS SwiftUI utility app for OKBrain workflows.

## OKProxy Client

The **OKProxy Client** section can clone/update OKProxy, manage Node.js, and run the local client.

### Client Configuration

Configure the server host, target host, client certificate, client key, CA certificate, and whether multipath is enabled. Turning off **Enable multipath** starts the client without the `--multipath` flag.

## Local OpenAI API

OkBrainCC includes a **Local AI** section and a headless CLI for exposing configured local MLX model folders through a small OpenAI-compatible API.

### API endpoints

- `GET /health`
- `GET /v1/models`
- `POST /v1/chat/completions`
- `POST /v1/embeddings`

The implementation intentionally does **not** add Ollama-compatible `/api/*` endpoints.

### Headless CLI

Build first:

```bash
swift build
```

Run the deterministic E2E runtime:

```bash
.build/debug/OkBrainCC local-ai e2e --runtime mock --port 11538
```

Install Python MLX bridge dependencies for model-backed E2E testing:

```bash
.build/debug/OkBrainCC local-ai install-python-mlx --venv .build/local-ai-venv
```

Download a tiny MLX chat model for E2E testing:

```bash
.build/debug/OkBrainCC local-ai download-tiny-model \
  --python .build/local-ai-venv/bin/python \
  --repo mlx-community/Qwen3-0.6B-4bit \
  --local-dir .build/local-ai-models/qwen3-0.6b-4bit
```

Run model-backed E2E:

```bash
scripts/e2e-local-ai.sh
```

Or run it manually:

```bash
.build/debug/OkBrainCC local-ai e2e \
  --runtime mlx-python \
  --python .build/local-ai-venv/bin/python \
  --port 11539 \
  --chat-alias qwen3:0.6b \
  --download-tiny-model \
  --repo mlx-community/Qwen3-0.6B-4bit \
  --local-dir .build/local-ai-models/qwen3-0.6b-4bit
```

Serve manually:

```bash
.build/debug/OkBrainCC local-ai serve \
  --runtime mlx-python \
  --python .build/local-ai-venv/bin/python \
  --chat-alias qwen3:0.6b \
  --chat-path .build/local-ai-models/qwen3-0.6b-4bit \
  --embedding-path .build/local-ai-models/qwen3-0.6b-4bit
```

Then point OpenAI-compatible clients at:

```text
base_url = http://127.0.0.1:11535/v1
api_key = okbraincc-local
model = qwen3:0.6b
```

### GUI

Open **Local AI** in the sidebar to configure:

- Simple model list with an **Add Model** dialog
- Add Model supports Chat/Embedding, model name, Local folder, or Hugging Face repo/URL download with progress
- Collapsible hint section for model type guidance, download locations, and recommended MLX starting points
- Chat panel with a model picker and transcript
- Server status, base URL, runtime selection, and auth settings
- Validation/test actions, idle unload controls, and runtime logs

After changing model rows, restart the local server so `/v1/models` and API clients see the updated catalog.

## Development vs Production

The app supports two isolated environments so local development never touches production state.

| Mode | Command | Bundle | Bundle ID | State directories |
|------|---------|--------|-----------|-------------------|
| Dev (default) | `./scripts/build.sh` | `dist/OkBrainCC-Dev.app` | `com.okbraincc.app.dev` | `~/okproxy-dev` (install), `~/.okproxy-dev` (logs), `~/okrun-switch-dev` (install), `~/.okrun-switch-dev` (logs), `~/okbraincc-backups-dev` |
| Prod | `./scripts/build.sh --prod` | `dist/OkBrainCC.app` | `com.okbraincc.app` | `~/okproxy` (install), `~/.okproxy` (logs), `~/okrun-switch` (install), `~/.okrun-switch` (logs), `~/okbraincc-backups` |

Build and run the dev app:

```bash
./scripts/run.sh
./scripts/run.sh --dev
```

Build and run the production app:

```bash
./scripts/run.sh --prod
```

Run the full test pass:

```bash
./scripts/test.sh
```

Dev/prod isolation covers:

- Separate UserDefaults suites (dev uses `com.okbraincc.app.dev`)
- Separate on-disk install/log/backup directories
- Separate bundle IDs, so dev and prod apps can run side by side
- `NODE_ENV=development` for dev services, `NODE_ENV=production` for prod services
- Dev builds default to not auto-launching the configured OKRun VM app

You can override the environment at runtime with `--dev`/`--prod` launch arguments or the `OKBRAINCC_ENV` environment variable.
