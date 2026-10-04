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

- **28 GB** is the setting: Windows keeps ~4 GB.
- **Never 32 GB** (the whole host): the VM can then take everything, Windows
  pages to a small pagefile, and the desktop freezes for minutes.
- Add `kernelCommandLine=transparent_hugepage=madvise` to the same section.
  With the WSL kernel's default (`always`), allocating ~20 GB next to a full
  page cache triggers direct compaction stalls: mmap page faults went from
  0.2 ms to 10+ ms and the engine stalled. `wsl --shutdown` applies it; until
  then `echo madvise | sudo tee /sys/kernel/mm/transparent_hugepage/enabled`.

Changing `.wslconfig` needs `wsl --shutdown`, which also stops Docker Desktop
and any SSH server running inside WSL.

## How the Coder fits (resident low-RAM mode)

The Coder has ~23 GB of experts. The GPU caches the 1948 hottest (3.75 GB);
the other **19.67 GiB** must be in RAM, or the engine reads them through mmap
page faults and stalls. The compose file makes that happen:

- `LOW_RAM=on` + setup's `--resident-experts` pick: the engine copies the
  experts the GPU does not hold into RAM at start (~1-2 min).
- `STRATA_RESIDENT_PIN=0`: the copy is pageable. Page-locking 20 GB under
  WSL2 took 15+ min and pushed the VM into swap.
- `STRATA_RESIDENT_BUDGET_GIB=20` (a local entrypoint patch writes it as
  `--resident-budget-gib` into the model config): exactly the 19.67 GiB.
  Without it the engine also grabs the prompt path's experts (22.8 GiB) and
  the VM runs out of memory.
- `STRATA_RESIDENT_HEADROOM_GIB=1`: the engine's own safety margin (default
  4 GB) would otherwise cut the copy to ~13 GB.
- No `mem_limit`: under cgroup v1, Strata reads "limit - usage" as free RAM,
  and usage counts reclaimable page cache, so any cap shrinks the copy.

A healthy start logs `resident 19.67 GiB` and leaves ~4 GB available in the VM.

## Local patches (docker/strata)

The image is Strata's own (`strata-upstream:<ref>`) plus:

- `patches/0001-cgroup-hybrid-v1-fallback.patch` (engine, rebuilt): Docker
  Desktop on WSL2 runs a hybrid cgroup hierarchy. `/proc/self/cgroup` has a
  `0::/docker/<id>` line but no cgroup2 mount is visible, and upstream gives
  up ("cannot determine available RAM"), which silently disables the resident
  mode. The patch falls back to the v1 memory controller.
- `script-patches/0001-resident-budget-env.patch`: `STRATA_RESIDENT_BUDGET_GIB`
  support in `docker-entrypoint.sh`.

When bumping `STRATA_REF`, check whether upstream fixed these and drop the
patch, or refresh it if it no longer applies.

## Stall watchdog

The engine kills itself after 60 s without progress (`no progress for 60 s`;
the request gets a 503 and the next one restarts it). A cold first long prompt
reads the experts its chunk displaces from disk and one layer can take longer
than that. `STRATA_WATCHDOG_S=300` gives it room; a real hang still ends.

## Interrupted downloads

If the network drops during the first start, Strata's downloader can keep
failing with `Connection refused` after the network is back.
`docker restart <container>` resumes from the `.part` file.

## Requests through another host name

Strata refuses requests whose `Host` header is not one it answers to
(`refused a request for Host '...'`). A reverse proxy in front of it needs
that name in `allowed_hosts` / `STRATA_ALLOWED_HOSTS`, or an API key.

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
