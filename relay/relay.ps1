<#
.SYNOPSIS
  Medina Agentic Relay - psmux control plane.

  Opus (orchestrator) drives Gemini (executor) and Sonnet (validator) as live
  panes in a psmux session. Content moves over a file bus (.relay/) so results
  are clean and lossless; psmux provides process persistence, liveness and the
  ability to send follow-up instructions into a running agent.

.NOTES
  Windows PowerShell 5.1 compatible. No pwsh 7 syntax.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('up', 'down', 'status', 'send', 'dispatch', 'capture', 'wait', 'attach', 'bus')]
    [string]$Command = 'status',

    [string]$Workspace,
    [ValidateSet('executor', 'validator', 'scout')]
    [string]$Agent,
    [string]$Text,
    [string]$Task,
    [string]$File,
    [int]$Lines = 60,
    [int]$TimeoutSec = 900,
    [string]$Session = 'relay',
    [switch]$Safe
)

$ErrorActionPreference = 'Stop'

# --- psmux must be on PATH even in a freshly-spawned shell -------------------
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path', 'User')

$RelayHome = Split-Path -Parent $MyInvocation.MyCommand.Path
$StateFile = Join-Path $RelayHome 'state.json'

# Panes inherit their PATH from the psmux *server*, not from this script - and the
# server may have been started by any shell at any time. claude.exe in particular
# lives in ~\.local\bin, which a shell profile adds rather than the registry PATH,
# so a pane can fail with "not recognized" even though the command works fine here.
# Resolve real executable paths up front and launch the agents by absolute path.
function Resolve-Exe($name, $candidates) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -and (Test-Path $cmd.Source)) { return $cmd.Source }
    foreach ($c in $candidates) {
        $expanded = [Environment]::ExpandEnvironmentVariables($c)
        if (Test-Path $expanded) { return $expanded }
    }
    return $null
}

function Fail($msg) { Write-Host "[relay] ERROR: $msg" -ForegroundColor Red; exit 1 }
function Say($msg)  { Write-Host "[relay] $msg" -ForegroundColor Cyan }

function Get-State {
    if (-not (Test-Path $StateFile)) { Fail "Relay is not up. Run: relay.ps1 up -Workspace <path>" }
    Get-Content $StateFile -Raw | ConvertFrom-Json
}

function Get-PaneTarget($state, $agentName) {
    if ($agentName -eq 'executor')  { return $state.executorPane }
    if ($agentName -eq 'validator') { return $state.validatorPane }
    if ($agentName -eq 'scout')     { return $state.scoutPane }
    Fail "Unknown agent '$agentName'. Use 'executor', 'validator' or 'scout'."
}

# send-keys in three steps: clear whatever is already in the prompt buffer, then
# the literal payload, then a bare Enter. Sending the text with -l avoids psmux
# interpreting braces/semicolons in a prompt as key names.
#
# The C-u matters: agent TUIs frequently leave ghost or half-typed text in their
# input line, and without clearing it the dispatched instruction is appended to
# that garbage and the agent acts on a corrupted message.
function Send-Line($target, $line) {
    psmux send-keys -t $target C-u | Out-Null
    Start-Sleep -Milliseconds 150
    psmux send-keys -t $target -l -- $line | Out-Null
    Start-Sleep -Milliseconds 250
    psmux send-keys -t $target Enter | Out-Null
}

# Agent CLIs open on a "do you trust this folder?" gate. A pane sitting on that
# prompt is indistinguishable from a busy one in a capture, and it is this relay's
# single most common failure mode - so clear it explicitly rather than hoping.
function Clear-TrustPrompts($paneIds, $timeoutSec = 90) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $pending  = [System.Collections.ArrayList]@($paneIds)
    while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        foreach ($p in @($pending)) {
            $txt = (psmux capture-pane -t $p -p | Out-String)
            if ($txt -match 'trust (the contents of this|this folder)') {
                psmux send-keys -t $p Enter | Out-Null
                Say "Accepted folder-trust prompt in pane $p"
                Start-Sleep -Milliseconds 600
                $pending.Remove($p)
            }
            elseif ($txt -match 'READY|\? for shortcuts|shift\+tab to cycle') {
                $pending.Remove($p)   # already past the gate
            }
        }
    }
    foreach ($p in $pending) {
        Write-Host "[relay] WARNING: pane $p never cleared its startup prompt - inspect it with 'capture'." -ForegroundColor Yellow
    }
}

# Bus artifact paths are written relative to the workspace, but the orchestrator
# rarely runs from there. Resolve against the workspace so 'wait' does not silently
# watch a path that can never appear.
function Resolve-BusPath($state, $path) {
    if ([System.IO.Path]::IsPathRooted($path)) { return $path }
    return (Join-Path $state.workspace $path)
}

function New-BusDirs($ws) {
    foreach ($d in 'tasks', 'results', 'evidence', 'reports', 'logs') {
        New-Item -ItemType Directory -Force (Join-Path $ws ".relay\$d") | Out-Null
    }
}

# ============================================================== UP ===========
if ($Command -eq 'up') {
    if (-not $Workspace) { $Workspace = (Get-Location).Path }
    if (-not (Test-Path $Workspace)) { Fail "Workspace not found: $Workspace" }
    $Workspace = (Resolve-Path $Workspace).Path

    $existing = psmux ls 2>$null | Out-String
    if ($existing -match "(?m)^$([regex]::Escape($Session)):") {
        Say "Session '$Session' already running. Use 'down' first to rebuild."
        exit 0
    }

    New-BusDirs $Workspace

    # Charters describe each agent's contract with the bus.
    $charterDir = Join-Path $RelayHome 'charters'
    foreach ($c in 'executor', 'validator', 'scout') {
        $src = Join-Path $charterDir "$c.md"
        if (Test-Path $src) { Copy-Item $src (Join-Path $Workspace ".relay\$c.md") -Force }
    }

    # Preflight: the executor runs Antigravity CLI (agy). Gemini CLI's "Sign in with
    # Google" was retired for individual accounts on 2026-06-18, so agy - which uses
    # OAuth via the Windows credential manager - is the supported executor.
    $agyExe = Resolve-Exe 'agy' @(
        '%LOCALAPPDATA%\agy\bin\agy.exe',
        '%LOCALAPPDATA%\agy\bin\agy.cmd'
    )
    $claudeExe = Resolve-Exe 'claude' @(
        '%USERPROFILE%\.local\bin\claude.exe',
        '%APPDATA%\npm\claude.cmd',
        '%LOCALAPPDATA%\claude\bin\claude.exe'
    )
    if (-not $agyExe) {
        Write-Host "[relay] WARNING: 'agy' (Antigravity CLI) not found." -ForegroundColor Yellow
        Write-Host "        Install: irm https://antigravity.google/cli/install.ps1 | iex" -ForegroundColor Yellow
        Write-Host "        The executor pane will not start without it." -ForegroundColor Yellow
        $agyExe = 'agy'
    }
    if (-not $claudeExe) {
        Write-Host "[relay] WARNING: 'claude' not found - scout and validator will not start." -ForegroundColor Yellow
        $claudeExe = 'claude'
    }
    Say "executor bin : $agyExe"
    Say "claude  bin  : $claudeExe"

    # --- build the launchers, then create panes that RUN them -----------------
    # Do not type launch commands into an interactive shell. Two independent psmux
    # behaviours make that unreliable: 'send-keys -l' strips double quotes (so a
    # quoted prompt argument decomposes into loose arguments), and a pane shell
    # inherits its environment from the psmux server, which may have been started
    # by any process - one such server had a PSModulePath so broken that even
    # Test-Path was "not recognized". Generating a launcher script per agent and
    # having psmux exec it directly sidesteps both: no quoting, no inherited env.
    $launchDir = Join-Path $Workspace '.relay\launch'
    New-Item -ItemType Directory -Force $launchDir | Out-Null

    function Write-Launcher($name, $body) {
        $path = Join-Path $launchDir "$name.ps1"
        $prelude = @(
            '$env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" +'
            '            [Environment]::GetEnvironmentVariable("Path","User") + ";" +'
            '            "$env:LOCALAPPDATA\agy\bin;$env:USERPROFILE\.local\bin"'
            ''
        ) -join "`r`n"
        ($prelude + $body) | Set-Content $path -Encoding utf8
        return $path
    }

    # Executor: Antigravity CLI on Gemini 3.6 Flash (High) - fast, high volume.
    $agyFlags = '--dangerously-skip-permissions'
    if ($Safe) { $agyFlags = '--mode accept-edits' }
    $agyBoot = "Read .relay/executor.md and follow it as your operating contract for this session. Reply READY when loaded, then wait for task files."
    $execLauncher = Write-Launcher 'executor' "& `"$agyExe`" --model gemini-3.6-flash-high $agyFlags -i `"$agyBoot`"`r`n"

    # acceptEdits permits file edits but still gates every new Bash command shape behind
    # an approval prompt - which strands the scout and validator, whose entire job is
    # running verification commands. An unattended pane sitting on that prompt is this
    # relay's classic silent stall. User chose bypassPermissions (2026-08-08); the
    # charters, not the sandbox, are what keep these two panes from editing code.
    # -Safe trades autonomy back for a human in the loop.
    $claudeMode = 'bypassPermissions'
    if ($Safe) { $claudeMode = 'acceptEdits' }

    # Validator: Opus 5 - judgment only, grades against evidence it did not gather.
    $valBoot = "Read .relay/validator.md and follow it as your operating contract for this session. Reply READY when loaded, then wait for evidence files to grade."
    $valLauncher = Write-Launcher 'validator' "& `"$claudeExe`" --model opus --permission-mode $claudeMode `"$valBoot`"`r`n"

    # Scout: Sonnet 5 - mechanical evidence gathering and stall watchdog.
    $scoutBoot = "Read .relay/scout.md and follow it as your operating contract for this session. Reply READY when loaded, then wait for result files to gather evidence on."
    $scoutLauncher = Write-Launcher 'scout' "& `"$claudeExe`" --model sonnet --permission-mode $claudeMode `"$scoutBoot`"`r`n"

    # Bus pane: live view of artifacts landing on the file bus.
    $watchBody = @(
        '$p = ".relay"'
        'while ($true) {'
        '    Clear-Host'
        '    Write-Host "== RELAY BUS ==" -ForegroundColor Cyan'
        '    Get-ChildItem $p -Recurse -File -Filter *.md -EA 0 |'
        '        Sort-Object LastWriteTime -Descending | Select-Object -First 14 LastWriteTime,'
        '            @{n="artifact";e={$_.FullName.Replace((Get-Location).Path,"")}} |'
        '        Format-Table -AutoSize | Out-Host'
        '    Start-Sleep 3'
        '}'
        ''
    ) -join "`r`n"
    $watchLauncher = Write-Launcher 'buswatch' $watchBody

    # --- create the panes, each one exec'ing its launcher ----------------------
    # -NoExit keeps the pane alive if an agent exits, so a crash is inspectable
    # with 'capture' instead of collapsing the pane and losing the reason.
    function PaneCmd($launcher) {
        return "powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File `"$launcher`""
    }

    Say "Building session '$Session' in $Workspace"

    psmux new-session -d -s $Session -n agents -c $Workspace (PaneCmd $execLauncher) | Out-Null
    Start-Sleep -Milliseconds 1500
    foreach ($l in $valLauncher, $scoutLauncher, $watchLauncher) {
        psmux split-window -t "${Session}:agents" -c $Workspace (PaneCmd $l) | Out-Null
        Start-Sleep -Milliseconds 1200
    }
    psmux select-layout -t "${Session}:agents" tiled | Out-Null
    Start-Sleep -Milliseconds 500

    # Resolve stable pane IDs (%N) so later targeting survives index shuffling.
    $panes = @(psmux list-panes -t "${Session}:agents" -F "#{pane_index} #{pane_id}")
    if ($panes.Count -lt 4) { Fail "Expected 4 panes, got $($panes.Count)." }
    $ids = @{}
    foreach ($p in $panes) {
        $parts = $p.Trim() -split '\s+'
        $ids[$parts[0]] = $parts[1]
    }

    $state = [ordered]@{
        session       = $Session
        workspace     = $Workspace
        executorPane  = $ids['0']
        validatorPane = $ids['1']
        scoutPane     = $ids['2']
        busPane       = $ids['3']
        safe          = [bool]$Safe
        created       = (Get-Date).ToString('o')
    }
    $state | ConvertTo-Json | Set-Content $StateFile -Encoding utf8

    # Agents boot into a folder-trust gate; clear it before declaring the relay up.
    Say "Waiting for agents to boot and clearing startup prompts..."
    Clear-TrustPrompts @($ids['0'], $ids['1'], $ids['2'])

    Say "Relay up."
    Say "  executor  (agy / gemini-3.6-flash-high) -> $($ids['0'])"
    Say "  validator (claude opus)                 -> $($ids['1'])"
    Say "  scout     (claude sonnet)               -> $($ids['2'])"
    Say "  bus watch                               -> $($ids['3'])"
    Say "Attach with: psmux attach -t $Session"
    exit 0
}

# ============================================================ DOWN ===========
if ($Command -eq 'down') {
    psmux kill-session -t $Session 2>$null | Out-Null
    if (Test-Path $StateFile) { Remove-Item $StateFile -Force }
    Say "Relay '$Session' torn down."
    exit 0
}

# ========================================================== STATUS ===========
if ($Command -eq 'status') {
    $live = psmux ls 2>$null | Out-String
    if (-not ($live -match "(?m)^$([regex]::Escape($Session)):")) {
        Write-Host "[relay] DOWN - no psmux session '$Session'." -ForegroundColor Yellow
        exit 0
    }
    $s = Get-State
    Write-Host "[relay] UP  session=$($s.session)  workspace=$($s.workspace)" -ForegroundColor Green
    Write-Host "        safe-mode=$($s.safe)"
    psmux list-panes -t "$($s.session):agents" -F "        pane #{pane_index} (#{pane_id}) cmd=#{pane_current_command} active=#{pane_active}"

    $bus = Join-Path $s.workspace '.relay'
    foreach ($d in 'tasks', 'results', 'evidence', 'reports') {
        $items = @(Get-ChildItem (Join-Path $bus $d) -File -EA 0)
        Write-Host "        $d`: $($items.Count) artifact(s)"
        $items | Sort-Object LastWriteTime -Descending | Select-Object -First 3 | ForEach-Object {
            Write-Host "            - $($_.Name)  ($($_.LastWriteTime.ToString('HH:mm:ss')))"
        }
    }
    exit 0
}

# ============================================================ SEND ===========
if ($Command -eq 'send') {
    if (-not $Agent) { Fail "-Agent required (executor|validator)" }
    if (-not $Text)  { Fail "-Text required" }
    $s = Get-State
    Send-Line (Get-PaneTarget $s $Agent) $Text
    Say "Sent to $Agent."
    exit 0
}

# ======================================================== DISPATCH ===========
# Hand a task file to an agent. The task file IS the interface - keeps quoting
# sane and gives the agent a durable spec it can re-read.
if ($Command -eq 'dispatch') {
    if (-not $Task) { Fail "-Task <path to task .md> required" }
    $s = Get-State
    $taskPath = Resolve-BusPath $s $Task
    if (-not (Test-Path $taskPath)) { Fail "Task file not found: $taskPath" }
    $rel = (Resolve-Path $taskPath).Path.Replace($s.workspace, '').TrimStart('\', '/')
    $agentName = $Agent
    if (-not $agentName) { $agentName = 'executor' }
    $msg = "New task on the bus: $rel . Read it, execute it per your contract in .relay/executor.md, and write your completion report to the results path named in the task."
    if ($agentName -eq 'scout') {
        $msg = "Gather evidence for: $rel . Follow your contract in .relay/scout.md - re-run the verification commands yourself, record what you observe, and write to the evidence path named in the task. Do not issue a verdict."
    }
    if ($agentName -eq 'validator') {
        $msg = "Grade this task: $rel . Follow your contract in .relay/validator.md - read the task, the executor result, and the scout evidence, then write your verdict to the report path named in the task."
    }
    Send-Line (Get-PaneTarget $s $agentName) $msg
    Say "Dispatched $rel -> $agentName"
    exit 0
}

# ========================================================= CAPTURE ===========
if ($Command -eq 'capture') {
    if (-not $Agent) { Fail "-Agent required (executor|validator)" }
    $s = Get-State
    $target = Get-PaneTarget $s $Agent
    $out = psmux capture-pane -t $target -p
    $out | Select-Object -Last $Lines
    exit 0
}

# ============================================================ WAIT ===========
# Block until an artifact lands on the bus. This is what closes the loop.
if ($Command -eq 'wait') {
    if (-not $File) { Fail "-File <expected artifact path> required" }
    $s = Get-State
    $watch = Resolve-BusPath $s $File
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    Say "Waiting for $watch (timeout ${TimeoutSec}s)..."
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $watch) {
            Start-Sleep -Milliseconds 700   # let the writer finish flushing
            Say "Artifact landed: $watch"
            Get-Content $watch -Raw
            exit 0
        }
        Start-Sleep -Seconds 3
    }
    Write-Host "[relay] TIMEOUT after ${TimeoutSec}s - $watch never appeared." -ForegroundColor Yellow
    Say "Last 30 lines from the agent pane:"
    if ($Agent) {
        psmux capture-pane -t (Get-PaneTarget $s $Agent) -p | Select-Object -Last 30
    }
    exit 2
}

# ============================================================= BUS ===========
if ($Command -eq 'bus') {
    $s = Get-State
    Get-ChildItem (Join-Path $s.workspace '.relay') -Recurse -File -EA 0 |
        Where-Object { $_.DirectoryName -notlike '*\.relay\launch' } |
        Sort-Object LastWriteTime -Descending |
        Select-Object LastWriteTime, @{n = 'artifact'; e = { $_.FullName.Replace($s.workspace, '') } } |
        Format-Table -AutoSize
    exit 0
}

# ========================================================== ATTACH ===========
if ($Command -eq 'attach') {
    Say "Run this in your own terminal (cannot attach from a tool call):"
    Write-Host "    psmux attach -t $Session" -ForegroundColor White
    exit 0
}
