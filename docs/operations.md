# Operations

Everything goes through `llm-ctl.ps1`. Four actions, and the set is closed by
`ValidateSet` so a typo fails loudly instead of falling through.

```powershell
.\llm-ctl.ps1 -Action embed     # load the model
.\llm-ctl.ps1 -Action status    # what is tracked, and is it healthy
.\llm-ctl.ps1 -Action logs      # follow the live log
.\llm-ctl.ps1 -Action stop      # free the card
```

## Starting

`STARTED name=embed pid=... port=8080` is only printed after `/health` answers
200. A live PID is not a usable server, and the script does not claim otherwise.

If startup fails it prints `FAILED` **and the tail of the error log**, rather
than a success line with nothing behind it. That distinction was added after a
version that reported success while the process had died at launch.

Before binding, the script frees the port in two steps: it kills any tracked
instance on it, then any **orphan** `llama-server` still listening. Without that
second step an untracked process can hold the bind while the health check goes
green by answering from the old server.

It then waits for the card to actually hand its memory back. `Stop-Process`
returns as soon as a process is marked dead, but Windows frees device memory
asynchronously. The wait reads the WDDM performance counters
(`\GPU Adapter Memory(*)\Dedicated Usage`), which exist for any card, since there
is no AMD equivalent of `nvidia-smi` on Windows and ROCm does not cover RDNA1.

Two facts about those counters, verified on this machine: they stay **English**
on a French Windows, so no culture-dependent lookup is needed, and they report
one instance per adapter, only one of which is the discrete card.

## Reading logs

`llama-server` writes everything to stderr, including served requests.
`llm-out-embed.log` stays empty forever and is **not** the file to read;
`llm-err-embed.log` carries everything.

That file is written by llama.cpp's own `--log-file`, never by a shell
redirection. Redirected through `cmd.exe`, the C runtime fully buffers stderr and
the file stays at zero bytes until the process exits, which would defeat both the
`FAILED` diagnostic and the `logs` action.

## Proving what is loaded

`status` reports what the script *tracks*. `/props` reports what actually holds
the port. When they disagree, `/props` wins and tracking has come loose.

```bash
curl -s http://<host>:8080/props | grep -o '"model_path":"[^"]*"'
```

## Autostart

A scheduled task, `LLM-Ctl-Autostart`, runs `-Action embed` at boot under the
system account. No password stored, no automatic logon enabled.

One known hazard, from the chat era of this machine: a boot-time start can fire
before the card has released memory, and llama.cpp will then fall back to the CPU
with a single warning buried in the log while `/health` answers normally. The
symptom is a service that works and is forty times too slow. The current model is
639 MB, which makes the failure far less likely, but the check is the same:
compare a request's latency against the figures in the README, not against
"it answers".

## Running PowerShell over SSH

Anything beyond a trivial command needs `-EncodedCommand` with UTF-16LE base64.
Quoting nested through SSH, `cmd.exe` and PowerShell mangles quotes and pipes
silently; `Select-String` and other cmdlets end up being handed to `cmd`, which
reports them as unknown commands.

```bash
CMD='Get-Content D:\LLM-Setup\llm-err-embed.log -Tail 40'
ENC=$(python3 -c "import base64,sys; print(base64.b64encode(sys.argv[1].encode('utf-16-le')).decode())" "$CMD")
ssh user@host "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $ENC"
```

## Adding a second profile

Add its port to the `$ports` table and a branch to the `switch`. Nothing else in
the script needs to change. Models on this card are mutually exclusive on the
port by design, and the start path already enforces it.
