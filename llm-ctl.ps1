param(
  [ValidateSet('embed','stop','status','logs')]
  [string]$Action,
  [string]$Name,  # optional: for 'stop' and 'logs', targets a named instance
  [int]$Tail = 40 # for 'logs': history lines to show before following live
)

# ---------------------------------------------------------------------------
# Paths. Adjust these two to match your machine; nothing else below is
# installation-specific.
# ---------------------------------------------------------------------------
$RootDir   = if ($env:LLM_ROOT_DIR) { $env:LLM_ROOT_DIR } else { 'D:\LLM-Setup' }
$ModelsDir = if ($env:LLM_MODELS_DIR) { $env:LLM_MODELS_DIR } else { 'D:\models' }

# ---------------------------------------------------------------------------
# One llama.cpp build here, Vulkan backend, and that is not a default: it is
# the only backend that drives this card. The Radeon RX 5700 XT is RDNA1
# (gfx1010), an architecture ROCm dropped support for, so the HIP backend is
# not an option on this box. Vulkan is.
# ---------------------------------------------------------------------------
$exe     = "$RootDir\llama-cpp-vulkan\llama-server.exe"
$workDir = $RootDir

$instDir = "$RootDir\instances"
New-Item -ItemType Directory -Force -Path $instDir | Out-Null

# One profile, one port. This box used to serve six chat profiles that were all
# mutually exclusive on the card; it now serves embeddings and nothing else.
# The table is kept because the rest of the script indexes into it, and because
# a second profile would slot in here without touching anything below.
$ports = @{ embed = 8080 }

# Shared by every model block below. Without it, any web page open on any
# machine of the LAN can query this server through the user's browser: a
# firewall does not protect against that case, because the request originates
# from inside the network. This closes the browser path, and it is the ONLY
# protection this server carries: there is no API key, and the host firewall is
# off. Anything on the LAN that is not a browser reaches the model.
$CorsOrigins = ''

function Quote($s) {
  # An EMPTY argument must be quoted too. Left bare it vanishes from the joined
  # command line instead of being passed through, which silently hands the
  # PRECEDING flag whatever token comes next as its value.
  if ($s -eq '' -or $s -match '[\s"]') { return '"' + ($s -replace '"','\"') + '"' }
  return $s
}

function Read-Instances {
  Get-ChildItem $instDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
    $o = Get-Content $_.FullName -Raw | ConvertFrom-Json
    [pscustomobject]@{ Name = $_.BaseName; Pid = $o.Pid; Port = $o.Port }
  }
}

function Kill-Pid($procId) {
  $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
  if ($p) { $p | Stop-Process -Force }
}

# Wait for the graphics card to actually hand its memory back.
#
# Stop-Process returns as soon as the process is marked dead, but Windows frees
# device memory ASYNCHRONOUSLY. An instance relaunched before that hand-back
# completes sees a card that is still occupied. A FIXED delay cannot cover this
# properly: it is either too short or wasted time. So we wait for the processes
# to actually disappear, then for the card's usage to settle, with a 30 s guard
# rail.
#
# The reading comes from the Windows performance counters, not from a vendor
# tool. There is no AMD equivalent of nvidia-smi on Windows, and rocm-smi does
# not cover this card. The counter set is provided by the WDDM driver model
# itself, so it works for any graphics card. Verified on this box 2026-09-02:
# the counter names stay ENGLISH on a fr-FR Windows, this set is not localised,
# so no culture-dependent lookup is needed.
#
# Instances are summed because the machine exposes several adapters and only
# one of them is the discrete card; the idle ones report zero.
function Get-VramUsedMb {
  try {
    $samples = (Get-Counter '\GPU Adapter Memory(*)\Dedicated Usage' -ErrorAction Stop).CounterSamples
  } catch {
    return -1
  }
  if (-not $samples) { return -1 }
  $sum = ($samples | Measure-Object -Property CookedValue -Sum).Sum
  return [int][math]::Round($sum / 1MB)
}

function Wait-VramReleased($timeoutSec = 30) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)

  while ((Get-Date) -lt $deadline -and (Get-Process -Name llama-server -ErrorAction SilentlyContinue)) {
    Start-Sleep -Milliseconds 250
  }

  Start-Sleep -Milliseconds 500
  $previous = -1
  $stable   = 0
  while ((Get-Date) -lt $deadline) {
    $used = Get-VramUsedMb
    # Counters unavailable: fall back to a fixed delay rather than burning the
    # whole timeout. Control must not depend on that one source.
    if ($used -lt 0) { Start-Sleep -Seconds 2; return }
    if ($used -eq $previous) { $stable++ } else { $stable = 0 }
    if ($stable -ge 2) { return }
    $previous = $used
    Start-Sleep -Milliseconds 500
  }
}

function Stop-One($name) {
  $f = Join-Path $instDir "$name.json"
  if (Test-Path $f) {
    $o = Get-Content $f -Raw | ConvertFrom-Json
    Kill-Pid $o.Pid
    Remove-Item $f -Force
    Write-Output "STOPPED $name"
  } else {
    Write-Output "NOT_RUNNING $name"
  }
}

function Stop-All {
  $procs = Get-Process -Name llama-server -ErrorAction SilentlyContinue
  if ($procs) { $procs | Stop-Process -Force; Wait-VramReleased; Write-Output "STOPPED all" }
  else { Write-Output "NOT_RUNNING" }
  Get-ChildItem $instDir -Filter '*.json' -ErrorAction SilentlyContinue | Remove-Item -Force
}

# Live log tailing.
#
# llama-server writes ALL of its output to stderr, including progress lines and
# served requests: llm-out-<name>.log stays empty forever and is NOT the file to
# read. llm-err-<name>.log carries everything. This action exists so nobody has
# to remember that: it picks the log of the running instance and follows it.
# Ctrl+C to exit; the server is unaffected.
function Show-Logs($name, $tail) {
  if (-not $name) {
    $running = @(Read-Instances | Where-Object { Get-Process -Id $_.Pid -ErrorAction SilentlyContinue })
    if ($running.Count -eq 0) {
      Write-Output "NO_INSTANCE no tracked instance is running. Pass -Name ($($ports.Keys -join '/'))."
      return
    }
    $name = $running[0].Name
  }
  $errLog = "$RootDir\llm-err-$name.log"
  if (-not (Test-Path $errLog)) { Write-Output "NO_LOG $errLog not found"; return }
  Write-Output "TAILING name=$name file=$errLog (Ctrl+C to exit)"
  Get-Content $errLog -Tail $tail -Wait
}

function Start-LLM($name, $modelArgs) {
  $port = $ports[$name]
  # Free the port: kill any tracked instance on the same port.
  $killed = @()
  foreach ($i in Read-Instances) {
    if ($i.Port -eq $port) { Kill-Pid $i.Pid; $killed += $i.Pid; Remove-Item (Join-Path $instDir "$($i.Name).json") -Force -ErrorAction SilentlyContinue }
  }
  # Then any ORPHAN instance still listening on that port. A llama-server
  # started by hand, or one that survived a loss of tracking, used to block the
  # bind silently while this script reported STARTED and the health check went
  # green by querying the old process.
  Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty OwningProcess -Unique |
    Where-Object { $killed -notcontains $_ -and (Get-Process -Id $_ -ErrorAction SilentlyContinue).ProcessName -eq 'llama-server' } |
    ForEach-Object { Write-Output "KILLED_ORPHAN pid=$_ port=$port"; Kill-Pid $_ }
  Wait-VramReleased

  $outLog = "$RootDir\llm-out-$name.log"
  $errLog = "$RootDir\llm-err-$name.log"
  Clear-Content $outLog -ErrorAction SilentlyContinue
  Clear-Content $errLog -ErrorAction SilentlyContinue

  # The error log is written via llama-server's own --log-file flag, NOT via a
  # shell "2>" redirection. Sent through cmd.exe to a file, the process's C
  # runtime fully buffers its stderr and the file stays at 0 bytes until the
  # process exits, which defeats both the FAILED diagnostic below and the
  # 'logs' action. --log-file is flushed by the process itself and stays
  # readable while it runs.
  $fullArgs = $modelArgs + @('--log-file', $errLog)
  $quoted = ($fullArgs | ForEach-Object { Quote $_ }) -join ' '

  # No `set` inside the cmd line, and this is not a style choice. cmd /c strips
  # the outer quotes of the whole line, after which `set VAR=<value> && <rest>`
  # swallows ` && <rest>` INTO the value: nothing after it ever runs, no log
  # file is even created, and Win32_Process.Create still returns 0. Measured on
  # the CUDA box 2026-09-01, on every quoting variant tried, including /s and an
  # extra wrapping pair. `cd /d` is still required, dropping it makes the launch
  # fail.
  $inner = "cd /d `"$workDir`" && `"$exe`" $quoted > `"$outLog`""
  $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "cmd.exe /c $inner"; CurrentDirectory = $workDir }
  if ($r.ReturnValue -ne 0) { Write-Output "ERROR Win32_Process.Create rc=$($r.ReturnValue)"; return }

  # Resolve the real llama-server PID (child of the cmd.exe we launched).
  $llamaPid = $null
  $deadline = (Get-Date).AddSeconds(60)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 300
    $child = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($r.ProcessId) AND Name='llama-server.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($child) { $llamaPid = $child.ProcessId; break }
  }
  if (-not $llamaPid) {
    # No STARTED here: without a PID the instance is untracked and the process
    # almost certainly failed at startup. Reporting success hid the failure.
    Write-Output "FAILED name=$name port=$port (no llama-server started, see llm-err-$name.log)"
    Get-Content $errLog -Tail 20 -ErrorAction SilentlyContinue
    return
  }

  # A live PID is not a usable server. Loading the weights and warming the card
  # takes time here, and answering before /health is green means the caller's
  # first request hits a closed socket.
  $ready = $false
  $deadline = (Get-Date).AddSeconds(120)
  while ((Get-Date) -lt $deadline) {
    try {
      $h = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 3
      if ($h.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
    Start-Sleep -Seconds 1
  }
  if (-not $ready) {
    Write-Output "FAILED name=$name pid=$llamaPid port=$port (health check timeout)"
    Get-Content $errLog -Tail 30 -ErrorAction SilentlyContinue
    return
  }

  @{ Pid = $llamaPid; Port = $port } | ConvertTo-Json -Compress | Set-Content -Path (Join-Path $instDir "$name.json")
  Write-Output "STARTED name=$name pid=$llamaPid port=$port"
}

function Get-Status {
  $any = $false
  foreach ($i in Read-Instances) {
    $any = $true
    $alive = [bool](Get-Process -Id $i.Pid -ErrorAction SilentlyContinue)
    $health = 'no answer'
    try {
      $resp = Invoke-WebRequest -Uri "http://localhost:$($i.Port)/health" -TimeoutSec 3 -UseBasicParsing
      if ($resp.StatusCode -eq 200) { $health = 'ok' }
    } catch { $health = 'no answer' }
    Write-Output "RUNNING name=$($i.Name) pid=$($i.Pid) port=$($i.Port) alive=$alive health=$health"
  }
  if (-not $any) { Write-Output "NOT_RUNNING" }
}

switch ($Action) {
  'stop'   { if ($Name) { Stop-One $Name } else { Stop-All }; break }
  'status' { Get-Status; break }
  'logs'   { Show-Logs $Name $Tail; break }

  'embed' {
    # Qwen3-Embedding-0.6B, Q8_0, the only thing this box serves. Text in,
    # vectors out: this profile does NOT answer /v1/chat/completions and that
    # is the point, not a limitation to work around.
    Start-LLM 'embed' @(
      '-m',"$ModelsDir\qwen3-embedding-0.6b\Qwen3-Embedding-0.6B-Q8_0.gguf",
      # Without an alias, /v1/models reports the model id as the full Windows
      # path of the GGUF, backslashes included. Callers store that string, and
      # it breaks the day the file moves. Checked on this box 2026-09-07.
      '--alias','qwen3-embedding-0.6b',
      '-ngl','99',
      # --embedding switches the server into embedding mode. Without it the
      # weights still load and /health still goes green, but /v1/embeddings
      # answers 501: the failure surfaces at the caller, not here.
      '--embedding',
      # POOLING IS NOT A DETAIL, AND IT IS NOT THE SAME AS ON THE OTHER BOX.
      # Qwen3-Embedding is trained with last-token pooling; the sibling machine
      # serves nomic, which wants mean. Copy the wrong one and the server still
      # starts, still answers, still returns vectors of the right length, and
      # every similarity computed from them is quietly wrong. Nothing reports
      # it. Source: the model card published by Qwen.
      '--pooling','last',
      # 8192, not the model's native 32768, and --parallel 1 with it.
      #
      # -c is what a SINGLE input may weigh, and it is billed as KV cache the
      # moment the server starts, used or not. Measured here 2026-09-07, delta
      # against an idle card: 32768 costs 5462 MB of video memory, 8192 costs
      # 2699 MB. Nothing on this box needs to embed a 32k-token text in one
      # piece, and the ingestion curve below rules it out anyway, so the window
      # was cut and 2.7 GB handed back.
      #
      # A LOT is not capped by -c: 1000 sentences totalling 16890 tokens are
      # served in one call, because each input is embedded on its own. Only an
      # individual text above 8192 tokens is refused, cleanly, with HTTP 400 and
      # a message naming both figures.
      #
      # --parallel 1 because WITHOUT it llama.cpp opens FOUR slots and SPLITS -c
      # between them, so the window announced by /props is four times what a
      # single request gets. Found on this box 2026-09-02 by reading total_slots,
      # after a profile had been written wrong.
      '-c','8192',
      '--parallel','1',
      # Qwen's own launch line for this model uses -ub 8192. It does NOT hold
      # here, and the reason is the card: at 8192 the Vulkan backend fails to
      # allocate its pinned buffer and falls back silently, logging
      # "Failed to allocate pinned memory ... ErrorOutOfDeviceMemory" as a mere
      # warning. At 2048 the warning is gone and the SAME 4802-token text is
      # embedded in 15.4 s instead of 23.4 s. Lower ubatch, faster, on this card.
      #
      # The ubatch does NOT cap the length of one input: llama.cpp splits a
      # longer text across several ubatches and pools across them. Verified here,
      # a 4802-token text is served with -ub 2048.
      '-b','2048',
      '-ub','2048',
      # --no-mmap plus --mlock: hold the weights in resident memory instead of
      # letting Windows page them back from disk under pressure. 639 MB here,
      # so this costs almost nothing.
      '--no-mmap',
      '--mlock',
      # NO --reranking. Enabled alongside --embedding it makes this exact model
      # return all-zero vectors, an open llama.cpp defect (issue 20085). Zeros
      # do not throw: they produce a similarity of zero between everything.
      '--host','0.0.0.0',
      '--port','8080',
      '--log-colors','off',
      '--cors-origins',$CorsOrigins
    )
    break
  }

  # ValidateSet already rejects an unknown value with a usable error. The only
  # case left is no argument at all, which would otherwise fall through the
  # whole switch and exit silently as if it had worked.
  default  { Write-Output "USAGE: llm-ctl.ps1 -Action <$($ports.Keys -join '|')|stop|status|logs> [-Name <instance>] [-Tail <n>]"; break }
}
