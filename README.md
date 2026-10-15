# vllm-enterprise

Docker Compose package for serving a quantized 14B LLM with vLLM on an Azure VM with one 16 GB NVIDIA GPU (Tesla T4). It sits behind an Nginx gateway that handles TLS, per-app API keys, rate limits and an endpoint allow-list, and comes with Prometheus, Grafana, Alertmanager and GPU/host exporters.

Full step-by-step instructions are in **GUIDE.md**.

## Quick start (on the VM)

```bash
sudo bash scripts/01-install-host.sh && sudo reboot      # driver
sudo bash scripts/01-install-host.sh                     # docker + toolkit + GPU test
bash scripts/02-init-secrets.sh                          # .env, secrets, first key, temp cert
bash scripts/04-download-model.sh                        # images + model weights (one time)
docker compose up -d && docker compose logs -f vllm      # wait for "startup complete"
bash scripts/smoke-test.sh <client-key>                  # security + inference checks
```

## Layout

```text
compose.yaml                     all services, networks, volumes
.env.example                     every tunable (images, model, limits, binding)
nginx/nginx.conf                 key map, JSON access log
nginx/templates/*.template       TLS server, rate limits, allow-list, key swap
nginx/api-keys/keys.map          per-app keys (created by scripts, git-ignored)
nginx/certs/                     tls.crt / tls.key (git-ignored)
prometheus/prometheus.yml        scrape jobs
prometheus/rules/llm-alerts.yml  14 alert rules
alertmanager/alertmanager.yml    routing (add email / Teams / webhook)
grafana/                         datasources + "Enterprise LLM" dashboard
scripts/                         install, secrets, cert, download, keys, smoke test
```

## Pinned versions

| Component | Image |
|---|---|
| vLLM | `vllm/vllm-openai:v0.31.0` (or `-cu129` for drivers older than 580) |
| Nginx | `nginx:1.28-alpine` |
| Prometheus | `v3.5.0` |
| Alertmanager | `v0.28.1` |
| Grafana | `12.0.2` |
| Node exporter | `v1.9.1` |
| DCGM exporter | `4.6.0-4.8.4-distroless` |
| Nginx exporter | `1.4.2` |
