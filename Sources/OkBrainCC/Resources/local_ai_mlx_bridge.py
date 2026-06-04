#!/usr/bin/env python3
import argparse
import hashlib
import json
import math
import os
import sys


def read_payload():
    raw = sys.stdin.read()
    if not raw.strip():
        return {}
    return json.loads(raw)


def estimate_tokens(text):
    return max(1, len(str(text).split()))


def deterministic_embedding(text, dimensions=1024):
    digest = hashlib.sha256(str(text).encode("utf-8")).digest()
    values = []
    for i in range(dimensions):
        byte = digest[i % len(digest)]
        mixed = (byte + i * 31 + (i >> 1) * 17) % 2000
        values.append((mixed / 1000.0) - 1.0)
    norm = math.sqrt(sum(v * v for v in values)) or 1.0
    return [v / norm for v in values]


def command_chat(payload):
    model_path = payload.get("model_path")
    messages = payload.get("messages") or []
    max_tokens = int(payload.get("max_tokens") or 128)

    if not model_path:
        raise RuntimeError("model_path is required")

    try:
        from mlx_lm import generate, load
    except Exception as exc:
        raise RuntimeError(
            "mlx_lm is not installed. Run `OkBrainCC local-ai install-python-mlx` and pass --python .build/local-ai-venv/bin/python."
        ) from exc

    model, tokenizer = load(model_path)

    if getattr(tokenizer, "chat_template", None) is not None:
        prompt = tokenizer.apply_chat_template(messages, add_generation_prompt=True)
    else:
        prompt = "\n".join(f"{m.get('role', 'user')}: {m.get('content', '')}" for m in messages) + "\nassistant:"

    response = generate(model, tokenizer, prompt=prompt, verbose=False, max_tokens=max_tokens)

    try:
        prompt_tokens = len(tokenizer.encode(prompt))
        completion_tokens = len(tokenizer.encode(response))
    except Exception:
        prompt_tokens = estimate_tokens(prompt)
        completion_tokens = estimate_tokens(response)

    print(json.dumps({
        "content": response,
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
    }))


def command_embed(payload):
    inputs = payload.get("input") or []
    dimensions = int(payload.get("dimensions") or 1024)

    # The production Swift API shape is tested even when a dedicated embedding runtime is
    # not installed. If mlx_embeddings is available, future revisions can replace this
    # deterministic fallback with real pooled vectors for configured embedding models.
    embeddings = [deterministic_embedding(text, dimensions=dimensions) for text in inputs]
    print(json.dumps({
        "embeddings": embeddings,
        "prompt_tokens": estimate_tokens(" ".join(inputs)),
        "fallback": True,
    }))


def command_download(payload):
    repo = payload.get("repo") or "mlx-community/Qwen3-0.6B-4bit"
    local_dir = payload.get("local_dir")
    if local_dir:
        local_dir = os.path.abspath(os.path.expanduser(local_dir))
        os.makedirs(local_dir, exist_ok=True)

    try:
        from huggingface_hub import snapshot_download
    except Exception as exc:
        raise RuntimeError(
            "huggingface_hub is not installed. Run `OkBrainCC local-ai install-python-mlx` and pass --python .build/local-ai-venv/bin/python."
        ) from exc

    path = snapshot_download(
        repo_id=repo,
        local_dir=local_dir,
        allow_patterns=[
            "*.json",
            "*.safetensors",
            "tokenizer*",
            "*.model",
            "*.txt",
            "*.md",
        ],
    )
    print(json.dumps({"repo": repo, "path": path}))


def main():
    parser = argparse.ArgumentParser(description="OKBrainCC local MLX bridge")
    parser.add_argument("command", choices=["chat", "embed", "download"])
    args = parser.parse_args()

    try:
        payload = read_payload()
        if args.command == "chat":
            command_chat(payload)
        elif args.command == "embed":
            command_embed(payload)
        elif args.command == "download":
            command_download(payload)
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
