# One-time prerequisites for plan-and-verify on Windows: Git for Windows (Git Bash), jq,
# and CLAUDE_CODE_GIT_BASH_PATH so Claude Code runs the plugin's hooks through Git Bash.
$ErrorActionPreference = "Stop"
function Find-GitBash {
  $c = @("$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe", "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe")
  foreach ($p in $c) { if (Test-Path $p) { return $p } }
  $g = Get-Command git -ErrorAction SilentlyContinue
  if ($g) { $p = Join-Path (Split-Path (Split-Path $g.Source)) "bin\bash.exe"; if (Test-Path $p) { return $p } }
  return $null
}
$bash = Find-GitBash
if (-not $bash) { Write-Host "Installing Git for Windows..."; winget install --id Git.Git -e --accept-source-agreements --accept-package-agreements; $bash = Find-GitBash }
if (-not $bash) { Write-Error "Git Bash still not found; install Git for Windows from https://git-scm.com/download/win and re-run." }
if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
  Write-Host "Installing jq..."; winget install --id jqlang.jq -e --accept-source-agreements --accept-package-agreements
  $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
  if (-not (Get-Command jq -ErrorAction SilentlyContinue)) { Write-Error "jq not on PATH yet; open a new terminal and re-run." }
}
[Environment]::SetEnvironmentVariable("CLAUDE_CODE_GIT_BASH_PATH", $bash, "User"); $env:CLAUDE_CODE_GIT_BASH_PATH = $bash
Write-Host "prerequisites ok. CLAUDE_CODE_GIT_BASH_PATH = $bash"
Write-Host "Restart Claude Code, then: claude plugin marketplace add <you>/claude-plugins  &&  claude plugin install plan-and-verify@<you>"
