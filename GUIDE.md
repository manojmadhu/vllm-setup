# Enterprise vLLM on an Azure 16 GB GPU VM — Setup Guide

This package runs a quantized 14B model with vLLM in Docker, behind a hardened Nginx gateway, with Prometheus, Grafana and Alertmanager for monitoring. It targets an Azure VM with one 16 GB NVIDIA GPU (NCasT4_v3 series, Tesla T4).

## 1. What you are deploying

```text
 Internal apps (RAG, agents, APIs)
            │  HTTPS :443 + per-app API key
            ▼
 ┌──────────────── Azure VM (private IP only) ────────────────┐
 │  gateway (Nginx)  TLS · key auth · rate limits · allow-list │
 │        │  internal Docker network (no internet, no ports)   │
 │        ▼                                                    │
 │  vllm  :8000  Qwen2.5-14B-Instruct-AWQ on the T4            │
 │                                                             │
 │  prometheus ─ alertmanager ─ grafana   (127.0.0.1 only)     │
 │  dcgm-exporter (GPU) · node-exporter (host) · nginx-exporter│
 └─────────────────────────────────────────────────────────────┘
            ▲
   Admin workstation ── SSH tunnel ── Grafana / Prometheus / Alertmanager
```

| Service | Where it listens | Who can reach it |
|---|---|---|
| vLLM API | `vllm:8000` inside the `llm_internal` network only | Only the gateway and Prometheus. Never published on the host. |
| Gateway | `<VM private IP>:443` | Apps in your VNet that hold a client key |
| Prometheus | `127.0.0.1:9090` | Admins via SSH tunnel |
| Alertmanager | `127.0.0.1:9093` | Admins via SSH tunnel |
| Grafana | `127.0.0.1:3000` | Admins via SSH tunnel |
| Exporters | internal only | Prometheus |

**How the vLLM port is protected (defence in depth):**
- **No published port.** `compose.yaml` has no `ports:` for vLLM, so port 8000 does not exist on the VM or the VNet.
- **Internal-only network.** vLLM sits on a Docker network created with `internal: true`, so it has no route to the internet and runs offline (`HF_HUB_OFFLINE=1`).
- **Separate keys.** Apps authenticate to the gateway with their own keys. The gateway swaps in a separate internal key (`VLLM_API_KEY`) that only it and vLLM know.
- **Endpoint allow-list.** Only `/v1/chat/completions`, `/v1/completions`, `/v1/models` and `/health` pass through. `/metrics`, `/tokenize`, `/docs` and admin routes return 404.
- **Azure NSG.** Allows 443 only from your app subnets and 22 only from Bastion or admin IPs (step 9).

**Rate limiting and back-pressure, layered:**
- **Per app key:** 60 requests/min with a burst of 20, set in `.env`.
- **Per app key:** at most 4 requests in flight at once.
- **Per source IP:** 20 requests/s, which slows key guessing.
- **Inside vLLM:** at most 8 sequences run concurrently, and beyond 32 queued requests new ones are rejected instead of waiting forever.
- **Responses:** callers get JSON `429` with `Retry-After`, or `503` while the model is starting.

## 2. Before you start (Azure)

**VM**
- **Size:** `Standard_NC4as_T4_v3` (4 vCPU, 28 GB RAM, T4 16 GB). `NC8as_T4_v3` gives more RAM and CPU headroom for the tokenizer and RAG pre-processing.
- **Image:** Ubuntu Server 24.04 LTS (22.04 also works).
- **OS disk:** 256 GB Premium SSD. The vLLM image is about 10 GB, the model about 10 GB, plus metrics and logs.
- **Networking:** no public IP. Place the VM in a private subnet and reach it with Azure Bastion or a VPN.
- **Trusted Launch / Secure Boot:** the Ubuntu-signed driver installed by the script works with Secure Boot. If you install drivers manually, use signed packages or disable Secure Boot.

**Accounts and inputs you'll need**
- An internal DNS name for the gateway, for example `llm.internal.yourcompany.com`, pointing at the VM's private IP.
- A TLS certificate for that name from your internal CA. The package can generate a temporary self-signed one.
- Somewhere to send alerts: email/SMTP, a Teams workflow URL, or a webhook.

**Memory budget on a T4 (why the defaults are what they are)**

| Item | Approx. |
|---|---|
| Usable VRAM at `GPU_MEMORY_UTILIZATION=0.90` | ~13.5 GB |
| Qwen2.5-14B AWQ weights (4-bit) | ~10 GB |
| Activations and CUDA graphs | ~0.5–1 GB |
| KV cache left (≈190 KB per token) | ~2.5–3 GB, about 12–15k tokens total |

So the defaults are an 8k context (`MAX_MODEL_LEN=8192`) with up to 8 concurrent sequences. Expect roughly 10–25 generated tokens/s per stream on a T4. Measure your own with the smoke test.

## 3. Step 1 — copy the package to the VM

From your workstation (through Bastion or VPN):

```bash
scp vllm-enterprise.zip <admin>@<vm-private-ip>:/tmp/
ssh <admin>@<vm-private-ip>
sudo apt-get install -y unzip
sudo mkdir -p /opt && sudo unzip /tmp/vllm-enterprise.zip -d /opt/
sudo mv /opt/vllm-enterprise /opt/vllm
sudo chown -R $USER:$USER /opt/vllm
cd /opt/vllm && chmod +x scripts/*.sh
```

## 4. Step 2 — install driver, Docker and the NVIDIA Container Toolkit

```bash
sudo bash scripts/01-install-host.sh     # installs the NVIDIA driver
sudo reboot
# reconnect, then run it again to finish Docker + toolkit + GPU test
cd /opt/vllm && sudo bash scripts/01-install-host.sh
exit                                    # log out/in so the docker group applies
```

The second run ends with `nvidia-smi` output printed from inside a container.

The script prints the driver version. The default image `vllm/vllm-openai:v0.31.0` is built on CUDA 13 and needs driver 580 or newer. If you are on an older driver, set `VLLM_IMAGE=vllm/vllm-openai:v0.31.0-cu129` in `.env` (next step).

## 5. Step 3 — configure secrets and settings

```bash
cd /opt/vllm
bash scripts/02-init-secrets.sh
```

This does four things:
- Creates `.env` (mode 600) from `.env.example`.
- Generates the internal `VLLM_API_KEY` and the Grafana admin password.
- Detects the VM's private IP for `GATEWAY_BIND_IP`.
- Creates the first client key, `admin-test`. **Copy that key now — it is printed once.**

Then review `.env`:

```bash
nano .env
```

| Setting | What to check |
|---|---|
| `GATEWAY_BIND_IP` | The VM's private IP (`ip -4 addr`). Never `0.0.0.0` on a VM with a public IP. |
| `GATEWAY_SERVER_NAME` | Your internal DNS name for the gateway |
| `MODEL_ID` | Default `Qwen/Qwen2.5-14B-Instruct-AWQ`. Any 14B-class AWQ checkpoint works the same way. |
| `RATE_LIMIT_PER_CLIENT`, `RATE_LIMIT_BURST`, `MAX_CONCURRENT_PER_CLIENT` | Fairness between apps |
| `MAX_MODEL_LEN`, `MAX_NUM_SEQS` | Context length versus concurrency trade-off |

## 6. Step 4 — TLS certificate

A self-signed certificate was generated in `nginx/certs/` for testing. For production, replace it with your CA-issued one:

```bash
cp /path/llm.internal.yourcompany.com.crt nginx/certs/tls.crt   # include the intermediate chain
cp /path/llm.internal.yourcompany.com.key nginx/certs/tls.key
chmod 600 nginx/certs/tls.key
```

If you change `GATEWAY_SERVER_NAME` or `GATEWAY_BIND_IP` after generating the self-signed certificate, re-run `bash scripts/03-gen-self-signed-cert.sh`.

## 7. Step 5 — download the model (one time)

```bash
bash scripts/04-download-model.sh
```

This pulls all images and downloads the weights into the `hf_cache` volume using a short-lived container on an egress network. vLLM itself never needs internet access afterwards.

## 8. Step 6 — start the stack

```bash
docker compose up -d
docker compose logs -f vllm
```

First start takes about 3–10 minutes (weight loading plus kernel and CUDA-graph warm-up). In the log, look for:
- `Using AWQ` or similar, confirming quantization is active.
- An attention backend line. On a T4 (SM75) expect a Triton backend; FlashAttention 2 needs SM80+.
- `GPU KV cache size: N tokens` — this should be above `MAX_MODEL_LEN`.
- `Application startup complete`.

Then check that everything is healthy:

```bash
docker compose ps        # vllm and gateway should show (healthy)
nvidia-smi               # ~13–14 GB used by the vllm process
```

## 9. Step 7 — smoke test

```bash
bash scripts/smoke-test.sh <admin-test-key>
```

The test checks that:
- Port 8000 is closed on the host.
- `/health` returns 200.
- Requests without a key, or with a wrong key, get 401.
- `/metrics` and `/tokenize` are hidden (404).
- `/v1/models` returns 200 with a valid key.
- A real chat completion succeeds, and it reports tokens/s.
- Rapid calls trigger 429.

## 10. Step 8 — lock down the network (Azure NSG)

On the VM's NSG, set these inbound rules, in priority order:

| Priority | Source | Port | Action |
|---|---|---|---|
| 100 | App subnets / VNet ranges that call the LLM | TCP 443 | Allow |
| 110 | AzureBastionSubnet or admin IPs | TCP 22 | Allow |
| 4000 | Any | Any | Deny |

Then verify from a machine in an allowed subnet:

```bash
curl --cacert tls.crt https://llm.internal.yourcompany.com/health   # 200
nc -vz <vm-ip> 8000                                                  # must fail
nc -vz <vm-ip> 3000                                                  # must fail
```

## 11. Step 9 — open the dashboards through an SSH tunnel

Run this **on your workstation**, not on the VM:

```bash
ssh -N \
  -L 3000:127.0.0.1:3000 \
  -L 9090:127.0.0.1:9090 \
  -L 9093:127.0.0.1:9093 \
  <admin>@<vm-private-ip>
```

With Azure Bastion, use the native client tunnel instead: `az network bastion tunnel ... --resource-port 22 --port 2222`, then `ssh -p 2222 -N -L ... <admin>@127.0.0.1`.

Keep the tunnel open, then browse to these addresses:

| Tool | URL | What to check |
|---|---|---|
| Grafana | http://127.0.0.1:3000 | Log in with `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` from `.env`, then open **Enterprise LLM → Enterprise LLM — vLLM, GPU & Gateway** |
| Prometheus | http://127.0.0.1:9090/targets | All 6 targets show **UP** |
| Alertmanager | http://127.0.0.1:9093 | Active alerts and silences |

The dashboard covers:
- Requests running and waiting
- KV-cache use
- Prompt and generation tokens/s
- Time-to-first-token and end-to-end latency (p50/p95)
- HTTP status codes
- Gateway connections
- GPU utilisation, VRAM, temperature and power
- Host CPU, memory and disk

## 12. Step 10 — wire up alerts

Edit `alertmanager/alertmanager.yml` and uncomment one receiver: email, a Teams workflow URL, or a webhook. Then restart and check the config loaded:

```bash
docker compose restart alertmanager
docker compose logs alertmanager | tail
```

The included rules in `prometheus/rules/llm-alerts.yml`:

| Area | Alerts |
|---|---|
| Availability | vLLM down, gateway down, exporter down |
| Inference | Queue backlog, KV cache > 95%, p95 TTFT > 10 s, 5xx rate > 5%, preemptions |
| GPU | Temperature > 85 °C, XID hardware errors, GPU idle while requests wait |
| Host | Disk < 15% free, RAM < 10% free, CPU > 90% |

## 13. Step 11 — onboard applications

Give every app its own key, so each gets its own rate-limit bucket and appears by name in the logs:

```bash
bash scripts/manage-keys.sh add rag-service      # prints the key once
bash scripts/manage-keys.sh add support-agent
bash scripts/manage-keys.sh list
bash scripts/manage-keys.sh revoke admin-test    # once real clients exist
```

Store each key in Azure Key Vault. Adding or revoking a key reloads Nginx gracefully, without dropping connections.

**Python (OpenAI SDK):**

```python
import os, httpx
from openai import OpenAI

client = OpenAI(
    base_url="https://llm.internal.yourcompany.com/v1",
    api_key=os.environ["LLM_API_KEY"],                 # from Key Vault
    http_client=httpx.Client(verify="/etc/ssl/certs/internal-ca.pem", timeout=600),
)

resp = client.chat.completions.create(
    model="enterprise-llm",                            # SERVED_MODEL_NAME
    messages=[{"role": "system", "content": "Answer only from the provided context."},
              {"role": "user", "content": "Context: ...\n\nQuestion: ..."}],
    temperature=0.2, max_tokens=512, stream=True,
)
for chunk in resp:
    print(chunk.choices[0].delta.content or "", end="")
```

**Agents and tool calling:** pass `tools=[...]` as you would with the OpenAI API. The server runs with `--enable-auto-tool-choice --tool-call-parser hermes`, which matches Qwen2.5. LangChain, LlamaIndex and Semantic Kernel work through their OpenAI-compatible clients pointed at the same base URL.

**Client rules of thumb on a T4:**
- Keep prompt plus output under about 8k tokens; trim RAG context to the top chunks.
- Always set `max_tokens`.
- Retry `429` and `503` with exponential backoff, honouring `Retry-After`.
- Use streaming for chat UIs.

## 14. Operations

| Task | Command |
|---|---|
| Status | `docker compose ps` |
| Logs (JSON, per client) | `docker compose logs -f gateway` |
| Restart model only | `docker compose restart vllm` |
| Change rate limits | Edit `.env`, then `docker compose up -d gateway` |
| Reload Prometheus rules | `curl -X POST http://127.0.0.1:9090/-/reload` |
| Stop everything | `docker compose down` (volumes and model are kept) |

All containers restart automatically after a crash or VM reboot (`restart: unless-stopped`, Docker enabled at boot, `live-restore`).

**Upgrading vLLM:**
1. Read the release notes for breaking flag changes.
2. Change `VLLM_IMAGE` in `.env`.
3. Run `docker compose pull vllm && docker compose up -d vllm`.
4. Re-run the smoke test.
5. To roll back, restore the old tag and run `up -d` again.

**Changing the model:**
1. Set `MODEL_ID` in `.env`.
2. Run `bash scripts/04-download-model.sh`, then `docker compose up -d vllm`.

Apps keep calling `enterprise-llm`, so nothing changes on their side.

**Backups:** back up `/opt/vllm` (config, `.env`, keys, certs) to a secure location. The model can be re-downloaded, and metrics history lives in the `prometheus_data` volume.

## 15. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `could not select device driver "nvidia"` | Toolkit not configured: `sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker` |
| `CUDA driver version is insufficient` | Driver older than 580: use the `-cu129` image tag, or upgrade the driver |
| Out of memory at startup | Lower `GPU_MEMORY_UTILIZATION` to 0.85 or `MAX_MODEL_LEN` to 6144, or uncomment `--enforce-eager` in `compose.yaml` |
| `KV cache ... smaller than max_model_len` | Reduce `MAX_MODEL_LEN` |
| `Bfloat16 is only supported on GPUs with compute capability >= 8.0` | Keep `DTYPE=half` on the T4 |
| vLLM tries to reach huggingface.co | The model wasn't downloaded: run `scripts/04-download-model.sh` (vLLM is offline by design) |
| Gateway returns 503 | vLLM is still starting or crashed: `docker compose logs vllm` |
| Gateway returns 401 with a valid key | Header must be exactly `Authorization: Bearer <key>`; confirm with `manage-keys.sh list` |
| Lots of 429s | Raise `RATE_LIMIT_PER_CLIENT` or `RATE_LIMIT_BURST` for fairness, but the GPU is the real limit — watch *Waiting requests* |
| Prometheus target `vllm` DOWN | `docker compose ps vllm`; it's expected during the first 10 minutes of startup |
| Some Grafana panels empty | Metric names differ by vLLM version; check names at http://127.0.0.1:9090 → Graph |

## 16. Production hardening checklist

- [ ] CA-issued certificate installed; self-signed certificate removed
- [ ] NSG: 443 only from app subnets, 22 only from Bastion; no public IP
- [ ] `admin-test` key revoked; one key per app, stored in Key Vault
- [ ] Alert receiver configured and a test alert received
- [ ] Azure Backup or snapshot policy on the OS disk; `/opt/vllm` config backed up
- [ ] Gateway logs shipped to Log Analytics or your SIEM (Azure Monitor Agent on the VM, or a log-forwarder container)
- [ ] Image tags reviewed quarterly; vLLM release notes checked for security fixes
- [ ] Load-tested at expected peak with the rate limits you set
