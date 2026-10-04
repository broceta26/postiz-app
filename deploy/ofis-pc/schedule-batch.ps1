# Zakazuje ODOBREN paket objava u lokalni Postiz preko Public API-ja.
# Bezbedno je pokretati više puta: već zakazano se preskače (stanje u C:\postiz\scheduled\).
#
#   powershell -ExecutionPolicy Bypass -File C:\postiz\schedule-batch.ps1 -Batch <paket.json> -Brand "FX Doctor" -DryRun
#   ... -TestPost   -> prva objava paketa izlazi za ~3 min na povezane kanale, bez upisa u stanje (provera izgleda)
#   ... -TestPost -Only okt26-fbig-03   -> isto, ali za izabranu objavu
#   ... -MarkDone okt26-fbig-03         -> objava je već izašla (npr. proba): upiši je u stanje, da se ne zakaže ponovo
#   powershell -ExecutionPolicy Bypass -File C:\postiz\schedule-batch.ps1 -Batch <paket.json> -Brand "FX Doctor"
#
# Paket (JSON niz): { id, date (ISO sa zonom), channels: [telegram|facebook|instagram|linkedin-page],
#                     text: "..." ili { <kanal>: "..." } }
# Slike: <Images>\<id>_NN.jpg (podrazumevano folder "kreative" pored paketa); idu na facebook i instagram.
param(
  [Parameter(Mandatory = $true)][string]$Batch,
  [Parameter(Mandatory = $true)][string]$Brand,
  [string]$Images = '',
  [string]$Dir = 'C:\postiz',
  [int]$Port = 4007,
  [switch]$DryRun,
  [switch]$TestPost,
  [string]$Only = '',
  [string]$MarkDone = ''
)

$ErrorActionPreference = 'Stop'
$api = "http://127.0.0.1:$Port/api/public/v1"
$imageChannels = @('facebook', 'instagram')
$channelAliases = @{ 'instagram' = @('instagram', 'instagram-standalone') }

function EnvValue([string]$name) {
  # Tolerant of Notepad edits: BOM / zero-width chars, spaces around "=", quotes, a duplicate empty line
  $value = $null; $found = 0
  foreach ($raw in [System.IO.File]::ReadAllLines((Join-Path $Dir '.env'))) {
    $line = $raw.Trim([char]0xFEFF, [char]0x200B, [char]0x00A0, ' ', "`t")
    if ($line -match "^$([regex]::Escape($name))\s*=(.*)$") {
      $found++
      $candidate = $Matches[1].Trim().Trim('"', "'")
      if ($candidate) { $value = $candidate }
    }
  }
  if (-not $value -and $found) { Write-Host "  .env: $found red(ova) $name, ali bez vrednosti" -ForegroundColor Yellow }
  return $value
}
function Api($method, $path, $body) {
  $params = @{ Method = $method; Uri = "$api$path"; Headers = @{ Authorization = $script:apiKey } }
  if ($body) {
    $params.ContentType = 'application/json; charset=utf-8'
    $params.Body = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $body -Depth 20 -Compress))
  }
  Invoke-RestMethod @params
}
function ToHtml([string]$text) {
  # Postiz editor content: one <p> per line, empty line = empty paragraph
  $escaped = $text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
  -join ($escaped -split "`r?`n" | ForEach-Object { "<p>$_</p>" })
}
function UtcDate($value) {
  if ($value -is [datetime]) { return $value.ToUniversalTime() }
  return ([DateTimeOffset]::Parse($value)).UtcDateTime
}
function SaveState { WriteUtf8 $statePath (ConvertTo-Json -InputObject $state -Depth 20) }
function WriteUtf8($path, $text) { [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $false)) }

$script:apiKey = EnvValue 'POSTIZ_API_KEY'
if (-not $apiKey) { throw "Upiši POSTIZ_API_KEY u $Dir\.env (Postiz > Settings > Developers)." }
$Batch = (Resolve-Path $Batch).Path
if (-not $Images) { $Images = Join-Path (Split-Path -Parent $Batch) 'kreative' }
# PS 5.1 emits a parsed JSON array as ONE object; assigning it first makes the pipe enumerate it
$parsed = Get-Content $Batch -Raw -Encoding UTF8 | ConvertFrom-Json
$items = @($parsed | Sort-Object { UtcDate $_.date })

# --- channels of this brand
$allIntegrations = Api 'GET' '/integrations' $null
$integrations = @($allIntegrations | Where-Object { -not $_.disabled -and $_.customer -and $_.customer.name -eq $Brand })
if (-not $integrations) {
  $groups = ($allIntegrations | Where-Object { $_.customer } | ForEach-Object { $_.customer.name } | Sort-Object -Unique) -join ', '
  throw "Nema aktivnih kanala u grupi '$Brand'. Postojeće grupe: $groups"
}
$byChannel = @{}
foreach ($channel in @('telegram', 'facebook', 'instagram', 'linkedin-page')) {
  $identifiers = if ($channelAliases.ContainsKey($channel)) { $channelAliases[$channel] } else { @($channel) }
  $found = @($integrations | Where-Object { $identifiers -contains $_.identifier })
  if ($found.Count -gt 1) { throw "Grupa '$Brand' ima $($found.Count) kanala tipa $channel ($(($found | ForEach-Object { $_.name }) -join ', ')). Ostavi jedan." }
  if ($found.Count -eq 1) { $byChannel[$channel] = $found[0] }
}
Write-Host "Kanali za '$Brand':" -ForegroundColor Cyan
$byChannel.GetEnumerator() | ForEach-Object { Write-Host ("  {0,-14} {1}" -f $_.Key, $_.Value.name) }

# --- state (what is already scheduled / uploaded)
$stateDir = Join-Path $Dir 'scheduled'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$statePath = Join-Path $stateDir ((Split-Path -Leaf $Batch) -replace '\.json$', '.state.json')
$state = @{ posts = @{}; uploads = @{} }
if (Test-Path $statePath) {
  $saved = Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
  $saved.posts.PSObject.Properties | ForEach-Object { $state.posts[$_.Name] = $_.Value }
  $saved.uploads.PSObject.Properties | ForEach-Object { $state.uploads[$_.Name] = $_.Value }
}

if ($MarkDone) {
  $item = $items | Where-Object { $_.id -eq $MarkDone } | Select-Object -First 1
  if (-not $item) { throw "U paketu nema objave sa id '$MarkDone'." }
  foreach ($channel in $item.channels) {
    if ($byChannel.ContainsKey($channel)) {
      $state.posts["$($item.id)|$channel"] = @{ at = (Get-Date).ToString('o'); response = 'marked done (already published)' }
      Write-Host "  OZNAČENO $($item.id) | $channel kao objavljeno" -ForegroundColor Green
    }
  }
  SaveState
  return
}

$scheduled = 0; $skipped = 0; $missing = @{}
if ($Only) {
  $items = @($items | Where-Object { $_.id -eq $Only })
  if (-not $items) { throw "U paketu nema objave sa id '$Only'." }
}
if ($TestPost) { $items = @($items | Select-Object -First 1) }
foreach ($item in $items) {
  $when = UtcDate $item.date
  if ($TestPost) { $when = (Get-Date).ToUniversalTime().AddMinutes(3) }
  elseif ($when -lt (Get-Date).ToUniversalTime().AddMinutes(10)) {
    Write-Host "  PRESKAČEM $($item.id): termin $($item.date) je prošao" -ForegroundColor Yellow; $skipped++; continue
  }
  $posts = @(); $channelsInRequest = @()
  $files = @(Get-ChildItem -Path $Images -Filter "$($item.id)_*.jpg" -ErrorAction SilentlyContinue | Sort-Object Name)
  if ($item.channels -contains 'instagram' -and $files.Count -eq 0) {
    # the post is designed around its creative: hold FB and IG together until the images exist
    Write-Host "  PRESKAČEM $($item.id) na facebook/instagram: nema slike $($item.id)_NN.jpg u $Images" -ForegroundColor Yellow
  }
  foreach ($channel in $item.channels) {
    $key = "$($item.id)|$channel"
    if ($state.posts.ContainsKey($key) -and -not $TestPost) { continue }
    if (-not $byChannel.ContainsKey($channel)) { $missing[$channel] = $true; continue }
    $text = if ($item.text -is [string]) { $item.text } else { $item.text.$channel }
    if (-not $text) { throw "$($item.id): nema teksta za kanal $channel" }

    $media = @()
    if ($imageChannels -contains $channel) {
      if ($item.channels -contains 'instagram' -and $files.Count -eq 0) { continue }
      foreach ($file in $files) {
        if (-not $state.uploads.ContainsKey($file.Name)) {
          if ($DryRun) { $state.uploads[$file.Name] = @{ id = 'dry-run'; path = $file.Name } }
          else {
            $raw = & curl.exe -s -f -X POST -H "Authorization: $apiKey" -F "file=@$($file.FullName)" "$api/upload"
            if ($LASTEXITCODE -ne 0) { throw "Upload $($file.Name) nije uspeo (curl $LASTEXITCODE)" }
            $uploaded = ($raw -join "`n") | ConvertFrom-Json
            $state.uploads[$file.Name] = @{ id = $uploaded.id; path = $uploaded.path }
            SaveState
          }
        }
        $media += @{ id = $state.uploads[$file.Name].id; path = $state.uploads[$file.Name].path }
      }
    }
    $settings = if ($channel -eq 'instagram') { @{ post_type = 'post' } } else { @{} }
    $posts += @{ integration = @{ id = $byChannel[$channel].id }; value = @(@{ content = (ToHtml $text); image = $media }); settings = $settings }
    $channelsInRequest += $channel
  }
  if (-not $posts) { continue }

  $label = "{0}  {1:yyyy-MM-dd HH:mm} UTC  {2}" -f $item.id, $when, ($channelsInRequest -join ', ')
  if ($DryRun) { Write-Host "  [proba] $label"; $scheduled++; continue }
  $body = @{ type = 'schedule'; shortLink = $false; date = $when.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [System.Globalization.CultureInfo]::InvariantCulture); tags = @(); posts = $posts }
  try { $response = Api 'POST' '/posts' $body }
  catch {
    $detail = $_.ErrorDetails.Message
    throw "$($item.id) nije zakazan: $($_.Exception.Message) $detail"
  }
  if ($TestPost) { Write-Host "  TEST $label (izlazi za ~3 min; nije upisano u stanje, pa pravo zakazivanje ide normalno)" -ForegroundColor Green; $scheduled++; continue }
  foreach ($channel in $channelsInRequest) { $state.posts["$($item.id)|$channel"] = @{ at = (Get-Date).ToString('o'); response = $response } }
  SaveState
  Write-Host "  ZAKAZANO $label" -ForegroundColor Green
  $scheduled++
}

if ($DryRun) { Write-Host "`nPROBA: $scheduled zahteva bi bilo poslato, ništa nije zakazano." -ForegroundColor Cyan }
else { Write-Host "`nZakazano: $scheduled zahteva. Stanje: $statePath" -ForegroundColor Green }
if ($skipped) { Write-Host "Preskočeno (prošao termin): $skipped" -ForegroundColor Yellow }
if ($missing.Count) { Write-Host "Kanali koji još nisu povezani u grupi '$Brand': $($missing.Keys -join ', '). Kad ih povežeš, pokreni skriptu ponovo; dodaće samo te objave." -ForegroundColor Yellow }
