# llm-station-embedder

An 8 GB AMD card that stopped trying to be a chat server and became a good one
at something else: **serving embeddings over `/v1/embeddings`**, on
`llama.cpp` with the Vulkan backend.

This is the same physical machine as
[llm-station-vulkan](https://github.com/gputier/llm-station-vulkan), repurposed.
That repository is kept as it was, because its measurements are the reason this
one exists.

## Why the machine was repurposed

The card is a Radeon RX 5700 XT, RDNA1, 2019. RDNA1 has no matrix units, and the
Vulkan cooperative-matrix extension that accelerates prompt ingestion needs
them. Prompt processing therefore runs on scalar shaders, and the cost grows
faster than the prompt.

Measured on this card, same model, same prompt, 2026-09-02: 340 tokens per
second at 2,048 ingested, 173 at 4,096, 81 at 8,192, 51 at 12,288. An agentic
client that opens with ~35,000 tokens of instructions costs about half an hour
before the first word. Every software lever was tried the same day, including a
154-build engine update, a prefill batch sweep and flash attention: total spread
7% against a measurement variance of 8%. Nothing moved.

**Embedding is the job this hardware is actually good at.** Short texts, no
generation, no long context. The collapse that makes it useless for chat barely
shows, provided you feed it short inputs, and the section below quantifies that
"provided".

## Hardware and software this was proven on

| | |
|---|---|
| GPU | AMD Radeon RX 5700 XT, 8 GB, driver 32.0.21045.5002 |
| OS | Windows 11 |
| Backend | `llama.cpp` Vulkan build b10603, prebuilt binaries, no compilation |
| Model | Qwen3-Embedding-0.6B, Q8_0, weights published by Qwen |

## What it serves

```powershell
.\llm-ctl.ps1 -Action embed
```

| | |
|---|---|
| Model id from `/v1/models` | `qwen3-embedding-0.6b` |
| Vector dimension | 1024, counted on a real vector |
| Context per input | 8,192 tokens |
| Languages | 100+ |
| Video memory | 2,699 MB, measured as a delta against an idle card |
| Weights on disk | 639 MB |

Nothing else. `/v1/chat/completions` does not answer, and that is the point.

## Five things measured on the machine, 2026-09-07

### Vectors come out already normalised

Norm 1.000000, on inputs of different lengths. A dot product is a cosine
similarity here. This contradicts the common advice that `llama-server` returns
unnormalised embeddings because it has no `--embd-normalize`: on this build, with
this pooling, it does normalise. Check it on yours rather than trusting either
claim, it costs one request.

### One long text is expensive, a batch of short ones is almost free

The same 4,800-token content:

| | |
|---|---|
| Sent as one input | 13.7 s |
| Sent as eight chunks in one call | 0.09 s |

A factor of 150, from chunking alone. On a single input the curve is the same
one that killed the chat use case: 302 tokens in 0.04 s, 1,202 in 0.85 s, 2,402
in 3.32 s, 4,802 in 18.2 s. Past roughly two thousand tokens it falls apart.

In batch: 300 sentences in 6.9 s, 1,000 sentences in 22.8 s, about 44 per second.

**Chunk before you send.** On this card that is not an optimisation, it is the
only usable access pattern.

### `-c` is billed on start, whether you use it or not

The KV cache is allocated for the declared window at load time. Measured as a
delta against an idle card: `-c 32768` costs 5,462 MB of video memory, `-c 8192`
costs 2,699 MB. Nothing here needs a 32k-token single input, and the curve above
rules it out anyway, so the window was cut and 2.7 GB handed back.

A batch is not capped by `-c`: 1,000 sentences totalling 16,890 tokens are served
in one call, because each input is embedded on its own. Only an individual text
above the window is refused, cleanly, with HTTP 400 naming both figures.

### Qwen's own `-ub 8192` is wrong on this card

The model card's launch line uses `-ub 8192`. Here the Vulkan backend cannot
allocate its pinned buffer at that size and falls back silently, logging
`Failed to allocate pinned memory (... ErrorOutOfDeviceMemory)` as a **warning**,
not an error. At `-ub 2048` the warning is gone and the same 4,802-token text is
embedded in 15.4 s instead of 23.4 s.

Lower ubatch, faster, on this hardware. And the ubatch does **not** cap input
length: llama.cpp splits a longer text across several ubatches and pools across
them.

### Pooling is not a detail, and it is not portable

Qwen3-Embedding is trained with **last-token pooling**. The sibling machine on
this network serves nomic, which wants mean. Copy the wrong flag and the server
still starts, still answers, still returns vectors of the right length, and every
similarity computed from them is quietly wrong. Nothing reports it.

## Refused by measurement

`--reranking` alongside `--embedding` returns all-zero vectors for this model
([llama.cpp #20085](https://github.com/ggml-org/llama.cpp/issues/20085)). Zeros do
not raise: they produce a similarity of zero between everything. The flag is not
set here.

## A note on the client side

A request to `/v1/chat/completions` does not return an error. The connection
stays open until the caller's own timeout. A client without a timeout hangs
forever. Give yours one.

## Security

No API key. The only lock is `--cors-origins ''`, which closes the browser path;
the host firewall is off. Anything on the LAN that is not a browser reaches the
model. That is a deliberate choice for a private network, not an oversight, and
[SECURITY.md](SECURITY.md) says how to put a key back.

## License

MIT. `llama.cpp` is MIT; the model weights carry their own license.
