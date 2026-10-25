# Stand-in for Claude Code's folder-trust menu, used by ps1_trust_prompt_test.ps1.
# Down moves the cursor (wrapping), Enter writes the chosen item to -Out and exits.
param([string]$Out, [int]$Start = 0, [switch]$NoGlyph)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$items = @('1. No, exit', '2. Yes, I trust this folder')
$sel = $Start
function Draw {
    Clear-Host
    Write-Host 'Do you trust the files in this folder?'
    Write-Host 'Claude Code may read files here. Only trust this folder if you wrote it.'
    Write-Host ''
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ($NoGlyph) { $c = '  ' } elseif ($i -eq $sel) { $c = [string][char]0x276F + ' ' } else { $c = '  ' }
        Write-Host ($c + $items[$i])
    }
}
Draw
while ($true) {
    $k = [Console]::ReadKey($true)
    if ($k.Key -eq 'DownArrow') { $sel = ($sel + 1) % $items.Count; Draw }
    elseif ($k.Key -eq 'Enter') { Set-Content -Path $Out -Value $items[$sel]; exit }
}
