#!/usr/bin/env bash
# =============================================================================
# 04-download-model.sh — pull images and download model weights once.
# vLLM later runs on an internal network with HF_HUB_OFFLINE=1.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source <(grep -E '^MODEL_ID=' .env)

echo "Pulling container images (vLLM image is ~10 GB)..."
docker compose pull
docker compose --profile setup pull model-download

echo "Downloading ${MODEL_ID} into the hf_cache volume..."
docker compose --profile setup run --rm model-download

echo "Done. Start the stack with:  docker compose up -d"
