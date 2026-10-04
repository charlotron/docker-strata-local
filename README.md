# Local Strata server (Docker)

Runs [Strata](https://github.com/Niko1221/Strata) inside Docker on an NVIDIA
GPU and connects OpenCode to it. Strata serves Qwen3.8-Flash-Next, a
125B-parameter MoE, on a consumer PC by keeping the most used experts on the
GPU and mapping the rest from disk.

Sibling of `docker-llama-local`: same layout, same port (12345), same client
workflow. Only one of the two can run at a time on a 12 GB GPU, and each
launcher stops the other's containers first.

## Architecture

- **Image**: built locally from Strata's own `Dockerfile` at a pinned commit
  (`STRATA_REF`). The CUDA engine is compiled from source during the build; no
  prebuilt binary is downloaded.
- **Data dir** (`STRATA_DATA_DIR`, mounted at `/data`): model shards, the
  prepared pack, the MTP draft layer and the install config. The first start
  downloads the model into it (~58 GB for the Coder); later starts serve
  straight away.
- **API** on port 12345: web UI at `/`, OpenAI at `/v1` (chat completions,
  responses), Anthropic at `/v1/messages`, plus `/health`, `/props`, `/slots`.

## Quick start

### 1. Prerequisites

- Windows with WSL2 and Docker Desktop (WSL backend), NVIDIA driver 580+.
- **WSL2 memory limit at 28 GB** (see AGENTS.md):
  ```ini
  # %USERPROFILE%\.wslconfig
  [wsl2]
  memory=28GB
  swap=8GB
  ```
  then `wsl --shutdown` from PowerShell.
- ~70 GB free on the disk holding `STRATA_DATA_DIR`. Use native WSL storage
  (e.g. `/home/<user>/data/strata`), never a `/mnt/<drive>` path.
- OpenCode (`npm install -g opencode-ai`), `jq`, `node`.

### 2. Configuration

```bash
cp .env.gpu.strata-coder.sample .env.gpu.strata-coder
# edit .env.gpu.strata-coder: set STRATA_DATA_DIR
```

| Profile | Model | When |
| --- | --- | --- |
| `.env.gpu.strata-coder.sample` | Qwen3.8-Flash-Next Coder (IQ1_M) | Coding agents on 32 GB RAM. The only Strata model that fits 32 GB. |

With 48 GB of RAM or more, `STRATA_FAMILY=qwen` and `STRATA_MODEL=IQ2_XS`
(or `Q2_0`) keep every expert and are better outside code.

### 3. Launch

```bash
./scripts/docker/launch-server.sh .env.gpu.strata-coder
```

The first run builds the image (10-30 min) and downloads the model; the
script waits until `/health` answers (up to `STRATA_START_TIMEOUT`, 3 h by
default).

### 4. Run OpenCode

```bash
./scripts/clients/opencode-strata.sh
```

`opencode-strata-yolo.sh` skips permission prompts.

## Maintenance

- **Logs**: `./scripts/docker/attach-server-logs.sh`
- **Stop**: `./scripts/docker/stop-all-servers.sh`
- **Live status**: the web UI's Monitor tab, or `curl -s localhost:12345/v1/status | jq`
- **Change context, KV or API key** for a model already set up: they are
  recorded in its config on the data dir. Edit the env file and launch once
  with `REINSTALL=1 ./scripts/docker/launch-server.sh ...`.
- **Update Strata**: bump `STRATA_REF` to a newer commit; the launcher builds
  the new image on the next start. Remove old images with
  `docker image rm strata-local:<old-ref>`.
