# ---------------------------------------------------------------------------
# tests/ps1_trust_prompt_test.ps1 - relay.ps1 folder-trust handling, on real psmux
# ---------------------------------------------------------------------------
# Draws a stand-in for Claude Code's folder-trust menu (trust_prompt_menu.ps1) in a
# throwaway psmux session, then runs relay.ps1's own Clear-BlockingPrompts against it.
# The functions are lifted out of relay.ps1 by AST so the script itself is not run.
# Windows only: needs psmux on PATH. Exit code is the number of failed cases.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\ps1_trust_prompt_test.ps1
param(
    [string]$Relay = (Join-Path $PSScriptRoot '..\relay\relay.ps1'),
    [string]$Session = 'trusttest'
)
$menu = Join-Path $PSScriptRoot 'trust_prompt_menu.ps1'
$dir  = Join-Path ([IO.Path]::GetTempPath()) ("relay-trust-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null

$ast  = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $Relay).ProviderPath, [ref]$null, [ref]$null)
$want = 'Invoke-PsmuxCapture', 'Get-PaneText', 'Test-PaneMatch', 'Invoke-AcceptTrustPrompt', 'Clear-BlockingPrompts'
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $want -contains $n.Name }, $true)) {
    . ([scriptblock]::Create($f.Extent.Text))
}
$vars = '$script:ClearablePrompts', '$script:MenuCursorPattern', '$script:RepaintSettleMs'
foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $vars -contains $n.Left.Extent.Text }, $false)) {
    . ([scriptblock]::Create($a.Extent.Text))
}
$missing = @($want | Where-Object { -not (Get-Command $_ -CommandType Function -ErrorAction SilentlyContinue) })
if ($missing.Count -or -not $script:MenuCursorPattern) {
    "could not load from ${Relay}: $($missing -join ', ')"
    exit 99
}
$script:RepaintSettleMs = 300

$cases = @(
    @{ Name = 'cursor on No (2.1.296 layout)';   Args = '-Start 0';           Expect = '2. Yes, I trust this folder' },
    @{ Name = 'cursor already on Yes';           Args = '-Start 1';           Expect = '2. Yes, I trust this folder' },
    @{ Name = 'no cursor glyph: Enter fallback'; Args = '-Start 0 -NoGlyph'; Expect = '1. No, exit' }
)
$fail = 0
try {
    foreach ($c in $cases) {
        $out = Join-Path $dir 'choice.txt'
        Remove-Item $out -ErrorAction SilentlyContinue
        psmux kill-session -t $Session 2>$null | Out-Null
        psmux new-session -d -s $Session -x 120 -y 30 "powershell -NoProfile -ExecutionPolicy Bypass -File `"$menu`" -Out `"$out`" $($c.Args)" | Out-Null
        Start-Sleep -Seconds 3
        $cleared = Clear-BlockingPrompts $Session
        Start-Sleep -Seconds 1
        $got = if (Test-Path $out) { (Get-Content $out -Raw).Trim() } else { '<no choice>' }
        $ok = $got -eq $c.Expect
        if (-not $ok) { $fail++ }
        '{0,-34} cleared={1,-20} chose={2,-30} {3}' -f $c.Name, $cleared, $got, $(if ($ok) { 'PASS' } else { 'FAIL' })
    }
}
finally {
    psmux kill-session -t $Session 2>$null | Out-Null
    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
}
"failures: $fail"
exit $fail
