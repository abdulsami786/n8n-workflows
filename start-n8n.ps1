# Starts the local (non-Docker) n8n with the LeadOps settings from .env.
# N8N_ENCRYPTION_KEY is skipped: this n8n keeps its own key in ~/.n8n/config.
# -EnvOnly loads the settings into the current session without starting n8n (used by setup-local.ps1).
param([switch]$EnvOnly)
Get-Content "$PSScriptRoot\.env" | ForEach-Object {
  if ($_ -match '^\s*([A-Z0-9_]+)=(.*)$' -and $matches[1] -ne 'N8N_ENCRYPTION_KEY') {
    [Environment]::SetEnvironmentVariable($matches[1], ($matches[2] -replace '\s+#.*$', '').Trim().Trim('"'))
  }
}
$env:N8N_BLOCK_ENV_ACCESS_IN_NODE = 'false'   # workflows read their config from .env
$env:GENERIC_TIMEZONE = $env:TIMEZONE          # schedules (07:30 digest) run on school time, not n8n's New York default
if ($EnvOnly) { return }
Set-Location $HOME   # n8n auto-loads .env from the cwd, which would bring the key back
n8n
