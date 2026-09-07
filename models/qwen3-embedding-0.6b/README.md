# Qwen3-Embedding-0.6B

The only model this box serves. Text in, vectors out, 1024 dimensions, 100+
languages, weights published by Qwen themselves.

```powershell
.\llm-ctl.ps1 -Action embed
```

| | |
|---|---|
| Weights | `Qwen3-Embedding-0.6B-Q8_0.gguf`, 639,150,592 bytes |
| Parameters | 595,776,512, as the server reports them in `/v1/models` |
| Dimension | 1024, counted on a real vector, not read off the model card |
| Native window | 32,768; served here at 8,192, see below |
| Pooling | `last` |
| Video memory | 2,699 MB, delta against an idle card |

## Every flag, and why

| Flag | Reason |
|---|---|
| `--embedding` | Without it the weights load, `/health` goes green, and `/v1/embeddings` answers 501. The failure surfaces at the caller, not here |
| `--pooling last` | What Qwen trained. The wrong value produces vectors of the right shape and wrong content, silently |
| `--alias qwen3-embedding-0.6b` | Without it `/v1/models` reports the full Windows path of the GGUF as the model id, backslashes included, and callers store that string |
| `-c 8192` | The KV cache is allocated at load for the declared window: 32,768 costs 5,462 MB, 8,192 costs 2,699 MB. Nothing here embeds a 32k-token text in one piece |
| `--parallel 1` | Without it llama.cpp opens four slots and splits `-c` between them, while `/props` still announces the full figure |
| `-b 2048 -ub 2048` | Qwen's own line says 8192; on this card that fails to allocate a pinned buffer and falls back silently. See below |
| `-ngl 99` | All layers on the card. A local model runs in video memory, not in system RAM |
| `--no-mmap --mlock` | Weights resident rather than paged back from disk under pressure. 639 MB, so it costs nothing |
| `--cors-origins ''` | Closes the browser path. It is the only lock on this server |
| no `--reranking` | Alongside `--embedding` it returns all-zero vectors for this model, [llama.cpp #20085](https://github.com/ggml-org/llama.cpp/issues/20085). Zeros do not raise |

## The ubatch, in detail

The model card's launch line uses `-ub 8192`. On this card the Vulkan backend
cannot allocate its pinned buffer at that size:

```
W ggml_vulkan: Failed to allocate pinned memory (Requested buffer size exceeds device buffer size limit: ErrorOutOfDeviceMemory)
```

It is logged as a **warning** and the server keeps running on a slower path.
Measured, same 4,802-token text:

| `-ub` | Warnings at load | Time |
|---|---|---|
| 8192 | 1 | 23.4 s |
| 4096 | 1 | not timed |
| 2048 | 0 | 15.4 s |

Lower is both quieter and faster here. And the ubatch does **not** cap input
length: a 4,802-token text is served fine with `-ub 2048`, llama.cpp splitting it
across several ubatches and pooling across them.

## Ingestion, and how it dictates usage

Single input, measured on this card:

| Tokens | Time |
|---|---|
| 302 | 0.04 s |
| 602 | 0.56 s |
| 1,202 | 0.85 s |
| 2,402 | 3.32 s |
| 4,802 | 18.2 s |

The same 4,800-token content as eight chunks in one call: **0.09 s**.

Batch throughput: 300 sentences in 6.9 s, 1,000 in 22.8 s.

This is the RDNA1 curve documented in the
[sibling repository](https://github.com/gputier/llm-station-vulkan), and it is
why that machine could not serve chat. Here it is survivable, because embedding
inputs are chunked anyway. Chunk them.

## Behaviour worth knowing

Vectors come out **already normalised**, norm 1.000000. A dot product is the
cosine.

A single input above `-c` is refused with HTTP 400 naming both figures. A batch
is not capped by `-c`: 1,000 sentences totalling 16,890 tokens pass in one call.

Sanity check, French and English, cosine on raw vectors:

| Pair | Cosine |
|---|---|
| "Le chat dort sur le canapé" / "Un félin fait la sieste sur le sofa" | 0.727 |
| "La facture doit être réglée avant le 30" / same sentence in English | 0.720 |
| "Le chat dort sur le canapé" / "La facture doit être réglée avant le 30" | 0.201 |

Cross-language similarity matching same-language similarity is the multilingual
claim holding up, measured rather than assumed.
