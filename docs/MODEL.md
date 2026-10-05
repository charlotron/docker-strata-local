# The model: Qwen3.8-Flash-Next Coder (IQ1_M)

What this repo serves, how big it really is, and where each part lives at run
time. Sources: Strata's `docs/HOW_IT_WORKS.md`, `docs/MODELS.md` and
`docs/DETAILS.md`, plus the engine logs of the reference host.

## Base model

- **Qwen3.8-Flash-Next**: a Mixture-of-Experts (MoE) model with **125B
  parameters** in total.
- **48 layers**, mixing full attention (with a KV cache that grows with the
  context) and Gated DeltaNet linear attention (fixed-size state).
- Each layer has a **router**, **shared experts** used for every token and
  **512 routed experts**, of which the router picks **10 per token**.
- A built-in **MTP layer** drafts up to 3 tokens ahead; one pass over the 48
  layers verifies them (2.4-3.2 tokens accepted per pass on average). This is
  where most of the generation speed comes from.
- A **28.8 GB n-gram lookup table (PLE)**, of which only a few rows are read
  per token.

## The Coder variant

[ISTA-DASLab's GSQ-RCO Coder](https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-Coder-GGUF)
is an expert-pruned release of the base model:

| | Base | Coder IQ1_M |
| --- | ---: | ---: |
| Routed experts per layer | 512 | 256 |
| Routed experts in total | 24,576 | 12,288 |
| Active experts per token | 10 per layer | 10 per layer |
| Expert weights | - | ~23 GB |
| Shard 1 (dense + experts) | - | 29.6 GB |

- The kept experts are the ones most used on code, agentic and vision
  calibration data (RCO).
- The authors report 91.3% of the base model's SWE-bench Verified score and
  98.7% of its LiveCodeBench v6 score.
- It is weaker outside code and in languages other than English.
- "IQ1_M" refers to 1.89 bits per *original* parameter. The kept experts are
  stored like IQ3_S: IQ2_S-IQ4_XS for gate/up, IQ4_NL/Q2_0 for down, about
  3.4 bits per weight.

## How big is it really?

Three different numbers, often mixed up:

1. **Stored parameters**: about **55-65B** (our estimate, not an upstream
   figure). Pruning half the routed experts removes most of the 125B, since
   experts are the bulk of an MoE. At ~3.4 bits per weight, ~23 GB of experts
   is roughly 54B parameters, plus the dense part.
2. **Memory footprint**: ~23 GB of experts plus the dense weights. That is
   what a dense 20B model would take at 8 bits, which is why it can feel like
   a "20B model". It is not one.
3. **Active parameters per token**: only 10 routed experts per layer plus the
   shared parts run for each token. Upstream does not publish the figure, but
   it is a small fraction of the total. That is why it generates at 35-40 tok/s
   on a 12 GB consumer GPU. A dense 60B model would run at a few tok/s on the
   same machine.

In short: the knowledge of a large, pruned and heavily compressed model, at
the per-token compute of a small one.

## Where each part lives (reference host)

RTX 4070 SUPER 12 GB, 28 GB WSL2 VM, 100K context, KV q4_0, low-RAM
resident mode (see AGENTS.md):

| Location | Contents | Size |
| --- | --- | --- |
| GPU (VRAM) | attention and DeltaNet mixers, routers, shared experts, output head, MTP layer, KV cache, and an **expert cache** of the most used experts (adapts during the conversation) | expert cache: 2,082 experts, 4.0 GiB (~17% of the experts) |
| RAM | every expert not in the GPU cache, computed in place by the CPU while the GPU works on its own share | ~10,200 experts, 19.42 GiB |
| SSD | the PLE n-gram table, read a few rows per token | 28.8 GB |

All the experts must fit in RAM. Any expert read from the SSD during decoding
makes generation much slower, which is what the resident-mode settings in
AGENTS.md prevent.

## API compatibility with llama.cpp clients

The server speaks the same API that `docker-llama-local`'s clients use, so the
same OpenCode wrapper works against either server on port 12345:

- `POST /v1/chat/completions`, the only endpoint OpenCode's
  `@ai-sdk/openai-compatible` provider calls.
- `/slots` (context size) and `/props` (model name), which are llama.cpp
  endpoints that Strata emulates.

Differences that matter:

- Strata rejects requests whose `Host` header it does not know (DNS rebinding
  protection). Clients that connect by host name need it in
  `STRATA_ALLOWED_HOSTS`. llama.cpp has no such check.
- The thinking cap is a server setting here
  (`STRATA_REASONING_BUDGET_TOKENS`). llama.cpp controls reasoning with its
  own server flags.
- Strata rejects a request whose prompt + `max_tokens` exceeds the context
  unless `fit_max_tokens` is on (`STRATA_FIT_MAX_TOKENS=1`, the default here).
- A request without sampling fields decodes greedy on Strata.
  `STRATA_SAMPLING` sets the defaults (temperature 0.6, top_p 0.95, top_k 20,
  repetition_penalty 1.05) to avoid repetition loops.
