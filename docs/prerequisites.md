# Prerequisites

## Server side, Windows

### Hardware

| | Used here |
|---|---|
| GPU | AMD Radeon RX 5700 XT, 8 GB, driver 32.0.21045.5002 |
| OS | Windows 11 |

Any Vulkan-capable GPU works, and for this workload almost any will do: the
weights are 639 MB and the whole server sits under 2.7 GB of video memory. The
card is not the constraint here. Its *generation* is: see the ingestion curve in
the main README before assuming a long input will be fast.

### Software

**No build toolchain.** This box runs the official prebuilt `llama.cpp` Vulkan
release, `b10603`, unzipped into `llama-cpp-vulkan`. Vulkan needs neither CUDA
nor Visual Studio.

You need:

- A recent AMD (or other Vulkan-capable) driver. On this machine a driver eleven
  months out of date cost half a day of diagnosis on a defect that no longer
  existed upstream. Update before diagnosing anything else.
- The prebuilt Vulkan release of `llama.cpp`.
- PowerShell 5.1 or later, present by default.

### Model weights

```powershell
curl.exe -L --fail --retry 3 `
  -o D:\models\qwen3-embedding-0.6b\Qwen3-Embedding-0.6B-Q8_0.gguf `
  https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF/resolve/main/Qwen3-Embedding-0.6B-Q8_0.gguf
```

639,150,592 bytes. **Check the size, not just that the download finished.** A
truncated GGUF can still carry a valid internal signature: that happened on this
machine on 2026-08-24, a file at a quarter of its real size passed the signature
check and failed nowhere until it was loaded.

Hugging Face rate-limits **per connection**, not per client: 1.66 MB/s on one
stream against 7.55 MB/s over four, measured 2026-09-02 on a 930 Mb/s line. At
639 MB a single stream is fine; for larger weights, split the download into
parallel ranges.

### Paths

The script reads two environment variables and falls back to the values used
here:

| Variable | Default |
|---|---|
| `LLM_ROOT_DIR` | `D:\LLM-Setup` |
| `LLM_MODELS_DIR` | `D:\models` |

Nothing else in `llm-ctl.ps1` is installation-specific.

## Client side

Any HTTP client. There is no launcher in this repository and there is no reason
for one: this server does not serve a chat client, it answers a single POST.

The only client-side requirement is a **timeout**. A request sent to
`/v1/chat/completions` on this server does not return an error, it leaves the
connection open. See [api.md](api.md).
