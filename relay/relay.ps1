<#
.SYNOPSIS
  Medina Agentic Relay - psmux control plane.

  Opus (orchestrator) drives two Gemini panes - executor and scout - and an Opus
  validator, as live panes in a psmux session. Content moves over a file bus
  (.relay/) so results are clean and lossless; psmux provides process
  persistence, liveness and the ability to send follow-up instructions into a
  running agent.

  Cost shape as of 2026-08-09: the validator is the ONLY Claude pane. Executor
  and scout both run Antigravity CLI and spend no Claude quota, so evidence
  gathering is effectively free and is deliberately made deep (re-run, probe,
  assertion audit). The scout compacts that depth into a capped evidence file,
  so the one paid pane reads findings rather than raw log volume - which is what
  makes Opus affordable in the seat where judgment actually happens.

.NOTES
  Windows PowerShell 5.1 compatible. No pwsh 7 syntax.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('new', 'up', 'down', 'status', 'send', 'dispatch', 'capture', 'wait', 'attach', 'bus', 'health', 'restart', 'snapshot', 'autopilot')]
    [string]$Command = 'status',

    # Positional so 'relay new my-app' reads the way you would say it.
    [Parameter(Position = 1)]
    [string]$Name,

    [string]$Workspace,
    [ValidateSet('executor', 'validator', 'scout', 'mutator', 'all')]
    [string]$Agent,
    [string]$Text,
    [string]$Task,
    [string]$File,
    [int]$Lines = 60,
    [int]$TimeoutSec = 900,
    [string]$Session = 'relay',
    [switch]$Safe,

    # 'health' probes the agy panes by default because they are free. -Deep adds
    # the same probe to the validator, which costs Claude quota - worth it when
    # you suspect that pane specifically, wasteful as a routine check.
    [switch]$Deep,

    # --- autopilot knobs -----------------------------------------------------
    # Autopilot runs the whole queue unattended, so every way it could run away
    # needs a ceiling. These are those ceilings, not tuning parameters.
    [int]$BudgetMin = 480,          # hard wall-clock cap on a whole run
    [int]$MaxCycles = 24,           # hard cap on task cycles in one run
    [int]$MaxConsecutiveFails = 3,  # stop rather than grind on work that is not converging
    [int]$MutationDrainMin = 20,    # how long to wait for late mutation reports at the end
    [switch]$NoMutation             # skip the mutation lane entirely
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

# psmux pane ids are NOT globally unique the way tmux's are - they are allocated
# per session. Verified 2026-08-11: with a second session open, a bare '%1' target
# resolved to that session's pane, not the relay's. Every send, dispatch and
# capture would then land in a stranger's shell while the relay reported success,
# and the agent that never got the message looks exactly like one that crashed.
#
# 'session:%id' resolves correctly. 'session:window.%id' does NOT - it silently
# picks the wrong pane (it resolved '%1' to pane index 3) - so do not "improve"
# this by adding the window.
function Get-PaneId($state, $agentName) {
    if ($agentName -eq 'executor')  { return $state.executorPane }
    if ($agentName -eq 'validator') { return $state.validatorPane }
    if ($agentName -eq 'scout')     { return $state.scoutPane }
    if ($agentName -eq 'mutator')   { return $state.mutatorPane }
    Fail "Unknown agent '$agentName'. Use 'executor', 'scout', 'mutator' or 'validator'."
}

# Order matters in a few places (boot, health, restart -Agent all): the mutator is
# last because it is the only optional lane - a relay with a dead mutator still
# produces correct verdicts, just without mutation coverage.
$script:AllAgents = @('executor', 'validator', 'scout', 'mutator')

function Get-PaneTarget($state, $agentName) {
    return "$($state.session):$(Get-PaneId $state $agentName)"
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

# --- pane state classification ----------------------------------------------
#
# Everything below exists because of one hard lesson (2026-08-10): a pane that has
# stopped working looks EXACTLY like a healthy idle one. The old check treated
# '? for shortcuts' as proof an agent was past its startup gate and therefore fine.
# That string is also what a dead scout displays. Six consecutive tasks ran with no
# scout evidence while every status check reported the relay healthy.
#
# So: never infer health from the idle chrome. Match faults explicitly, and prove
# liveness by making the agent answer.

# Blocking prompts we know how to clear ourselves. Each is a modal that swallows
# input, so a dispatched instruction is simply absorbed and never acted on.
$script:ClearablePrompts = @(
    @{ Pattern = 'trust (the contents of this|this folder)'; Key = 'Enter'; What = 'folder-trust prompt' },
    # agy periodically asks for CLI feedback. Seen sitting on a crashed scout pane
    # 2026-08-10; it blocks the input line exactly like the trust gate does.
    @{ Pattern = "How's the CLI experience so far"; Key = '0'; What = 'agy feedback survey' }
)

# Faults that no keystroke fixes. These need the process restarted.
$script:FatalPatterns = @(
    # The scout killer. agy's OAuth access token refreshes into a state the server
    # rejects, and the process then 401s forever - 1030 consecutive failures were
    # logged on 2026-08-10 before the pane was killed. It never self-heals, and it
    # drops back to a normal-looking prompt afterwards.
    @{ Pattern = 'Agent execution terminated due to error'; What = 'agy agent fault (usually a wedged OAuth token)' },
    @{ Pattern = 'UNAUTHENTICATED|invalid authentication credentials'; What = 'expired/rejected credentials' },
    @{ Pattern = '/rate-limit-options|usage limit reached|Claude usage limit'; What = 'Claude rate limit' },
    @{ Pattern = 'Please run /login|Invalid API key|not authenticated'; What = 'agent is signed out' }
)

# An agent mid-task is healthy - and must not be interrupted by a liveness probe.
#
# Match ONLY the interrupt hints a TUI shows while it is actually running. Do not match
# activity words like "Cogitated"/"Thought for 3s" - those are completed-step summaries
# that stay on screen forever, so an idle pane reads as permanently busy and health can
# never look at it again. That is the same "looks fine, is dead" failure this file exists
# to prevent, just wearing a different hat.
$script:BusyPatterns = 'esc to cancel|esc to interrupt|ctrl\+c to (stop|cancel)|Running\.\.\.|Running…|Cogitating|Thinking…'

# Evidence that an agent TUI has finished booting and is sitting at its prompt.
#
# This says "booted", NOT "healthy" - a wedged agy pane matches these too, which is the
# whole reason Test-AgentResponsive exists. Use it only to stop waiting during boot, and
# never as a health verdict.
#
# Grepping for the literal 'READY' alone is not enough on its own: the boot banner
# scrolls off the visible screen, and Opus paraphrases ("Waiting for evidence files to
# grade") rather than emitting the bare token.
$script:BootedPatterns = 'READY|\? for shortcuts|shift\+tab to cycle|bypass permissions on|accept edits on'

# Poll until an agent's TUI is up, or a fatal fault appears. Returns $false on fault or
# timeout. Boot times differ a lot - agy is quick, Claude is not - so this waits rather
# than sampling once and calling a slow starter dead.
function Wait-PaneBooted($target, $timeoutSec = 90) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Get-PaneFault $target) { return $false }
        if (Test-PaneMatch (Get-PaneText $target) $script:BootedPatterns) { return $true }
        Start-Sleep -Seconds 3
    }
    return $false
}

function Get-PaneText($target, $lines = 40) {
    return (psmux capture-pane -t $target -p 2>$null | Select-Object -Last $lines | Out-String)
}

# Relay panes are tiled and therefore narrow, so any banner we match on may be
# hard-wrapped mid-sentence or mid-word. Observed: "Agent execution terminated due
# to error. Error ID: 601\n5d9e3-...". Matching only the raw capture means the
# fault is missed at exactly the pane widths the relay actually runs at.
#
# A wrap either replaces a space with a newline or splits a word. Removing the
# newlines recovers the second case; collapsing whitespace recovers the first. Test
# both, and a pattern matches if any view of the text contains it.
function Test-PaneMatch($txt, $pattern) {
    if ($txt -match $pattern) { return $true }
    if (($txt -replace '\r?\n', '') -match $pattern) { return $true }
    if (($txt -replace '\s+', ' ') -match $pattern) { return $true }
    return $false
}

function Clear-BlockingPrompts($target) {
    $txt = Get-PaneText $target
    foreach ($p in $script:ClearablePrompts) {
        if (Test-PaneMatch $txt $p.Pattern) {
            psmux send-keys -t $target $p.Key | Out-Null
            Start-Sleep -Milliseconds 600
            return $p.What
        }
    }
    return $null
}

function Get-PaneFault($target) {
    $txt = Get-PaneText $target
    foreach ($f in $script:FatalPatterns) {
        if (Test-PaneMatch $txt $f.Pattern) { return $f.What }
    }
    return $null
}

function Test-PaneBusy($target) {
    return (Test-PaneMatch (Get-PaneText $target) $script:BusyPatterns)
}

# The only check that actually distinguishes a working agent from a wedged one:
# make it say something new.
#
# The expected answer is deliberately never written into the prompt we send. The
# pane echoes whatever we type, and a pane that has dropped to a bare shell echoes
# it a second time inside a "not recognized" error - so any probe whose answer
# appears verbatim in its own question can be passed by something that is not an
# agent at all. Here the two halves are only ever adjacent in a real reply.
function Test-AgentResponsive($target, $timeoutSec = 75) {
    $nonce  = ([guid]::NewGuid().ToString('N').Substring(0, 6)).ToUpper()
    $expect = "RELAYOK$nonce"
    Send-Line $target "Reply with the word RELAYOK immediately followed by $nonce as one word, nothing else. Do not use any tools."
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $txt = Get-PaneText $target 60
        if ($txt -match [regex]::Escape($expect)) { return $true }
        $fault = Get-PaneFault $target
        if ($fault) { return $false }
    }
    return $false
}

# --- process-level liveness --------------------------------------------------
#
# The fault classification above reads the SCREEN. That misses the failure mode where
# the agent process simply exits: panes are launched with -NoExit precisely so a crash
# stays inspectable, which means the pane survives as a bare PowerShell prompt. A bare
# prompt matches no fatal pattern, shows no busy hint, and prints nothing alarming - it
# is invisible to every check in this file.
#
# psmux cannot help here: '#{pane_current_command}' reports the pane's root process, and
# for every relay pane that is 'powershell' whether the agent is alive or not (verified
# 2026-08-12 against a healthy relay - all four panes reported 'powershell'). What does
# work is '#{pane_pid}' plus a walk of that pid's descendants looking for the agent's own
# executable.
$script:AgentProcess = @{
    executor  = 'agy.exe'
    scout     = 'agy.exe'
    mutator   = 'agy.exe'
    validator = 'claude.exe'
}

function Get-PanePid($state, $agentName) {
    $paneId = Get-PaneId $state $agentName
    if (-not $paneId) { return $null }
    $rows = @(psmux list-panes -t "$($state.session):agents" -F "#{pane_id} #{pane_pid}" 2>$null)
    foreach ($r in $rows) {
        $parts = $r.Trim() -split '\s+'
        if ($parts.Count -ge 2 -and $parts[0] -eq $paneId) { return [int]$parts[1] }
    }
    return $null
}

function Test-AgentProcessAlive($state, $agentName) {
    $rootPid = Get-PanePid $state $agentName
    if (-not $rootPid) { return $false }
    $want = $script:AgentProcess[$agentName]
    if (-not $want) { return $true }

    $all = @(Get-CimInstance Win32_Process -EA SilentlyContinue |
                Select-Object ProcessId, ParentProcessId, Name)
    if ($all.Count -eq 0) { return $true }   # cannot tell; do not report a false crash

    # The agent sits two levels down (psmux shell -> launcher shell -> agent), so this
    # walks the whole subtree rather than checking direct children.
    $seen  = @{ "$rootPid" = $true }
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($rootPid)
    while ($queue.Count -gt 0) {
        $p = $queue.Dequeue()
        foreach ($c in $all) {
            if ($c.ParentProcessId -ne $p) { continue }
            if ($seen.ContainsKey("$($c.ProcessId)")) { continue }
            if ($c.Name -eq $want) { return $true }
            $seen["$($c.ProcessId)"] = $true
            $queue.Enqueue($c.ProcessId)
        }
    }
    return $false
}

# One call that answers "can I hand this agent work right now?" - screen faults, blocking
# modals and a dead process all in one place, so no caller has to remember all three.
# Returns $null when the agent looks usable, otherwise the reason it does not.
function Get-AgentTrouble($state, $agentName) {
    if (-not (Get-PaneId $state $agentName)) {
        return "no pane for '$agentName' - this relay was started before that agent existed"
    }
    $t = Get-PaneTarget $state $agentName
    Clear-BlockingPrompts $t | Out-Null
    $fault = Get-PaneFault $t
    if ($fault) { return $fault }
    if (-not (Test-AgentProcessAlive $state $agentName)) {
        return "$($script:AgentProcess[$agentName]) is not running - the agent exited and left a bare shell"
    }
    return $null
}

# Boot-time gate clearing. Unlike the old version this does not accept idle chrome
# as evidence of anything - it only clears modals. Liveness is proven separately.
function Clear-TrustPrompts($targets, $timeoutSec = 90) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $pending  = [System.Collections.ArrayList]@($targets)
    while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        foreach ($p in @($pending)) {
            $cleared = Clear-BlockingPrompts $p
            if ($cleared) {
                Say "Cleared $cleared in pane $p"
                $pending.Remove($p)
            }
            elseif (Test-PaneMatch (Get-PaneText $p) $script:BootedPatterns) {
                $pending.Remove($p)
            }
            elseif (Get-PaneFault $p) {
                # Already broken. Waiting out the full deadline for a gate that will
                # never appear just delays the diagnosis the caller needs.
                $pending.Remove($p)
            }
        }
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
    # 'probe' is the scout's sanctioned scratch area. It writes throwaway edge-case
    # tests there rather than into the project's own test tree, so probing never
    # pollutes the diff the scout is simultaneously reporting on.
    #
    # 'mutants' holds one isolated snapshot of the workspace per task, and
    # 'mutation' holds the mutator's findings. The snapshot is what keeps the
    # mutation lane off the critical path: the mutator edits source freely inside
    # its own copy while the executor is already working on the next task in the
    # real tree, and the two can never collide.
    foreach ($d in 'tasks', 'results', 'evidence', 'reports', 'logs', 'probe', 'mutants', 'mutation') {
        New-Item -ItemType Directory -Force (Join-Path $ws ".relay\$d") | Out-Null
    }
}

# --- naming convention on the bus -------------------------------------------
# A task file's basename is the id for every artifact it produces. Autopilot
# depends on this to know what to wait for without parsing the task's Artifacts
# section, so the convention is load-bearing rather than cosmetic.
function Get-BusArtifact($state, $kind, $taskBase) {
    return (Join-Path $state.workspace ".relay\$kind\$taskBase.md")
}

# ============================================================= NEW ===========
# Scaffold a project and bring the relay up on it in one command. This block
# deliberately does NOT exit - it prepares the workspace, then rewrites $Command
# to 'up' and falls through, so there is exactly one implementation of 'up'.
if ($Command -eq 'new') {
    if (-not $Name) { Fail "Usage: relay.ps1 new <project-name|path>" }

    $target = $Name
    if (-not [System.IO.Path]::IsPathRooted($target)) {
        $target = Join-Path (Get-Location).Path $Name
    }

    # Never scaffold over existing work. An empty directory is fine to adopt.
    if (Test-Path $target) {
        $existing = @(Get-ChildItem -Force $target -EA 0)
        if ($existing.Count -gt 0) {
            Fail "$target already exists and is not empty. Use 'up -Workspace `"$target`"' to run the relay on it as-is."
        }
    }
    else {
        New-Item -ItemType Directory -Force $target | Out-Null
    }
    $target = (Resolve-Path $target).Path
    $projName = Split-Path -Leaf $target
    Say "Created  $target"

    # --- git -----------------------------------------------------------------
    # The scout reads 'git diff' as its primary evidence, so a repo is not
    # optional here - without one it has nothing authoritative to compare against.
    $hasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
    if (-not $hasGit) {
        Write-Host "[relay] WARNING: git not found. The scout falls back to file listings," -ForegroundColor Yellow
        Write-Host "        which is weaker evidence than a diff." -ForegroundColor Yellow
    }

    # The whole bus is ignored on purpose. These are coordination artifacts, not
    # source - and keeping them untracked means the scout's 'git status --short'
    # shows exactly what the executor changed in the codebase, which is the
    # signal the relay exists to produce. The artifacts still live on disk.
    $gitignore = @(
        '# Relay coordination bus - artifacts stay on disk, out of version control'
        '.relay/'
        ''
        '# Editors / OS'
        '.vscode/'
        '.idea/'
        '.DS_Store'
        'Thumbs.db'
        ''
        '# Common build & dependency output'
        'node_modules/'
        'dist/'
        'build/'
        'target/'
        '__pycache__/'
        '*.py[cod]'
        '.venv/'
        'venv/'
        ''
        '# Logs & local env'
        '*.log'
        '.env'
        '.env.local'
        ''
    ) -join "`r`n"
    Set-Content (Join-Path $target '.gitignore') $gitignore -Encoding utf8

    $readme = @(
        "# $projName"
        ''
        'Worked on with the [Medina Agentic Relay](https://github.com/dmediontherise/medina-agentic-relay-setup).'
        ''
        '## Relay'
        ''
        '```'
        'relay status                      # session health and bus contents'
        'relay capture -Agent executor     # is that pane working, or stuck on a prompt?'
        'relay down                        # tear it down'
        '```'
        ''
        'Task specs live in `.relay/tasks/`. Verdicts land in `.relay/reports/`.'
        ''
    ) -join "`r`n"
    Set-Content (Join-Path $target 'README.md') $readme -Encoding utf8

    if ($hasGit) {
        Push-Location $target
        try {
            git init -q 2>&1 | Out-Null
            git add -A 2>&1 | Out-Null
            $commitOut = git commit -q -m "Initial commit" 2>&1
            if ($LASTEXITCODE -ne 0) {
                # Almost always missing user.name/user.email. Say which, rather
                # than leaving a repo with a silently empty history.
                Write-Host "[relay] WARNING: git commit failed - repo initialized but nothing committed." -ForegroundColor Yellow
                Write-Host "        $commitOut" -ForegroundColor Yellow
            }
            else { Say "git init + initial commit" }
        }
        finally { Pop-Location }
    }

    # --- seed a task the executor can actually be pointed at ------------------
    New-BusDirs $target
    $seed = @(
        '# Task 001: <title>'
        ''
        '## Objective'
        '<What "done" means, in one or two sentences.>'
        ''
        '## Scope'
        '- In:  <files or areas the executor may touch>'
        '- Out: <explicitly off-limits>'
        ''
        '## Requirements'
        '<Numbered and individually verifiable. The validator grades against THIS'
        'file, so anything vague here produces a worthless verdict. Write them so'
        'someone who did not read this conversation could check them.>'
        ''
        '1. '
        '2. '
        ''
        '## Verification'
        '<Commands that must pass, with the expected outcome. The scout re-runs'
        'every one of these itself rather than trusting the executor.'
        ''
        'Each command must be a SINGLE LINE that runs as written. The executor'
        'rewrites commands it cannot run and then reports the result it expected'
        'rather than the one it observed - so no try/except, if or for after a'
        'semicolon in a `python -c`. Prefer exact stdout, an assert one-liner, or'
        'pushing the assertion into the test suite and verifying with `pytest -q`.>'
        ''
        '- `<command>` -> <expected>'
        ''
        '## Artifacts'
        '- results:  `.relay/results/001-first-task.md`'
        '- evidence: `.relay/evidence/001-first-task.md`'
        '- report:   `.relay/reports/001-first-task.md`'
        ''
    ) -join "`r`n"
    $seedPath = Join-Path $target '.relay\tasks\001-first-task.md'
    Set-Content $seedPath $seed -Encoding utf8
    Say "Seeded   .relay\tasks\001-first-task.md"

    # Hand off to 'up' below rather than reimplementing it.
    $Workspace = $target
    $Command   = 'up'
    $script:ScaffoldedNew = $true
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
    foreach ($c in $script:AllAgents) {
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
        Write-Host "[relay] WARNING: 'claude' not found - the validator will not start." -ForegroundColor Yellow
        $claudeExe = 'claude'
    }
    Say "agy    bin   : $agyExe   (executor + scout)"
    Say "claude bin   : $claudeExe   (validator)"

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
    $agyModel = 'gemini-3.6-flash-high'
    $agyFlags = '--dangerously-skip-permissions'
    if ($Safe) { $agyFlags = '--mode accept-edits' }

    # agy does NOT root itself in the process working directory. Proven 2026-08-09: a
    # pane whose cwd is the workspace still runs its tools in C:\Users\<u>\.gemini\
    # antigravity-cli, so a relative path like '.relay/executor.md' resolves there,
    # misses, and the agent starts hunting the filesystem for something matching. In
    # testing both agy panes found and loaded a charter belonging to an entirely
    # different project, then reported READY on it.
    #
    # --add-dir pins the workspace explicitly and makes the tools run there. psmux's
    # -c is not sufficient - it sets the pane's cwd correctly, and agy ignores it.
    $agyRoot = "--add-dir `"$Workspace`""
    $agyBoot = "Read .relay/executor.md and follow it as your operating contract for this session. Reply READY when loaded, then wait for task files."
    $execLauncher = Write-Launcher 'executor' "& `"$agyExe`" $agyRoot --model $agyModel $agyFlags -i `"$agyBoot`"`r`n"

    # acceptEdits permits file edits but still gates every new Bash command shape behind
    # an approval prompt - which strands a review pane, whose entire job is running
    # verification commands. An unattended pane sitting on that prompt is this relay's
    # classic silent stall. User chose bypassPermissions (2026-08-08); the charter, not
    # the sandbox, is what keeps the validator from editing the code it grades.
    # -Safe trades autonomy back for a human in the loop. Applies to the validator only
    # now that the scout has moved to agy and takes $agyFlags instead.
    $claudeMode = 'bypassPermissions'
    if ($Safe) { $claudeMode = 'acceptEdits' }

    # Validator: Opus 5. Judgment only, grading evidence it did not gather.
    #
    # It ran Opus originally, was downgraded to Sonnet on 2026-08-08 after the validator
    # and the then-Sonnet scout together burned through the Claude limit mid-run and
    # stranded the relay on /rate-limit-options dialogs, and was restored to Opus on
    # 2026-08-09 once the scout moved to agy. That restoration is not a reversal of the
    # earlier call - the condition behind it changed. This is now the only pane spending
    # Claude quota at all, so the whole budget goes to the one step that is pure judgment.
    #
    # If rate limits ever bite here again, drop this to sonnet before touching anything
    # else: it is the single lever that matters, and the relay keeps working on Sonnet.
    $valBoot = "Read .relay/validator.md and follow it as your operating contract for this session. Reply READY when loaded, then wait for evidence files to grade."
    $valLauncher = Write-Launcher 'validator' "& `"$claudeExe`" --model opus --permission-mode $claudeMode `"$valBoot`"`r`n"

    # Scout: agy on the same Gemini tier as the executor (user's call, 2026-08-09; there
    # is no 3.6 Pro tier - see 'agy models'). Independence comes from role separation,
    # not model identity: a separate process with a separate charter, which did not write
    # the code and sees only the diff and the result file. Same launch posture this pane
    # already ran under, carried over unchanged via $agyFlags. Its charter keeps it out of
    # the source tree, and .relay/probe/ gives it a sanctioned place to write instead.
    $scoutBoot = "Read .relay/scout.md and follow it as your operating contract for this session. Reply READY when loaded, then wait for result files to gather evidence on."
    $scoutLauncher = Write-Launcher 'scout' "& `"$agyExe`" $agyRoot --model $agyModel $agyFlags -i `"$scoutBoot`"`r`n"

    # Mutator: the secondary scout, agy again, dedicated to mutation testing.
    #
    # It exists as its own pane for one reason: mutation testing is slow (minutes to
    # tens of minutes) and the relay cannot afford to hold the validator behind it. A
    # pane can only do one thing at a time, so giving mutation work to the primary
    # scout would serialise it into the critical path - which is exactly what a second
    # free agy pane buys us out of. It runs against a frozen snapshot of the workspace
    # in .relay/mutants/<task>/, so it can still be grinding on task 007 while the
    # executor is already editing the real tree for task 008.
    $mutBoot = "Read .relay/mutator.md and follow it as your operating contract for this session. Reply READY when loaded, then wait to be pointed at a mutation snapshot."
    $mutLauncher = Write-Launcher 'mutator' "& `"$agyExe`" $agyRoot --model $agyModel $agyFlags -i `"$mutBoot`"`r`n"

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

    # Re-tile after EVERY split, not once at the end. Each split halves the pane it
    # targets, so splitting five ways in a row runs the last one out of rows:
    # "pane too small to split vertically (3 rows, need 5)" - which is how the fifth
    # pane silently failed to exist the first time this went from four agents to five.
    # Tiling between splits keeps every pane large enough to split again.
    foreach ($l in $valLauncher, $scoutLauncher, $mutLauncher, $watchLauncher) {
        psmux split-window -t "${Session}:agents" -c $Workspace (PaneCmd $l) | Out-Null
        Start-Sleep -Milliseconds 1200
        psmux select-layout -t "${Session}:agents" tiled | Out-Null
        Start-Sleep -Milliseconds 300
    }
    Start-Sleep -Milliseconds 500

    # Resolve stable pane IDs (%N) so later targeting survives index shuffling.
    $panes = @(psmux list-panes -t "${Session}:agents" -F "#{pane_index} #{pane_id}")
    if ($panes.Count -lt 5) { Fail "Expected 5 panes, got $($panes.Count)." }
    $ids = @{}
    foreach ($p in $panes) {
        $parts = $p.Trim() -split '\s+'
        $ids[$parts[0]] = $parts[1]
    }

    $now = (Get-Date).ToString('o')
    $state = [ordered]@{
        session       = $Session
        workspace     = $Workspace
        executorPane  = $ids['0']
        validatorPane = $ids['1']
        scoutPane     = $ids['2']
        mutatorPane   = $ids['3']
        busPane       = $ids['4']
        safe          = [bool]$Safe
        created       = $now
        # Persisted so 'restart' can respawn one wedged pane in place instead of
        # tearing down the whole relay and losing the other agents' context.
        launchers     = [ordered]@{
            executor  = $execLauncher
            validator = $valLauncher
            scout     = $scoutLauncher
            mutator   = $mutLauncher
        }
        # Per-agent boot time. agy panes wedge after long uptime, so 'health' needs
        # to know how old each process is - not just when the session was created.
        booted        = [ordered]@{
            executor  = $now
            validator = $now
            scout     = $now
            mutator   = $now
        }
    }
    $state | ConvertTo-Json -Depth 5 | Set-Content $StateFile -Encoding utf8

    $targets = @("${Session}:$($ids['0'])", "${Session}:$($ids['1'])", "${Session}:$($ids['2'])", "${Session}:$($ids['3'])")

    # Agents boot into a folder-trust gate; clear it before declaring the relay up.
    Say "Waiting for agents to boot and clearing startup prompts..."
    Clear-TrustPrompts $targets

    # Do not report a relay as up on the strength of the panes existing. Every
    # silent failure this relay has had looked fine at exactly this point.
    Say "Verifying each agent answers..."
    $names = $script:AllAgents
    $bad = @()
    for ($i = 0; $i -lt $names.Count; $i++) {
        $n = $names[$i]
        $t = $targets[$i]
        $fault = Get-PaneFault $t
        if ($fault) { $bad += "$n : $fault"; continue }
        # The validator is Claude and every probe costs quota, so it gets the cheap
        # passive check unless -Deep is asked for. The agy panes are free: probe them.
        if ($n -eq 'validator' -and -not $Deep) {
            if (Wait-PaneBooted $t) { Say "  $n : booted (passive check - pass -Deep to probe it)" }
            else { $bad += "$n : never reached its prompt" }
            continue
        }
        if (Test-AgentResponsive $t) { Say "  $n : responding" }
        else { $bad += "$n : did not answer a liveness probe" }
    }

    if ($bad.Count -gt 0) {
        Write-Host ""
        Write-Host "[relay] RELAY IS NOT HEALTHY - do not dispatch work yet:" -ForegroundColor Red
        foreach ($b in $bad) { Write-Host "        $b" -ForegroundColor Red }
        Write-Host "        Inspect: relay.ps1 capture -Agent <name>" -ForegroundColor Yellow
        Write-Host "        Recover: relay.ps1 restart -Agent <name>" -ForegroundColor Yellow
        exit 3
    }

    Say "Relay up - all four agents answered."
    Say "  executor  (agy / $agyModel) -> $($ids['0'])"
    Say "  validator (claude opus)                  -> $($ids['1'])"
    Say "  scout     (agy / $agyModel) -> $($ids['2'])"
    Say "  mutator   (agy / $agyModel) -> $($ids['3'])"
    Say "  bus watch                                -> $($ids['4'])"
    Say "Attach with: psmux attach -t $Session"
    if ($script:ScaffoldedNew) {
        Write-Host ""
        Write-Host "  Next:" -ForegroundColor White
        Write-Host "    1. Fill in .relay\tasks\001-first-task.md (requirements + verification)" -ForegroundColor Gray
        Write-Host "    2. Run /relay-task in Claude Code from $Workspace" -ForegroundColor Gray
        Write-Host "       or dispatch by hand:  relay dispatch -Agent executor -Task .relay\tasks\001-first-task.md" -ForegroundColor Gray
    }
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

    # Tasks with a result but no evidence mean the scout was skipped or broken -
    # the exact silent degradation that had Opus doing the scout's work for six
    # cycles. Surface it here, where it is cheap to notice.
    $missing = @()
    foreach ($r in @(Get-ChildItem (Join-Path $bus 'results') -File -Filter *.md -EA 0)) {
        if (-not (Test-Path (Join-Path $bus "evidence\$($r.Name)"))) { $missing += $r.BaseName }
    }
    if ($missing.Count -gt 0) {
        Write-Host "        WARNING: $($missing.Count) task(s) have results but NO scout evidence:" -ForegroundColor Yellow
        Write-Host "                 $($missing -join ', ')" -ForegroundColor Yellow
        Write-Host "                 Check the scout: relay.ps1 health -Agent scout" -ForegroundColor Yellow
    }

    if ($s.booted -and $s.booted.scout) {
        $hrs = [math]::Round(((Get-Date) - [datetime]::Parse($s.booted.scout)).TotalHours, 1)
        if ($hrs -gt 8) {
            Write-Host "        NOTE: agy panes have been up ${hrs}h. Long-lived panes have wedged their" -ForegroundColor Yellow
            Write-Host "              OAuth token before (~12h). 'restart -Agent all' is cheap insurance." -ForegroundColor Yellow
        }
    }
    Write-Host "        Agent liveness is NOT checked here - run: relay.ps1 health" -ForegroundColor Gray
    exit 0
}

# ========================================================== HEALTH ===========
# The check 'status' could never do. 'status' proves panes exist; this proves the
# agents in them still work. Exits non-zero when any agent is unhealthy so a caller
# cannot skim past a dead lane the way six task cycles did on 2026-08-10.
if ($Command -eq 'health') {
    $s = Get-State
    $live = psmux ls 2>$null | Out-String
    if (-not ($live -match "(?m)^$([regex]::Escape($s.session)):")) {
        Write-Host "[relay] DOWN - no psmux session '$($s.session)'." -ForegroundColor Red
        exit 1
    }

    $names = $script:AllAgents
    if ($Agent -and $Agent -ne 'all') { $names = @($Agent) }

    $unhealthy = 0
    foreach ($n in $names) {
        $line = "  {0,-10}" -f $n

        # A relay started before this agent existed has no pane for it. Saying that
        # plainly beats targeting 'relay:' with an empty pane id, which psmux happily
        # resolves to something arbitrary.
        if (-not (Get-PaneId $s $n)) {
            Write-Host "$line ABSENT - this relay was started before the $n pane existed." -ForegroundColor Yellow
            Write-Host "             rebuild it: relay.ps1 down; relay.ps1 up -Workspace `"$($s.workspace)`"" -ForegroundColor Yellow
            $unhealthy++
            continue
        }
        $t = Get-PaneTarget $s $n

        # Uptime matters: the observed wedge took ~12.5h of uptime plus a long idle
        # gap. Surfacing age turns "why did the scout die again" into a prediction.
        $age = ''
        if ($s.booted -and $s.booted.$n) {
            $hrs = [math]::Round(((Get-Date) - [datetime]::Parse($s.booted.$n)).TotalHours, 1)
            $age = " (up ${hrs}h)"
        }

        $cleared = Clear-BlockingPrompts $t
        if ($cleared) { Write-Host "$line BLOCKED -> cleared $cleared$age" -ForegroundColor Yellow }

        $fault = Get-PaneFault $t
        if ($fault) {
            Write-Host "$line FAULT: $fault$age" -ForegroundColor Red
            Write-Host "             recover with: relay.ps1 restart -Agent $n" -ForegroundColor Yellow
            $unhealthy++
            continue
        }

        # Checked before the busy test on purpose: a dead agent's pane is not busy and
        # not faulted, so without this it falls through to the probe and merely looks
        # slow. This is the check that names it as a crash.
        if (-not (Test-AgentProcessAlive $s $n)) {
            Write-Host "$line CRASHED - $($script:AgentProcess[$n]) is not running in that pane$age" -ForegroundColor Red
            Write-Host "             the pane survived as a bare shell; recover with: relay.ps1 restart -Agent $n" -ForegroundColor Yellow
            $unhealthy++
            continue
        }

        if (Test-PaneBusy $t) {
            Write-Host "$line BUSY (working - not probed)$age" -ForegroundColor Cyan
            continue
        }

        if ($n -eq 'validator' -and -not $Deep) {
            if (Test-PaneMatch (Get-PaneText $t) $script:BootedPatterns) {
                Write-Host "$line IDLE at its prompt, no fault detected$age  (pass -Deep to probe it - costs Claude quota)" -ForegroundColor Gray
            }
            else {
                Write-Host "$line NOT AT ITS PROMPT - neither booted nor faulted$age" -ForegroundColor Yellow
                Write-Host "             inspect it: relay.ps1 capture -Agent validator" -ForegroundColor Yellow
                $unhealthy++
            }
            continue
        }

        if (Test-AgentResponsive $t) {
            Write-Host "$line OK - answered$age" -ForegroundColor Green
        }
        else {
            Write-Host "$line UNRESPONSIVE - no answer to a liveness probe$age" -ForegroundColor Red
            Write-Host "             recover with: relay.ps1 restart -Agent $n" -ForegroundColor Yellow
            $unhealthy++
        }
    }

    if ($unhealthy -gt 0) {
        Write-Host "[relay] $unhealthy agent(s) unhealthy." -ForegroundColor Red
        exit 1
    }
    Say "All checked agents healthy."
    exit 0
}

# ========================================================= RESTART ===========
# A wedged agy pane is fixed by restarting that process and nothing else - its
# credentials are re-read clean at startup. Restarting only the broken pane keeps
# the other two agents' conversation context, which a full down/up throws away.
#
# Do NOT reach for 'respawn-pane' here. psmux accepts it, exits 0, and silently
# discards the shell-command (verified 2026-08-11) - the pane comes back as a bare
# shell with no agent in it, which is worse than the fault being fixed because it
# reports success. kill-pane + split-window actually runs the launcher.
#
# Pane ids of surviving panes are stable across a kill (also verified), and the
# pane created by split-window becomes the active one, so the new id can be read
# straight back off the window. Only indices shuffle - and nothing targets those.
#
# Factored into a function because autopilot restarts wedged panes on its own. That
# self-healing is the single biggest reason a long unattended run survives: the fault
# this relay actually hits is a wedged agy token, and it is fixed by exactly this.
function Restart-Agents($s, $names, $deep) {
    if (-not $s.launchers) {
        Fail "This relay was started before launchers were recorded. Run 'down' then 'up' once to enable restart."
    }

    $win = "$($s.session):agents"
    $targets = @()
    foreach ($n in $names) {
        $launcher = $s.launchers.$n
        if (-not $launcher -or -not (Test-Path $launcher)) {
            Fail "Launcher for '$n' is missing ($launcher). Run 'down' then 'up'."
        }

        $oldId = Get-PaneId $s $n
        if ($oldId) {
            psmux kill-pane -t (Get-PaneTarget $s $n) 2>$null | Out-Null
            Start-Sleep -Milliseconds 800
        }
        psmux split-window -t $win -c $s.workspace `
            "powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File `"$launcher`"" | Out-Null
        Start-Sleep -Milliseconds 1500

        # split-window leaves the new pane active, so this reads back its id.
        $newId = (psmux display-message -p -t $win "#{pane_id}").Trim()
        if (-not $newId) { Fail "Could not resolve the new pane id for '$n'." }

        if     ($n -eq 'executor')  { $s.executorPane  = $newId }
        elseif ($n -eq 'validator') { $s.validatorPane = $newId }
        elseif ($n -eq 'scout')     { $s.scoutPane     = $newId }
        elseif ($n -eq 'mutator')   { $s.mutatorPane   = $newId }

        if ($s.booted) {
            # A state file written before this agent existed has no slot for it.
            if ($s.booted.PSObject.Properties.Name -contains $n) { $s.booted.$n = (Get-Date).ToString('o') }
            else { $s.booted | Add-Member -NotePropertyName $n -NotePropertyValue (Get-Date).ToString('o') }
        }
        Say "Restarted $n -> $newId"
        $targets += "$($s.session):$newId"
    }

    psmux select-layout -t $win tiled | Out-Null
    $s | ConvertTo-Json -Depth 5 | Set-Content $StateFile -Encoding utf8

    Say "Waiting for restarted agents to boot..."
    Start-Sleep -Seconds 5
    Clear-TrustPrompts $targets

    # Always PROBE after a restart, validator included - never accept the passive
    # "reached its prompt" check here.
    #
    # The quota argument for passive-checking the validator applies to routine health
    # polling, not to a restart: a restart exists to establish that a broken agent works
    # again, and one probe is a negligible price for that answer. Skipping it reports
    # success on exactly the case you restarted to fix.
    #
    # 2026-08-15: `restart -Agent validator` on a 59h pane returned "booted" and exited 0,
    # but the pane never accepted input - three messages vanished into it, and the
    # scrollback showed an empty prompt with no boot exchange at all. `Wait-PaneBooted`
    # was satisfied by 'bypass permissions on', which the status bar paints the instant the
    # TUI draws, well before Claude can read anything. A full down/up fixed it; a second
    # pane restart would not have. If this recurs, go straight to down/up rather than
    # restarting the pane again.
    $bad = @()
    for ($i = 0; $i -lt $names.Count; $i++) {
        $n = $names[$i]; $t = $targets[$i]
        if (Test-AgentResponsive $t) { Say "  $n : responding" } else { $bad += $n }
    }
    return $bad
}

if ($Command -eq 'restart') {
    if (-not $Agent) { Fail "-Agent required (executor|scout|mutator|validator|all)" }
    $s = Get-State

    $names = $script:AllAgents
    if ($Agent -ne 'all') { $names = @($Agent) }

    $bad = Restart-Agents $s $names $Deep
    if ($bad.Count -gt 0) {
        Write-Host "[relay] still unhealthy after restart: $($bad -join ', ')" -ForegroundColor Red
        Write-Host "        Inspect with: relay.ps1 capture -Agent <name>" -ForegroundColor Yellow
        exit 1
    }
    Say "Restart complete - agents responding."
    exit 0
}

# ============================================================ SEND ===========
if ($Command -eq 'send') {
    if (-not $Agent) { Fail "-Agent required (executor|scout|validator)" }
    if (-not $Text)  { Fail "-Text required" }
    $s = Get-State
    Send-Line (Get-PaneTarget $s $Agent) $Text
    Say "Sent to $Agent."
    exit 0
}

# ======================================================== DISPATCH ===========
# Hand a task file to an agent. The task file IS the interface - keeps quoting
# sane and gives the agent a durable spec it can re-read.
function Get-DispatchMessage($agentName, $rel, $taskBase) {
    if ($agentName -eq 'scout') {
        return "Gather evidence for: $rel . Follow your contract in .relay/scout.md - re-run the verification yourself, probe the edge cases the task implies, audit the tests for real assertions, and write the compacted evidence file named in the task. Do NOT do mutation testing; the mutator pane owns that. Observations only, no verdict."
    }
    if ($agentName -eq 'mutator') {
        return "Mutation pass for: $rel . Follow your contract in .relay/mutator.md . Your isolated snapshot of the workspace is at .relay/mutants/$taskBase/ - do all mutation work in there and never in the live tree. Write findings to .relay/mutation/$taskBase.md . Surviving mutants only, no verdict."
    }
    if ($agentName -eq 'validator') {
        return "Grade this task: $rel . Follow your contract in .relay/validator.md - read the task, the executor result, the scout evidence, and the mutation report at .relay/mutation/$taskBase.md if it exists, then write your verdict to the report path named in the task."
    }
    return "New task on the bus: $rel . Read it, execute it per your contract in .relay/executor.md, and write your completion report to the results path named in the task."
}

# Returns 'ok' or a fault string. Callers decide what a fault means: the CLI exits 3
# so a human notices, autopilot restarts the pane and retries once.
function Invoke-Dispatch($s, $agentName, $taskPath, $note = '') {
    $rel = (Resolve-Path $taskPath).Path.Replace($s.workspace, '').TrimStart('\', '/')
    $taskBase = [System.IO.Path]::GetFileNameWithoutExtension($taskPath)

    # Check the lane before shouting down it. A faulted pane accepts send-keys
    # silently and reports nothing, so without this the dispatch "succeeds" and the
    # caller waits out a full timeout on an agent that died hours ago.
    $target = Get-PaneTarget $s $agentName
    $cleared = Clear-BlockingPrompts $target
    if ($cleared) { Say "Cleared $cleared in $agentName before dispatching" }
    $fault = Get-PaneFault $target
    if ($fault) { return $fault }

    $msg = Get-DispatchMessage $agentName $rel $taskBase
    if ($note) { $msg = "$msg $note" }
    Send-Line $target $msg
    Say "Dispatched $rel -> $agentName"
    return 'ok'
}

if ($Command -eq 'dispatch') {
    if (-not $Task) { Fail "-Task <path to task .md> required" }
    $s = Get-State
    $taskPath = Resolve-BusPath $s $Task
    if (-not (Test-Path $taskPath)) { Fail "Task file not found: $taskPath" }
    $agentName = $Agent
    if (-not $agentName) { $agentName = 'executor' }

    $r = Invoke-Dispatch $s $agentName $taskPath
    if ($r -ne 'ok') {
        Write-Host "[relay] REFUSING TO DISPATCH - $agentName has faulted: $r" -ForegroundColor Red
        Write-Host "        Recover with: relay.ps1 restart -Agent $agentName" -ForegroundColor Yellow
        exit 3
    }
    exit 0
}

# ========================================================= CAPTURE ===========
if ($Command -eq 'capture') {
    if (-not $Agent) { Fail "-Agent required (executor|scout|validator)" }
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

    # A timeout is the moment to say WHY, not just that it happened. Treating this
    # as "the model is slow" is what let a dead scout be quietly written out of the
    # loop for six task cycles instead of being restarted in under a minute.
    if ($Agent) {
        $target = Get-PaneTarget $s $Agent
        $fault = Get-PaneFault $target
        if ($fault) {
            Write-Host "[relay] CAUSE: $Agent has faulted: $fault" -ForegroundColor Red
            Write-Host "        This does not recover on its own. Restart the pane and re-dispatch:" -ForegroundColor Yellow
            Write-Host "            relay.ps1 restart -Agent $Agent" -ForegroundColor Yellow
            Write-Host "            relay.ps1 dispatch -Agent $Agent -Task <task file>" -ForegroundColor Yellow
        }
        elseif (Test-PaneBusy $target) {
            Write-Host "[relay] $Agent is still working - consider a longer -TimeoutSec." -ForegroundColor Yellow
        }
        else {
            Write-Host "[relay] $Agent is idle with no artifact written - it may have missed the" -ForegroundColor Yellow
            Write-Host "        dispatch or answered in the pane instead of writing the file." -ForegroundColor Yellow
            Write-Host "        Check health: relay.ps1 health -Agent $Agent" -ForegroundColor Yellow
        }
        Say "Last 30 lines from the $Agent pane:"
        psmux capture-pane -t $target -p | Select-Object -Last 30
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

# ======================================================== SNAPSHOT ===========
# Freeze the workspace as it stands right now into .relay/mutants/<task>/, so the
# mutator can rewrite source files without ever touching the tree the executor is
# working in.
#
# This is the whole basis of the "mutation does not slow anything down" claim. The
# snapshot costs seconds and is taken at the one moment nothing is being written -
# just after the executor's result lands - after which the mutator grinds for as
# long as it needs while the rest of the relay moves on to the next task.
#
# Dependency directories are junctioned, not copied: node_modules is routinely
# larger than everything else combined, and a mutation run that spends four minutes
# copying it before it starts is a mutation run nobody will leave enabled.
#
# git writes progress to stderr, and PowerShell 5.1 turns a native command's stderr into
# ErrorRecords - which, under this script's $ErrorActionPreference = 'Stop', makes a
# perfectly successful `git worktree add` throw NativeCommandError. Every git call here
# goes through these two helpers so that cannot happen.
function Invoke-GitQuiet {
    param([string[]]$GitArgs)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git @GitArgs 2>$null | Out-Null
        return $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $old }
}

function Get-GitOutput {
    param([string[]]$GitArgs)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return @(& git @GitArgs 2>$null) }
    finally { $ErrorActionPreference = $old }
}

function New-MutantSnapshot($state, $taskBase) {
    $ws   = $state.workspace
    $dest = Join-Path $ws ".relay\mutants\$taskBase"

    # A re-run of the same task gets a clean snapshot. Remove the old worktree
    # through git first, or git keeps a stale administrative record of it.
    if (Test-Path $dest) {
        Invoke-GitQuiet @('-C', $ws, 'worktree', 'remove', '--force', $dest) | Out-Null
        if (Test-Path $dest) { Remove-Item -Recurse -Force $dest -EA 0 }
        Invoke-GitQuiet @('-C', $ws, 'worktree', 'prune') | Out-Null
    }

    $isRepo = $false
    $hasHead = $false
    if (Get-Command git -EA SilentlyContinue) {
        $isRepo = ((Invoke-GitQuiet @('-C', $ws, 'rev-parse', '--is-inside-work-tree')) -eq 0)
        if ($isRepo) {
            $hasHead = ((Invoke-GitQuiet @('-C', $ws, 'rev-parse', '--verify', 'HEAD')) -eq 0)
        }
    }

    $method = 'copy'
    if ($isRepo -and $hasHead) {
        $rc = Invoke-GitQuiet @('-C', $ws, 'worktree', 'add', '--detach', $dest, 'HEAD')
        if ($rc -eq 0 -and (Test-Path $dest)) {
            $method = 'worktree'

            # A worktree checks out HEAD, but the work being mutated is usually still
            # uncommitted - so carry the working tree over as well. Without this the
            # mutator would faithfully mutate the code as it was BEFORE the task and
            # report survivors that have nothing to do with the change under review.
            #
            # 'stash create' builds a commit object for the current working tree without
            # touching the tree or the stash list; checking that commit out into the
            # snapshot moves the real file contents across. Done as a patch file instead,
            # this breaks on binary hunks and on PowerShell's habit of adding a BOM that
            # `git apply` then rejects.
            #
            # DO NOT "improve" this to leave the index alone (e.g. by adding --no-overlay,
            # or restoring only the working tree). Staging the carried-over state is what
            # makes the mutator's restore step correct: its charter tells it to revert each
            # mutant before the next, and the natural command for that is
            # `git checkout <file>`, which restores from the INDEX. With the task's changes
            # staged, that reverts the mutation and keeps the work under test. If the index
            # still matched HEAD, the same command would silently throw away the very
            # change being mutation-tested, and every mutant after the first would be
            # applied to the pre-task baseline - producing a report that looks normal and
            # is entirely meaningless.
            $stashSha = (Get-GitOutput @('-C', $ws, 'stash', 'create') | Select-Object -First 1)
            if ($stashSha) {
                $stashSha = $stashSha.Trim()
                if ($stashSha) {
                    $rc2 = Invoke-GitQuiet @('-C', $dest, 'checkout', $stashSha, '--', '.')
                    if ($rc2 -ne 0) {
                        Write-Host "[relay] WARNING: could not replay uncommitted changes into the snapshot." -ForegroundColor Yellow
                        Write-Host "        The mutation pass will run against HEAD, not the working tree." -ForegroundColor Yellow
                    }
                }
            }

            # --exclude-standard keeps .relay/ and other ignored paths out, which is
            # what we want: the bus must not be duplicated into the snapshot.
            $untracked = @(Get-GitOutput @('-C', $ws, 'ls-files', '--others', '--exclude-standard'))
            foreach ($u in $untracked) {
                if (-not $u) { continue }
                $src = Join-Path $ws $u
                if (-not (Test-Path $src -PathType Leaf)) { continue }
                $dst = Join-Path $dest $u
                New-Item -ItemType Directory -Force (Split-Path -Parent $dst) | Out-Null
                Copy-Item $src $dst -Force -EA 0
            }
        }
    }

    if ($method -eq 'copy') {
        # No repo, no commits, or the worktree failed. Copy the tree instead, minus
        # everything heavy or regenerable.
        New-Item -ItemType Directory -Force $dest | Out-Null
        $xd = @('.git', '.relay', 'node_modules', '.venv', 'venv', '__pycache__', 'dist', 'build', 'target', '.next')
        $args = @($ws, $dest, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1', '/XD') + $xd
        robocopy @args | Out-Null
        if ($LASTEXITCODE -ge 8) { Fail "Snapshot copy failed (robocopy exit $LASTEXITCODE)." }
    }

    # Link the dependency trees rather than copying them. Tests import from these and
    # never write to them, so sharing one copy across snapshots is safe.
    foreach ($dep in 'node_modules', '.venv', 'venv') {
        $srcDep = Join-Path $ws $dep
        $dstDep = Join-Path $dest $dep
        if ((Test-Path $srcDep -PathType Container) -and -not (Test-Path $dstDep)) {
            New-Item -ItemType Junction -Path $dstDep -Target $srcDep -EA 0 | Out-Null
        }
    }

    return @{ path = $dest; method = $method }
}

if ($Command -eq 'snapshot') {
    if (-not $Task) { Fail "-Task <task file or task base name> required" }
    $s = Get-State
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Task)
    $snap = New-MutantSnapshot $s $base
    Say "Snapshot ($($snap.method)) -> $($snap.path)"
    exit 0
}

# ======================================================= AUTOPILOT ===========
# Drive the whole queue unattended: every pending task through execute -> scout ->
# validate, self-healing broken panes as it goes, with the mutation lane running
# alongside instead of in the way.
#
# The orchestrator's remaining job is to write task files and read the run log. It is
# out of the per-cycle loop entirely, which is the point.
#
# Everything here is bounded. An unattended loop with no ceiling is not autonomy, it is
# an unsupervised process burning a workspace: -BudgetMin caps wall clock, -MaxCycles
# caps task cycles, -MaxConsecutiveFails stops work that is not converging, restart
# budgets stop a wedged pane being respawned forever, and `.relay/STOP` lets the user
# halt the run between phases without killing anything.

function Write-RunLog($logPath, $msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    Add-Content -Path $logPath -Value $line -Encoding utf8
    Write-Host "[auto] $msg" -ForegroundColor DarkCyan
}

function Test-StopRequested($state) {
    return (Test-Path (Join-Path $state.workspace '.relay\STOP'))
}

function Get-PendingTasks($state) {
    $tasksDir = Join-Path $state.workspace '.relay\tasks'
    $out = @()
    foreach ($f in @(Get-ChildItem $tasksDir -File -Filter *.md -EA 0 | Sort-Object Name)) {
        if (Test-Path (Get-BusArtifact $state 'reports' $f.BaseName)) { continue }
        $txt = Get-Content $f.FullName -Raw -EA 0
        # Never dispatch the unfilled seed template. It states no requirements, so every
        # artifact it produces is noise - and since it can never earn a report, autopilot
        # would pick it first on every single pass and never advance.
        if ($txt -match '<What "done" means' -or $txt -match '#\s*Task\s+\d+:\s*<title>') { continue }
        $out += $f
    }
    return $out
}

# The validator writes its report and its follow-up task files as separate actions, and
# the report - which is what every wait in this script keys on - can land first. Observed
# 2026-08-13: a mutation sweep report was written at 00:04:51 and the task it dispatched at
# 00:05:05. Autopilot re-scanned the queue one second after the report, saw nothing
# pending, and exited - orphaning a task the relay had just decided was needed.
#
# So never conclude "no follow-up was written" from a scan taken the moment a report
# appears. Give the writer a settle window and re-scan.
function Wait-ForNewTasks($state, $before, $timeoutSec = 45) {
    $tasksDir = Join-Path $state.workspace '.relay\tasks'
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $after = @(Get-ChildItem $tasksDir -File -Filter *.md -EA 0 | ForEach-Object { $_.Name })
        $new = @($after | Where-Object { $before -notcontains $_ })
        if ($new.Count -gt 0) {
            Start-Sleep -Seconds 3   # let the last one finish flushing
            return $new
        }
        Start-Sleep -Seconds 5
    }
    return @()
}

function Get-Verdict($reportPath) {
    if (-not (Test-Path $reportPath)) { return 'MISSING' }
    $head = (Get-Content $reportPath -TotalCount 12 -EA 0) -join "`n"
    # PASS-WITH-CONCERNS must be tested before PASS or it grades as a clean pass.
    if ($head -match 'VERDICT:\s*PASS-WITH-CONCERNS') { return 'PASS-WITH-CONCERNS' }
    if ($head -match 'VERDICT:\s*FAIL')               { return 'FAIL' }
    if ($head -match 'VERDICT:\s*PASS')               { return 'PASS' }
    return 'UNPARSED'
}

# agy panes wedge after long uptime plus a long idle gap. The relay's own history says
# so, and autopilot makes the idle gaps longer - the mutator and scout can both sit for
# a whole executor phase. Two defences, both cheap because agy costs nothing:
#
#   keepalive - make idle agy panes answer during long waits, so their token never sits
#               expired for hours
#   recycle   - restart an agy pane on a timer, before it reaches the age where the
#               wedge has actually been observed
#
# Neither touches the validator: it is the one pane where a probe costs real money.
function Invoke-Keepalive($state, $agentName, $logPath) {
    if ($agentName -eq 'validator') { return }
    if (-not (Get-PaneId $state $agentName)) { return }
    $t = Get-PaneTarget $state $agentName
    # Never interrupt an agent mid-task. The mutator especially is usually working.
    if (Test-PaneBusy $t) { return }
    if (Test-AgentResponsive $t 45) { return }
    Write-RunLog $logPath "keepalive: $agentName did not answer - recycling it now"
    Restart-Agents $state @($agentName) $false | Out-Null
}

function Invoke-Recycle($state, $agentName, $logPath, $maxHours) {
    if ($agentName -eq 'validator') { return }
    if (-not (Get-PaneId $state $agentName)) { return }
    if (-not $state.booted) { return }
    if (-not ($state.booted.PSObject.Properties.Name -contains $agentName)) { return }
    $hrs = ((Get-Date) - [datetime]::Parse($state.booted.$agentName)).TotalHours
    if ($hrs -lt $maxHours) { return }
    if (Test-PaneBusy (Get-PaneTarget $state $agentName)) { return }
    Write-RunLog $logPath "recycling $agentName preemptively (up $([math]::Round($hrs,1))h)"
    $bad = Restart-Agents $state @($agentName) $false
    if ($bad -and $bad.Count -gt 0) { Write-RunLog $logPath "WARNING: $agentName did not come back cleanly" }
}

function Assert-AgentReady($state, $agentName, $logPath) {
    $trouble = Get-AgentTrouble $state $agentName
    if (-not $trouble) { return $true }
    $left = $script:RestartBudget[$agentName]
    if ($left -le 0) {
        Write-RunLog $logPath "$agentName is broken ($trouble) and its restart budget is spent - giving up on that lane"
        return $false
    }
    $script:RestartBudget[$agentName] = $left - 1
    Write-RunLog $logPath "$agentName trouble: $trouble - restarting ($left restart(s) were left)"
    $bad = Restart-Agents $state @($agentName) $false
    if ($bad -and $bad.Count -gt 0) {
        Write-RunLog $logPath "$agentName is STILL unhealthy after a restart"
        return $false
    }
    Write-RunLog $logPath "$agentName restarted and responding"
    return $true
}

# Block until an artifact lands, watching the working agent for faults and keeping the
# other agy panes warm. Returns 'ok', 'stopped', 'timeout', or "fault:<reason>".
function Wait-Artifact($state, $path, $timeoutSec, $agentName, $logPath, $idleAgents) {
    $deadline   = (Get-Date).AddSeconds($timeoutSec)
    $lastTouch  = Get-Date
    $lastHealth = Get-Date
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $path) { Start-Sleep -Milliseconds 900; return 'ok' }

        # A stop takes effect immediately - that is the point of a stop file - but the
        # agent it interrupts does NOT stop. It keeps working and will very likely write
        # its artifact minutes after this run has exited, with nothing watching for it.
        #
        # Observed 2026-08-13: a STOP during a mutation sweep ended the run, after which
        # the validator finished the sweep AND dispatched task 012. Both landed silently
        # and were only found by going to look. The defect was never that stopping is
        # fast; it was that the in-flight work went unrecorded. So record it.
        if (Test-StopRequested $state) {
            $leaf = Split-Path -Leaf $path
            Write-RunLog $logPath "STOP received while waiting on $agentName for $leaf"
            Write-RunLog $logPath "  -> $agentName is STILL WORKING and may write $leaf after this run exits"
            $script:OrphanedWork += "$agentName was mid-task on ``$leaf`` - check whether it landed, and whether it also wrote new task files"
            return 'stopped'
        }

        # Throttled: the process walk is a CIM query, too expensive to run every poll.
        if (((Get-Date) - $lastHealth).TotalSeconds -ge 30) {
            $lastHealth = Get-Date
            $trouble = Get-AgentTrouble $state $agentName
            if ($trouble) { return "fault:$trouble" }
        }

        if (((Get-Date) - $lastTouch).TotalMinutes -ge 12) {
            $lastTouch = Get-Date
            foreach ($ia in $idleAgents) { Invoke-Keepalive $state $ia $logPath }
        }
        Start-Sleep -Seconds 5
    }
    return 'timeout'
}

# One dispatch-and-wait phase, with the retry that used to require a human noticing.
function Invoke-Phase($state, $agentName, $taskPath, $artifactPath, $timeoutSec, $logPath, $idleAgents, $note = '') {
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        if (-not (Assert-AgentReady $state $agentName $logPath)) { return 'agent-down' }

        $d = Invoke-Dispatch $state $agentName $taskPath $note
        if ($d -ne 'ok') {
            Write-RunLog $logPath "$agentName refused dispatch: $d"
            if (-not (Assert-AgentReady $state $agentName $logPath)) { return 'agent-down' }
            continue
        }

        $r = Wait-Artifact $state $artifactPath $timeoutSec $agentName $logPath $idleAgents
        if ($r -eq 'ok')      { return 'ok' }
        if ($r -eq 'stopped') { return 'stopped' }

        Write-RunLog $logPath "$agentName attempt ${attempt}: $r"

        # A timeout on an agent that is visibly still working is not a failure, it is a
        # bad guess at how long the work takes. Extend once rather than restarting the
        # pane and throwing away everything it has done so far.
        if ($r -eq 'timeout' -and (Test-PaneBusy (Get-PaneTarget $state $agentName))) {
            Write-RunLog $logPath "$agentName is still working - extending the wait once"
            $r2 = Wait-Artifact $state $artifactPath $timeoutSec $agentName $logPath $idleAgents
            if ($r2 -eq 'ok')      { return 'ok' }
            if ($r2 -eq 'stopped') { return 'stopped' }
            Write-RunLog $logPath "$agentName after extension: $r2"
        }

        if (-not (Assert-AgentReady $state $agentName $logPath)) { return 'agent-down' }
    }
    return 'failed'
}

# Kick off a mutation pass and return immediately. Nothing downstream waits on this -
# that is the entire design. The snapshot is taken here, at the one moment in the cycle
# when the tree is quiet: the executor has finished and the next task has not started.
function Start-MutationPass($state, $taskPath, $logPath) {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($taskPath)
    if (-not (Assert-AgentReady $state 'mutator' $logPath)) { return $false }
    try { $snap = New-MutantSnapshot $state $base }
    catch {
        Write-RunLog $logPath "snapshot for $base failed: $($_.Exception.Message) - skipping mutation for this task"
        return $false
    }
    Write-RunLog $logPath "snapshot for $base ready ($($snap.method)) - mutation pass starts in the background"
    $d = Invoke-Dispatch $state 'mutator' $taskPath
    if ($d -ne 'ok') { Write-RunLog $logPath "mutator refused dispatch: $d"; return $false }
    return $true
}

if ($Command -eq 'autopilot') {
    $s = Get-State
    $live = psmux ls 2>$null | Out-String
    if (-not ($live -match "(?m)^$([regex]::Escape($s.session)):")) {
        Fail "Relay is not running. Bring it up first: relay.ps1 up -Workspace <path>"
    }

    $ws     = $s.workspace
    $logDir = Join-Path $ws '.relay\logs'
    New-Item -ItemType Directory -Force $logDir | Out-Null
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $log    = Join-Path $logDir "autopilot-$stamp.md"
    Set-Content $log "# Autopilot run $stamp`r`nworkspace: $ws`r`n" -Encoding utf8

    # A stale STOP from a previous run would end this one before it started.
    $stopFile = Join-Path $ws '.relay\STOP'
    if (Test-Path $stopFile) { Remove-Item $stopFile -Force; Write-RunLog $log "cleared a stale .relay/STOP" }

    $script:RestartBudget = @{ executor = 4; scout = 4; mutator = 3; validator = 2 }
    $script:OrphanedWork  = @()

    $mutationOn = (-not $NoMutation) -and [bool](Get-PaneId $s 'mutator')
    if ($NoMutation)        { Write-RunLog $log "mutation lane disabled by -NoMutation" }
    elseif (-not $mutationOn) { Write-RunLog $log "mutation lane unavailable - this relay has no mutator pane (down/up to add it)" }

    # Which mutation reports have already been folded into a verdict. Persisted so a
    # second autopilot run does not re-sweep findings the first one already handled.
    $seenFile = Join-Path $logDir 'mutation-seen.json'
    $seen = @{}
    if (Test-Path $seenFile) {
        foreach ($k in @((Get-Content $seenFile -Raw | ConvertFrom-Json))) { if ($k) { $seen["$k"] = $true } }
    }
    function Save-Seen($path, $tbl) { @($tbl.Keys) | ConvertTo-Json -Depth 2 | Set-Content $path -Encoding utf8 }

    $deadline    = (Get-Date).AddMinutes($BudgetMin)
    $cycles      = 0
    $consecFails = 0
    $stopReason  = 'queue drained'
    $summary     = @()
    $sweepDone   = $false

    Write-RunLog $log "autopilot start - budget ${BudgetMin}m, max ${MaxCycles} cycles, mutation=$mutationOn"

    while ($true) {
        if (Test-StopRequested $s)      { $stopReason = 'stopped by .relay/STOP'; break }
        if ((Get-Date) -ge $deadline)   { $stopReason = "wall-clock budget of ${BudgetMin}m exhausted"; break }
        if ($cycles -ge $MaxCycles)     { $stopReason = "cycle cap of $MaxCycles reached"; break }

        $pending = @(Get-PendingTasks $s)

        if ($pending.Count -eq 0) {
            # Queue is empty. Before declaring the run finished, give the mutation lane a
            # chance to land what it is still chewing on, then let the validator decide
            # whether any of it deserves a follow-up task. If it writes one, the loop
            # picks it up on the next pass and the run continues.
            if (-not $mutationOn -or $sweepDone) { break }
            $sweepDone = $true

            $outstanding = @()
            foreach ($m in @(Get-ChildItem (Join-Path $ws '.relay\mutation') -File -Filter *.md -EA 0)) {
                if (-not $seen.ContainsKey($m.BaseName)) { $outstanding += $m }
            }
            $inFlight = Test-PaneBusy (Get-PaneTarget $s 'mutator')
            if ($outstanding.Count -eq 0 -and -not $inFlight) { break }

            if ($inFlight) {
                Write-RunLog $log "queue drained; mutator still working - draining for up to ${MutationDrainMin}m"
                $drainEnd = (Get-Date).AddMinutes($MutationDrainMin)
                while ((Get-Date) -lt $drainEnd -and (Test-PaneBusy (Get-PaneTarget $s 'mutator'))) {
                    if (Test-StopRequested $s) { break }
                    Start-Sleep -Seconds 15
                }
                $outstanding = @()
                foreach ($m in @(Get-ChildItem (Join-Path $ws '.relay\mutation') -File -Filter *.md -EA 0)) {
                    if (-not $seen.ContainsKey($m.BaseName)) { $outstanding += $m }
                }
            }
            if ($outstanding.Count -eq 0) { break }

            Write-RunLog $log "mutation sweep over $($outstanding.Count) unreviewed report(s)"
            if (-not (Assert-AgentReady $s 'validator' $log)) { $stopReason = 'validator unavailable for the mutation sweep'; break }

            $sweepName = "mutation-sweep-$stamp"
            $sweepPath = Join-Path $ws ".relay\reports\$sweepName.md"
            $list = ($outstanding | ForEach-Object { ".relay/mutation/$($_.Name)" }) -join ' , '
            $nextId = '{0:D3}' -f (1 + [int](@(Get-ChildItem (Join-Path $ws '.relay\tasks') -File -Filter *.md -EA 0 |
                        ForEach-Object { if ($_.BaseName -match '^(\d+)') { [int]$Matches[1] } else { 0 } } |
                        Measure-Object -Maximum).Maximum))
            $msg = "Mutation sweep. These mutation reports have not been folded into any verdict yet: $list . Read each one. For every surviving mutant, decide whether it is a real gap in the tests or noise. Write a short summary to .relay/reports/$sweepName.md , first line VERDICT: PASS or VERDICT: FAIL - PASS if nothing is worth acting on. For each real gap that IS worth closing, also write a new task file to .relay/tasks/ using the standard task format (Objective, Scope, Requirements, Verification, Artifacts), starting at id $nextId and incrementing. Write no task files if nothing warrants one."
            Send-Line (Get-PaneTarget $s 'validator') $msg

            $tasksBeforeSweep = @(Get-ChildItem (Join-Path $ws '.relay\tasks') -File -Filter *.md -EA 0 | ForEach-Object { $_.Name })
            $r = Wait-Artifact $s $sweepPath 1800 'validator' $log @('scout', 'executor')
            Write-RunLog $log "mutation sweep: $r"
            foreach ($m in $outstanding) { $seen[$m.BaseName] = $true }
            Save-Seen $seenFile $seen
            $summary += "| mutation sweep | - | $r |"

            # The sweep dispatches its own follow-up tasks, and they land after the report.
            # Without this wait the loop re-scans too early, finds nothing, and exits -
            # throwing away the work the sweep just decided was needed.
            if ($r -eq 'ok') {
                $newFromSweep = Wait-ForNewTasks $s $tasksBeforeSweep 45
                if ($newFromSweep.Count -gt 0) {
                    Write-RunLog $log "sweep dispatched: $($newFromSweep -join ', ')"
                }
                else { Write-RunLog $log "sweep dispatched no follow-up tasks" }
            }
            continue
        }

        # --- one full cycle ---------------------------------------------------
        $taskFile = $pending[0]
        $base     = $taskFile.BaseName
        $cycles++
        Write-RunLog $log "=== cycle $cycles : $base ==="

        # Recycle before the cycle rather than during it: this is the one moment when no
        # agent is mid-task, so a restart costs nothing but the boot time.
        foreach ($a in 'executor', 'scout', 'mutator') { Invoke-Recycle $s $a $log 3 }

        $resultPath   = Get-BusArtifact $s 'results'  $base
        $evidencePath = Get-BusArtifact $s 'evidence' $base
        $reportPath   = Get-BusArtifact $s 'reports'  $base
        $mutationPath = Get-BusArtifact $s 'mutation' $base

        # Phases whose artifact is already on the bus are skipped, which makes a run
        # resumable: a cycle interrupted by STOP, a budget ceiling or a crash picks up
        # where it stopped instead of re-running work that is already done.
        #
        # This is not just an optimisation. Without it the executor is dispatched, the
        # stale result file is seen instantly, and the cycle sails on to scout a result
        # that was never regenerated - looking exactly like a fast success. Two tasks on
        # this bus were in precisely that state (result and evidence present, no verdict)
        # when autopilot was written.

        # 1. execute
        if (Test-Path $resultPath) {
            Write-RunLog $log "$base already has a result - skipping the executor (resuming)"
        }
        else {
            $r = Invoke-Phase $s 'executor' $taskFile.FullName $resultPath 1800 $log @('scout', 'mutator')
            if ($r -eq 'stopped') { $stopReason = 'stopped by .relay/STOP'; break }
            if ($r -ne 'ok') {
                Write-RunLog $log "executor did not produce a result for $base ($r) - stopping"
                $summary += "| $base | executor $r | run halted |"
                $stopReason = "executor could not complete $base"
                break
            }
        }

        # 2. mutation lane starts here and is never waited on
        if ($mutationOn -and -not (Test-Path $mutationPath)) {
            Start-MutationPass $s $taskFile.FullName $log | Out-Null
        }

        # 3. scout evidence - the step that must not be skipped silently
        $note = ''
        if (Test-Path $evidencePath) {
            Write-RunLog $log "$base already has scout evidence - skipping the scout (resuming)"
        }
        else {
            $r = Invoke-Phase $s 'scout' $taskFile.FullName $evidencePath 1200 $log @('mutator')
            if ($r -eq 'stopped') { $stopReason = 'stopped by .relay/STOP'; break }
            if ($r -ne 'ok') {
                Write-RunLog $log "NO SCOUT EVIDENCE for $base ($r) - validating degraded"
                $note = "There is NO scout evidence for this task - the scout failed twice. Grade it degraded per your contract: PASS-WITH-CONCERNS at best, never a clean PASS, and mark every requirement you establish yourself as self-verified."
            }
        }

        # 4. validate. Fold in the mutation report if it happened to land in time; if it
        #    did not, it is swept at the end of the run instead of holding this up.
        if (Test-Path $mutationPath) {
            $seen[$base] = $true
            Save-Seen $seenFile $seen
            Write-RunLog $log "mutation report for $base landed in time - the validator will read it"
        }
        $tasksBefore = @(Get-ChildItem (Join-Path $ws '.relay\tasks') -File -Filter *.md -EA 0 | ForEach-Object { $_.Name })

        $r = Invoke-Phase $s 'validator' $taskFile.FullName $reportPath 1800 $log @('scout', 'mutator', 'executor') $note
        if ($r -eq 'stopped') { $stopReason = 'stopped by .relay/STOP'; break }
        if ($r -ne 'ok') {
            Write-RunLog $log "validator produced no report for $base ($r) - stopping"
            $summary += "| $base | validator $r | run halted |"
            $stopReason = "validator could not grade $base"
            break
        }

        $verdict = Get-Verdict $reportPath
        Write-RunLog $log "VERDICT $base : $verdict"
        $summary += "| $base | $verdict | |"

        if ($verdict -eq 'FAIL') {
            $consecFails++
            if ($consecFails -ge $MaxConsecutiveFails) {
                $stopReason = "$consecFails consecutive FAIL verdicts - the work is not converging"
                break
            }
            # The validator writes its own follow-up task. If it did not, there is
            # nothing for the next cycle to pick up and looping would spin forever.
            # It writes the task AFTER the report, so this has to wait rather than scan
            # once - scanning once turns a slow write into a false "no follow-up".
            $new = Wait-ForNewTasks $s $tasksBefore 45
            if ($new.Count -eq 0) {
                $stopReason = "$base FAILED and the validator wrote no follow-up task - a human needs to decide the next move"
                break
            }
            Write-RunLog $log "follow-up queued: $($new -join ', ')"
        }
        else { $consecFails = 0 }

        # New tasks may have arrived, so re-sweep mutation at the end of the new queue.
        $sweepDone = $false
    }

    # --- run summary ----------------------------------------------------------
    $elapsed = [math]::Round(((Get-Date) - [datetime]::ParseExact($stamp, 'yyyyMMdd-HHmmss', $null)).TotalMinutes, 1)
    Add-Content $log "`r`n## Summary`r`n" -Encoding utf8
    Add-Content $log "stopped because: $stopReason" -Encoding utf8
    Add-Content $log "cycles: $cycles   elapsed: ${elapsed}m" -Encoding utf8
    Add-Content $log "`r`n| Task | Verdict | Note |`r`n|---|---|---|" -Encoding utf8
    foreach ($row in $summary) { Add-Content $log $row -Encoding utf8 }

    # Anything an interrupted agent may still be writing. This section exists so the work
    # is findable; without it the artifacts land after the run and nobody knows to look.
    if ($script:OrphanedWork.Count -gt 0) {
        Add-Content $log "`r`n## Work left in flight`r`n" -Encoding utf8
        foreach ($o in $script:OrphanedWork) { Add-Content $log "- $o" -Encoding utf8 }
        Add-Content $log "`r`nRe-run ``status`` in a few minutes: late artifacts are real output, and a validator interrupted mid-sweep can still dispatch tasks that nothing is watching for." -Encoding utf8
    }

    Copy-Item $log (Join-Path $logDir 'autopilot-latest.md') -Force

    Write-Host ""
    Write-Host "[relay] AUTOPILOT FINISHED - $stopReason" -ForegroundColor Green
    Write-Host "        cycles=$cycles  elapsed=${elapsed}m" -ForegroundColor Gray
    foreach ($row in $summary) { Write-Host "        $row" -ForegroundColor Gray }
    if ($script:OrphanedWork.Count -gt 0) {
        Write-Host ""
        Write-Host "[relay] WORK LEFT IN FLIGHT - an interrupted agent kept working:" -ForegroundColor Yellow
        foreach ($o in $script:OrphanedWork) { Write-Host "        $o" -ForegroundColor Yellow }
        Write-Host "        Check the bus again shortly - these artifacts land after this run exits." -ForegroundColor Yellow
    }
    Write-Host "        Run log: $log" -ForegroundColor Gray

    # Exit code carries the shape of the outcome so a caller can route without parsing.
    #   0 = queue drained cleanly   2 = stopped early, needs a human
    if ($stopReason -eq 'queue drained') { exit 0 }
    exit 2
}
