## What this changes

<!-- One or two sentences. -->

## If this changes a setting, the measurement

Delete this section only if the change touches no launch parameter, no
quantisation, no batch size and no cache type.

| | Before | After |
|---|---|---|
| Decode (tok/s) | | |
| Prefill (tok/s) | | |
| VRAM | | |

- **Hardware**: GPU, driver version
- **Build**: llama.cpp version or commit
- **Protocol**: number of runs, fixed seed yes/no, prompt size
- **Command or request used**:

```
```

A sweep without a fixed seed measures noise, not the setting. If you could not
fix the seed, say so here rather than omitting it.

## Checklist

- [ ] No hostname, IP address, username or credential anywhere in the diff
- [ ] Comments explain *why*, with the number behind the why
- [ ] Documentation updated if the behaviour changed
- [ ] I ran this, I am not reporting what I expect to happen
