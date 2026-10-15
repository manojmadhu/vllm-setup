#!/usr/bin/env bash
# =============================================================================
# 01-install-host.sh — prepare an Azure Ubuntu 22.04/24.04 GPU VM
#   * NVIDIA data-center driver
#   * Docker Engine + Compose plugin (official Docker repo)
#   * NVIDIA Container Toolkit (GPU access for containers)
#   * Docker log rotation
# Run as a sudo-capable user:  sudo bash scripts/01-install-host.sh
# A REBOOT is required after the driver installs; re-run the script afterwards
# and it will skip finished steps and run the GPU container test.
# =============================================================================
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }
. /etc/os-release
[[ "${ID}" == "ubuntu" ]] || { echo "This script supports Ubuntu only (found ${ID})"; exit 1; }

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

log "Base packages"
apt-get update -y
apt-get install -y ca-certificates curl gnupg jq bc openssl lsb-release ubuntu-drivers-common

# ---- 1. NVIDIA driver --------------------------------------------------------
if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi >/dev/null 2>&1; then
  log "Installing NVIDIA data-center (server) driver"
  lspci | grep -i nvidia || { echo "No NVIDIA GPU visible. Check the VM size."; exit 1; }
  # 580 server branch (>= 580 needed by the CUDA 13 vLLM image). ubuntu-drivers
  # picks Canonical's prebuilt, signed modules for the linux-azure kernel, so it
  # works with Trusted Launch / Secure Boot. --gpgpu = headless compute stack,
  # which does NOT include nvidia-smi, hence nvidia-utils.
  ubuntu-drivers install --gpgpu nvidia:580-server
  apt-get install -y nvidia-utils-580-server
  echo
  echo "Driver installed. REBOOT now (sudo reboot), then re-run this script."
  exit 0
fi

DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
GPU_CC=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1 || echo "?")
log "GPU: ${GPU_NAME} | compute capability ${GPU_CC} | driver ${DRIVER_VER}"
DRIVER_MAJOR=${DRIVER_VER%%.*}
if (( DRIVER_MAJOR < 580 )); then
  echo "NOTE: driver ${DRIVER_VER} < 580. The default vLLM image needs CUDA 13 (driver >= 580)."
  echo "      Either upgrade the driver or set VLLM_IMAGE=vllm/vllm-openai:v0.31.0-cu129 in .env"
fi
if [[ "${GPU_CC}" == "7.0" ]]; then
  echo "NOTE: V100 (SM70) detected: use the -cu129 vLLM image and a GPTQ (not AWQ) model."
fi

# ---- 2. Docker Engine --------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker Engine"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# Log rotation + live-restore (containers survive a dockerd restart)
log "Configuring Docker daemon"
mkdir -p /etc/docker
if [[ ! -s /etc/docker/daemon.json ]]; then echo '{}' > /etc/docker/daemon.json; fi
tmp=$(mktemp)
jq '. + {"log-driver":"json-file","log-opts":{"max-size":"50m","max-file":"5"},"live-restore":true}' \
  /etc/docker/daemon.json > "$tmp" && mv "$tmp" /etc/docker/daemon.json

# ---- 3. NVIDIA Container Toolkit ---------------------------------------------
if ! command -v nvidia-ctk >/dev/null 2>&1; then
  log "Installing NVIDIA Container Toolkit"
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -y
  apt-get install -y nvidia-container-toolkit
fi
nvidia-ctk runtime configure --runtime=docker
systemctl enable --now docker
systemctl restart docker

# Let the invoking admin user run docker without sudo
if [[ -n "${SUDO_USER:-}" ]]; then usermod -aG docker "${SUDO_USER}"; fi

# ---- 4. Persistence mode (faster, steadier GPU init) -------------------------
nvidia-smi -pm 1 || true

# ---- 5. Smoke test -----------------------------------------------------------
log "Testing GPU access from a container"
docker run --rm --gpus all ubuntu:24.04 nvidia-smi

log "Host ready. Log out/in so the docker group applies, then run scripts/02-init-secrets.sh"
