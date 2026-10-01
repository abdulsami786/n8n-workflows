# One-time LeadOps setup on Windows without Docker: .env, database, n8n credentials and workflows, then starts n8n.
# Needs PostgreSQL 17 and n8n 2.41.3 (npm install -g n8n@2.41.3). Safe to run again.
# Run:  powershell -ExecutionPolicy Bypass -File setup-local.ps1        (-NoDemo skips the 95-day demo history)
param([switch]$NoDemo)
$root = $PSScriptRoot
function Ok($what) { if ($LASTEXITCODE) { throw "$what failed (exit code $LASTEXITCODE)" } }
# n8n's exit code is unreliable on Windows (Node can crash while exiting after the work succeeded), so check its output instead
function Invoke-N8n([string]$expect, [string[]]$cmd) {
  $out = (& n8n @cmd 2>&1 | ForEach-Object { "$_" }) -join "`n"
  if ($out -notmatch [regex]::Escape($expect)) { Write-Host $out; throw "n8n $($cmd -join ' ') failed" }
}

$psql = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -Last 1 -ExpandProperty FullName
if (-not $psql) { throw 'PostgreSQL not found. Install PostgreSQL 17 from https://www.postgresql.org/download/windows/ first.' }
if (-not (Get-Command n8n -ErrorAction SilentlyContinue)) { throw 'n8n not found. Install it with: npm install -g n8n@2.41.3' }

Write-Host '1/6 Settings (.env)'
if (-not (Test-Path "$root\.env")) {
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  $lines = Get-Content "$root\.env.local.example" | ForEach-Object {
    [regex]::Replace($_, 'change-me', { $b = New-Object byte[] 16; $rng.GetBytes($b); -join ($b | ForEach-Object { $_.ToString('x2') }) })
  }
  [IO.File]::WriteAllText("$root\.env", ($lines -join "`n") + "`n")   # UTF-8 without BOM, LF: bash (tests) reads it too
  Write-Host '    created .env with random passwords'
}
. "$root\start-n8n.ps1" -EnvOnly
$env:PGCLIENTENCODING = 'UTF8'
$user = $env:POSTGRES_USER

Write-Host '2/6 Database user and database'
$env:PGPASSWORD = $env:POSTGRES_PASSWORD
& $psql -h 127.0.0.1 -U $user -d leadops -tAc 'SELECT 1' 2>&1 | Out-Null
if ($LASTEXITCODE) {
  $env:PGPASSWORD = $env:PG_SUPERUSER_PASSWORD
  if (-not $env:PGPASSWORD) {
    $s = Read-Host 'Password of the "postgres" user (chosen when PostgreSQL was installed)' -AsSecureString
    $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
  }
  $su = @('-h', '127.0.0.1', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-tAc')
  $hasRole = & $psql @su "SELECT 1 FROM pg_roles WHERE rolname = '$user'"; Ok 'Connecting as postgres (wrong password?)'
  if ($hasRole) { & $psql @su "ALTER ROLE $user LOGIN PASSWORD '$($env:POSTGRES_PASSWORD)'" | Out-Null }
  else { & $psql @su "CREATE ROLE $user LOGIN PASSWORD '$($env:POSTGRES_PASSWORD)'" | Out-Null }
  Ok 'Creating the database user'
  if (-not (& $psql @su "SELECT 1 FROM pg_database WHERE datname = 'leadops'")) {
    & $psql @su "CREATE DATABASE leadops OWNER $user ENCODING 'UTF8' TEMPLATE template0" | Out-Null; Ok 'Creating the database'
  }
  $env:PGPASSWORD = $env:POSTGRES_PASSWORD
}

Write-Host '3/6 Tables, settings and team'
$db = @('-h', '127.0.0.1', '-U', $user, '-d', 'leadops', '-v', 'ON_ERROR_STOP=1', '-q')
& $psql @db -f "$root\sql\01_schema.sql"; Ok 'Loading sql/01_schema.sql'
& $psql @db -v "tz=$($env:TIMEZONE)" -v "school=$($env:SCHOOL_NAME)" -f "$root\sql\02_seed.sql"; Ok 'Loading sql/02_seed.sql'
if (-not $NoDemo) { & $psql @db -f "$root\sql\03_demo_data.sql"; Ok 'Loading sql/03_demo_data.sql' }   # skips itself if already loaded
if ($env:TELEGRAM_API_BASE -match 'mock-telegram') {   # mock mode: placeholder chat ids so notifications "send"
  & $psql @db -c 'UPDATE leadops.agents SET telegram_chat_id = (100000000 + id)::text WHERE telegram_chat_id IS NULL'; Ok 'Setting mock chat ids'
}

Write-Host '4/6 Stopping n8n if it is running'
$c = Get-NetTCPConnection -LocalPort 5678 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($c) { Stop-Process -Id $c.OwningProcess -Force; Start-Sleep 3 }

Write-Host '5/6 Importing credentials and workflows'
Push-Location $HOME   # never run n8n from this folder: it would load N8N_ENCRYPTION_KEY from .env
try {
  $env:LEADOPS_DB_HOST = '127.0.0.1'
  $tmp = Join-Path $env:TEMP 'leadops-credentials.json'
  $json = & node "$root\n8n\render-credentials.js"; Ok 'Rendering credentials'
  [IO.File]::WriteAllText($tmp, ($json -join "`n"))
  try { Invoke-N8n 'Successfully imported' @('import:credentials', "--input=$tmp") } finally { Remove-Item $tmp }
  Invoke-N8n 'Successfully imported' @('import:workflow', '--separate', "--input=$root\n8n\workflows")
  Invoke-N8n 'Successfully imported' @('import:workflow', '--separate', "--input=$root\n8n\mocks")
  foreach ($id in 'lo10Alerts000000', 'lo05Notify000000', 'lo04CrmSync00000', 'lo03Processor000', 'lo01MetaIntake00', 'lo02WebIntake000',
                  'lo06SlaWatchdog0', 'lo07LeadActions0', 'lo08Dashboard000', 'lo09RetrySweep00', 'lo11DailyDigest0', 'lo90MockApis0000', 'lo91DemoLeads000') {
    Invoke-N8n 'Please restart n8n' @('publish:workflow', "--id=$id")
  }
} finally { Pop-Location }

Write-Host '6/6 Starting n8n (first start can take a few minutes)'
Start-Process powershell -WindowStyle Minimized -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$root\start-n8n.ps1`""
$check = "http://localhost:5678/webhook/leadops/meta?hub.mode=subscribe&hub.verify_token=$($env:META_VERIFY_TOKEN)&hub.challenge=ready"
$sw = [Diagnostics.Stopwatch]::StartNew()
while ((curl.exe -s -m 5 $check) -ne 'ready') {
  if ($sw.Elapsed.TotalMinutes -gt 8) { throw 'n8n did not answer within 8 minutes. Look at the minimized n8n window for errors.' }
  Start-Sleep 5
}
Write-Host @"

Done in $([int]$sw.Elapsed.TotalSeconds)s. n8n is running in a minimized window (keep it open).
  Editor:      http://localhost:5678
  Demo leads:  http://localhost:5678/webhook/leadops/demo-leads?count=5
  Dashboard:   http://localhost:5678/webhook/leadops/dashboard   (user: $($env:DASHBOARD_USER), password: DASHBOARD_PASSWORD in .env)
After a PC restart, start n8n with start-n8n.ps1 (see README), not with plain "n8n".
"@
