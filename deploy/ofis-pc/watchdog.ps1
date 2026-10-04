# Runs every 5 minutes (task "postiz-watchdog", created by install.ps1).
# 1) Postiz down -> start Docker Desktop if needed, docker compose up -d, alert on Telegram once
# 2) Tailscale Funnel missing -> turn it back on
# 3) once a day -> pg_dump of the Postiz database into backups\, keep the last 14
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Port = 4007
$log = Join-Path $Dir 'watchdog.log'
$downFlag = Join-Path $Dir '.watchdog-down'
$tailscale = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
$dockerDesktop = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'

function Log($text) { Add-Content -Path $log -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $text" }
function EnvValue($key) {
  $line = Get-Content (Join-Path $Dir '.env') | Where-Object { $_ -match "^$key=" } | Select-Object -First 1
  if ($line) { $line.Substring($key.Length + 1).Trim() }
}
function Alert($text) {
  $token = EnvValue 'TELEGRAM_TOKEN'
  $chat = EnvValue 'ALERT_CHAT_ID'
  if (-not $token -or -not $chat) { return }
  try { Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$token/sendMessage" -Body @{ chat_id = $chat; text = $text } | Out-Null } catch { Log "alert failed: $_" }
}
function Healthy {
  try { (Invoke-WebRequest -UseBasicParsing -TimeoutSec 20 "http://127.0.0.1:$Port").StatusCode -lt 500 } catch { $false }
}

if (Healthy) {
  if (Test-Path $downFlag) {
    Remove-Item $downFlag
    Log 'recovered'
    Alert 'Postiz (ofis-pc) ponovo radi.'
  }
} else {
  Log 'postiz not responding'
  docker info 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0 -and (Test-Path $dockerDesktop)) {
    Log 'starting Docker Desktop'
    Start-Process $dockerDesktop
    Start-Sleep 90
  }
  Push-Location $Dir
  docker compose up -d 2>&1 | ForEach-Object { Log "compose: $_" }
  Pop-Location
  Start-Sleep 60
  if (-not (Healthy) -and -not (Test-Path $downFlag)) {
    New-Item -ItemType File -Path $downFlag | Out-Null
    Alert 'Postiz (ofis-pc) ne radi ni posle restarta. Zakazane objave ne izlaze dok se ne podigne.'
  }
}

if (Test-Path $tailscale) {
  $funnel = (& $tailscale funnel status 2>&1) -join "`n"
  if (-not ($funnel -match 'Funnel on' -and $funnel -match "127.0.0.1:$Port")) {
    Log 'funnel missing -> enabling'
    & $tailscale funnel --bg $Port 2>&1 | ForEach-Object { Log "funnel: $_" }
  }
}

$backups = Join-Path $Dir 'backups'
$today = Join-Path $backups ("postiz-{0}.sql" -f (Get-Date -Format 'yyyyMMdd'))
if (-not (Test-Path $today) -and (Healthy)) {
  New-Item -ItemType Directory -Force -Path $backups | Out-Null
  docker exec postiz-postgres pg_dump -U postiz-user -d postiz-db --clean --if-exists -f /tmp/postiz-backup.sql 2>&1 | Out-Null
  if ($LASTEXITCODE -eq 0) {
    docker cp postiz-postgres:/tmp/postiz-backup.sql $today 2>&1 | Out-Null
    Log "backup $today"
  } else {
    Log 'backup failed'
  }
  Get-ChildItem $backups -Filter 'postiz-*.sql' | Sort-Object Name -Descending | Select-Object -Skip 14 | Remove-Item
}
