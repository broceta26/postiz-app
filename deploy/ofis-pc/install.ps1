# Postiz na ofis-pc: instalacija i ažuriranje. Bezbedno je pokretati više puta.
# Pokretanje (PowerShell):
#   irm https://raw.githubusercontent.com/broceta26/postiz-app/main/deploy/ofis-pc/install.ps1 -OutFile $env:TEMP\postiz-install.ps1
#   powershell -ExecutionPolicy Bypass -File $env:TEMP\postiz-install.ps1
# Posle prve instalacije: powershell -ExecutionPolicy Bypass -File C:\postiz\install.ps1
param(
  [string]$Dir = 'C:\postiz',
  [string]$Branch = 'main',
  [int]$Port = 4007
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repo = "https://raw.githubusercontent.com/broceta26/postiz-app/$Branch"
$tailscale = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
$dockerDesktop = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Ok($text) { Write-Host "   OK  $text" -ForegroundColor Green }
function YourTurn($text) {
  Write-Host "`n>>> TVOJ KORAK: $text" -ForegroundColor Yellow
  Write-Host ">>> Kad završiš, pokreni ponovo: powershell -ExecutionPolicy Bypass -File $Dir\install.ps1 -Branch $Branch" -ForegroundColor Yellow
  exit 2
}
function NewSecret([int]$bytes) {
  $buffer = New-Object byte[] $bytes
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buffer)
  -join ($buffer | ForEach-Object { $_.ToString('x2') })
}
function WriteUtf8($path, $text) {
  # .env must be UTF-8 without BOM or Docker reads the first key wrong
  [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $false))
}
function SetEnvValue([string]$text, [string]$key, [string]$value) {
  $pattern = "(?m)^$([regex]::Escape($key))=.*$"
  if ($text -match $pattern) { return [regex]::Replace($text, $pattern, "$key=$value") }
  return $text.TrimEnd() + "`n$key=$value`n"
}
function Native([scriptblock]$command) {
  # Windows PowerShell 5.1 turns redirected stderr into terminating errors under 'Stop'
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $command *> $null } finally { $ErrorActionPreference = $previous }
  return ($LASTEXITCODE -eq 0)
}
function TestPostiz {
  try { (Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 "http://127.0.0.1:$Port").StatusCode -lt 500 } catch { $false }
}

Step 'Fajlovi'
New-Item -ItemType Directory -Force -Path $Dir, (Join-Path $Dir 'dynamicconfig'), (Join-Path $Dir 'backups') | Out-Null
$files = @{
  'deploy/ofis-pc/docker-compose.yaml'  = 'docker-compose.yaml'
  'deploy/ofis-pc/.env.example'         = '.env.example'
  'deploy/ofis-pc/watchdog.ps1'         = 'watchdog.ps1'
  'deploy/ofis-pc/install.ps1'          = 'install.ps1'
  'dynamicconfig/development-sql.yaml'  = 'dynamicconfig\development-sql.yaml'
}
foreach ($source in $files.Keys) {
  Invoke-RestMethod -Uri "$repo/$source" -OutFile (Join-Path $Dir $files[$source])
}
Ok "preuzeto u $Dir (grana $Branch)"

$ramGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
if ($ramGb -lt 8) { Write-Host "   PAZI  računar ima $ramGb GB RAM-a; Postiz traži oko 4 GB" -ForegroundColor Yellow } else { Ok "$ramGb GB RAM-a" }

# A 24/7 server must never fall asleep on AC power
powercfg /change standby-timeout-ac 0 | Out-Null
powercfg /change hibernate-timeout-ac 0 | Out-Null
Ok 'spavanje računara isključeno (na struji)'

Step 'Docker'
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { YourTurn 'Instaliraj Docker Desktop sa https://www.docker.com/products/docker-desktop/ i restartuj računar.' }
  winget install -e --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements
  YourTurn 'Docker Desktop je instaliran. Restartuj računar, otvori Docker Desktop i prihvati uslove korišćenja.'
}
$dockerReady = Native { docker info }
if (-not $dockerReady -and (Test-Path $dockerDesktop)) {
  Start-Process $dockerDesktop
  for ($i = 0; $i -lt 24 -and -not $dockerReady; $i++) { Start-Sleep 5; $dockerReady = Native { docker info } }
}
if (-not $dockerReady) { YourTurn 'Otvori Docker Desktop, prihvati uslove i sačekaj da piše "Engine running".' }
foreach ($settings in @("$env:APPDATA\Docker\settings-store.json", "$env:APPDATA\Docker\settings.json")) {
  if (Test-Path $settings) {
    try {
      $json = Get-Content $settings -Raw | ConvertFrom-Json
      $key = if ($settings -like '*settings-store.json') { 'AutoStart' } else { 'autoStart' }
      $json | Add-Member -NotePropertyName $key -NotePropertyValue $true -Force
      WriteUtf8 $settings ($json | ConvertTo-Json -Depth 20)
    } catch { Write-Host "   PAZI  uključi ručno: Docker Desktop > Settings > Start Docker Desktop when you sign in" -ForegroundColor Yellow }
  }
}
Ok 'Docker radi i pali se sa Windows-om'

Step 'Tailscale (javna HTTPS adresa)'
if (-not (Test-Path $tailscale)) {
  winget install -e --id Tailscale.Tailscale --accept-package-agreements --accept-source-agreements
  YourTurn 'Tailscale je instaliran. Klikni ikonicu Tailscale pored sata i prijavi se istim nalogom kao VPS.'
}
$status = (& $tailscale status --json) -join "`n" | ConvertFrom-Json
if ($status.BackendState -ne 'Running') { YourTurn 'Klikni ikonicu Tailscale pored sata i prijavi se istim nalogom kao VPS.' }
$publicHost = $status.Self.DNSName.TrimEnd('.')
$publicUrl = "https://$publicHost"
Ok $publicUrl

Step 'Podešavanja (.env)'
$envPath = Join-Path $Dir '.env'
if (Test-Path $envPath) {
  $envText = Get-Content $envPath -Raw
} else {
  $envText = Get-Content (Join-Path $Dir '.env.example') -Raw
  $envText = SetEnvValue $envText 'JWT_SECRET' (NewSecret 48)
  $envText = SetEnvValue $envText 'POSTGRES_PASSWORD' (NewSecret 24)
  $envText = SetEnvValue $envText 'TEMPORAL_DB_PASSWORD' (NewSecret 24)
}
$envText = SetEnvValue $envText 'MAIN_URL' $publicUrl
$envText = SetEnvValue $envText 'FRONTEND_URL' $publicUrl
$envText = SetEnvValue $envText 'NEXT_PUBLIC_BACKEND_URL' "$publicUrl/api"
WriteUtf8 $envPath $envText
Ok "$envPath (tajne ostaju samo na ovom računaru)"

Step 'Postiz'
Push-Location $Dir
try {
  docker compose pull
  docker compose up -d --remove-orphans
  if ($LASTEXITCODE -ne 0) { throw 'docker compose up nije uspeo' }
} finally { Pop-Location }
Write-Host '   čekam da se Postiz podigne (do 5 min)...'
for ($i = 0; $i -lt 60 -and -not (TestPostiz); $i++) { Start-Sleep 5 }
if (-not (TestPostiz)) { throw "Postiz ne odgovara na http://127.0.0.1:$Port. Pogledaj: docker compose -f $Dir\docker-compose.yaml logs postiz" }
Ok "radi lokalno na http://127.0.0.1:$Port"

Step 'Javni pristup (Tailscale Funnel)'
Write-Host '   Ako Tailscale ispiše link "To enable, visit...", otvori ga i klikni Enable. Skripta čeka.'
& $tailscale funnel --bg $Port
if ($LASTEXITCODE -ne 0) { YourTurn 'Funnel nije uključen. Otvori link koji je Tailscale ispisao i klikni Enable.' }
Ok "$publicUrl -> 127.0.0.1:$Port"

Step 'Nadzor (watchdog na 5 min + dnevni backup baze)'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Dir\watchdog.ps1`""
$triggers = @(
  (New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"),
  (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5))
)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
$taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName 'postiz-watchdog' -Action $action -Trigger $triggers -Principal $principal -Settings $taskSettings -Force | Out-Null
Ok 'zadatak postiz-watchdog registrovan'

Write-Host "`nGOTOVO. Postiz: $publicUrl" -ForegroundColor Green
Write-Host 'Prvi nalog koji se registruje postaje admin; posle njega registracija je zatvorena.'
