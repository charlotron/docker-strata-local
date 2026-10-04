# AGENTS.md

Operational notes for anyone (human or agent) launching Strata in this repo.

## Profile files: what's tracked vs. what's real

- **`.env.gpu.<profile>.sample`** (tracked): the reference config for one
  profile, with `STRATA_DATA_DIR=""` left blank on purpose. Never edit these.
- **`.env` / `.env.gpu.<profile>`** (gitignored, host-specific): copied from a
  sample, with the host's `STRATA_DATA_DIR` filled in.

`launch-server.sh` uses `.env` with no argument, or the file passed as the
first argument.

## The WSL2 memory limit

Docker Desktop runs inside the WSL2 VM, so the VM's `memory=` in
`%USERPROFILE%\.wslconfig` is all the RAM Strata can get, whatever the host
has. On a 32 GB host:

- **28 GB** is the setting: Windows keeps ~4 GB, the container is capped at
  26 GB (`mem_limit`) so a runaway kills the container, not the VM.
- **Never 32 GB** (the whole host): the VM can then take everything, Windows
  pages to a small pagefile, and the desktop freezes for minutes. Locked
  (`memlock`) pages cannot be paged out, which makes it worse.
- The `llama.cpp` profiles in `docker-llama-local` run fine under the same
  limit.

Changing it needs `wsl --shutdown`, which also stops Docker Desktop and any
SSH server running inside WSL.

## Why LOW_RAM=on

Strata's setup sizes itself from `/proc/meminfo`. The Coder needs its ~23 GB
of experts plus ~10 GB of headroom to keep them all in RAM, which does not fit
28 GB. With `LOW_RAM=on` the experts are mapped from the data dir, the GPU
holds the most used ones, and the rest come through the page cache. That makes
the data dir's disk speed matter: keep it on native WSL storage.

## Context and VRAM

Under WSL, Strata cannot stream the KV cache to RAM (the driver pins only
~1 GB), so the whole KV cache stays in VRAM and competes with the experts
cached there. The model is hybrid and the KV cache is small (~0.9 GB at 128K
with `q4_0`), but a bigger context still means fewer experts on the GPU and
slower decoding. If the log reports little free VRAM, lower
`STRATA_CONTEXT_SIZE` (65536) before anything else.

Context, KV type, vision and API key are written into the model's config on
the first start. Changing them in the env file does nothing until a launch
with `REINSTALL=1`.

## Port and GPU sharing

Strata listens on 12345, the same port as the llama.cpp profiles, so OpenCode
and other clients need no changes. Keep it that way. The launcher stops every
`llama-cpp*` and `strata*` container before starting. The `docker-llama-local`
launcher only stops `llama-cpp*`, so stop Strata first
(`scripts/docker/stop-all-servers.sh`) before going back to it.
