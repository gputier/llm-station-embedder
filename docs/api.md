# Calling the server

Base URL on this machine: `http://192.168.4.98:8080`. No key.

## Embedding

```bash
curl -s http://<host>:8080/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"input": "le texte à vectoriser"}'
```

`input` also accepts an array of strings, which is how you should almost always
call it. The response follows the OpenAI shape: `data[].embedding` carries the
vector, `data[].index` preserves input order, `usage.prompt_tokens` reports what
was actually tokenised.

```python
import json, urllib.request

def embed(texts, base="http://192.168.4.98:8080"):
    req = urllib.request.Request(
        base + "/v1/embeddings",
        data=json.dumps({"input": texts}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        return [d["embedding"] for d in json.load(r)["data"]]
```

## Two traps

### The vectors are already normalised, so do not renormalise

Norm 1.000000, verified here on inputs of several lengths. Similarity is a plain
dot product. The widely repeated advice that `llama-server` returns unnormalised
vectors because it lacks `--embd-normalize` does not hold on this build. Verify
it on yours with one request rather than trusting either statement.

### Chunk your input, or pay for it

The card ingests a single long sequence on a collapsing curve. Measured here:

| One input of | Time |
|---|---|
| 302 tokens | 0.04 s |
| 602 tokens | 0.56 s |
| 1,202 tokens | 0.85 s |
| 2,402 tokens | 3.32 s |
| 4,802 tokens | 18.2 s |

The same 4,800-token content sent as eight chunks in a single call: **0.09 s**.

A batch is not capped by the context window. 1,000 sentences totalling 16,890
tokens are served in one call, in 22.8 s, because every input is embedded
independently. Only a **single** text above 8,192 tokens is refused, with HTTP
400:

```json
{"error":{"code":400,"message":"request (9002 tokens) exceeds the available context size (8192 tokens), try increasing it","type":"exceed_context_size_error"}}
```

That refusal is loud and correct. Nothing else about long inputs is.

## Instruction-aware queries

Qwen3-Embedding is trained to take a task instruction on the query side. Qwen
reports a 1% to 5% retrieval loss without one, and recommends writing it in
English even for other languages. Prefix the query, not the stored documents,
and keep the same instruction for the life of an index: changing it invalidates
every comparison against vectors built with the previous one.

This has not been measured on this machine. It is Qwen's figure, not ours.

## What does not answer

`/v1/chat/completions` and `/v1/messages` are not served. The connection is left
open rather than refused, so **a client without a timeout hangs indefinitely**.
This differs from the sibling machine, where the same call returns an empty
reply. Do not port a caller from one to the other without checking.

## Endpoints that do answer

| Route | Method | Use |
|---|---|---|
| `/health` | GET | `{"status":"ok"}`, answers whatever is loaded, so it proves nothing on its own |
| `/props` | GET | `model_path` says **which** model holds the port |
| `/v1/models` | GET | `id`, and `meta.n_embd` / `meta.n_ctx` |
| `/v1/embeddings` | POST | The one that matters |
| `/tokenize` | POST | Count tokens before sending, to size your chunks |
