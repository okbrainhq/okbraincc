#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-11539}"
PYTHON="${PYTHON:-.build/local-ai-venv/bin/python}"
MODEL_DIR="${MODEL_DIR:-.build/local-ai-models/qwen3-0.6b-4bit}"
REPO="${REPO:-mlx-community/Qwen3-0.6B-4bit}"

swift build

.build/debug/OkBrainCC local-ai e2e --runtime mock --port 11538

if [[ ! -x "$PYTHON" ]]; then
  .build/debug/OkBrainCC local-ai install-python-mlx --venv .build/local-ai-venv
fi

.build/debug/OkBrainCC local-ai e2e \
  --runtime mlx-python \
  --python "$PYTHON" \
  --port "$PORT" \
  --chat-alias qwen3:0.6b \
  --download-tiny-model \
  --repo "$REPO" \
  --local-dir "$MODEL_DIR"
