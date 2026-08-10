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
    [ValidateSet('new', 'up', 'down', 'status', 'send', 'dispatch', 'capture', 'wait', 'attach', 'bus')]
    [string]$Command = 'status',

    # Positional so 'relay new my-app' reads the way you would say it.
    [Parameter(Position = 1)]
    [string]$Name,

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
    # 'probe' is the scout's sanctioned scratch area. It writes throwaway edge-case
    # tests there rather than into the project's own test tree, so probing never
    # pollutes the diff the scout is simultaneously reporting on.
    foreach ($d in 'tasks', 'results', 'evidence', 'reports', 'logs', 'probe') {
        New-Item -ItemType Directory -Force (Join-Path $ws ".relay\$d") | Out-Null
    }
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
        'every one of these itself rather than trusting the executor.>'
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
    Say "  executor  (agy / $agyModel) -> $($ids['0'])"
    Say "  validator (claude opus)                  -> $($ids['1'])"
    Say "  scout     (agy / $agyModel) -> $($ids['2'])"
    Say "  bus watch                                -> $($ids['3'])"
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
        $msg = "Gather evidence for: $rel . Follow your contract in .relay/scout.md - re-run the verification yourself, probe the edge cases the task implies, audit the tests for real assertions, and write the compacted evidence file named in the task. Observations only, no verdict."
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
