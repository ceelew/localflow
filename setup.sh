#!/bin/zsh
# Downloads the local LLM runtime (llama.cpp) and the cleanup model (Qwen3-4B-Instruct, Q4_K_M, ~2.5 GB).
# The speech model (Parakeet v3, ~600 MB) is downloaded by the app itself on first launch.
set -euo pipefail

LLAMA_BUILD="${LLAMA_BUILD:-b11739}"
MODEL_URL="https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
SUPPORT="$HOME/Library/Application Support/LocalFlow"

mkdir -p "$SUPPORT/llama" "$SUPPORT/models"

if [[ ! -x "$SUPPORT/llama/llama-server" ]]; then
  echo "Downloading llama.cpp $LLAMA_BUILD…"
  tmp=$(mktemp -d)
  curl -fL --progress-bar -o "$tmp/llama.tar.gz" \
    "https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_BUILD/llama-$LLAMA_BUILD-bin-macos-arm64.tar.gz"
  tar -xzf "$tmp/llama.tar.gz" -C "$tmp"
  server=$(find "$tmp" -name llama-server -type f | head -1)
  # llama-server needs the dylibs that ship next to it.
  cp -R "$(dirname "$server")"/. "$SUPPORT/llama/"
  rm -rf "$tmp"
fi

if [[ ! -f "$SUPPORT/models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf" ]]; then
  echo "Downloading Qwen3-4B-Instruct (Q4_K_M, ~2.5 GB)…"
  curl -fL --progress-bar -C - -o "$SUPPORT/models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf.part" "$MODEL_URL"
  mv "$SUPPORT/models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf.part" "$SUPPORT/models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
fi

echo "Setup complete: $SUPPORT"
