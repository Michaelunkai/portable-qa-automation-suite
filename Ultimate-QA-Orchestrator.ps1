[CmdletBinding()]
param(
  [string]$TargetUrl,
  [string]$ApiBaseUrl,
  [string]$ApiCollection,
  [string]$ContractSchema,
  [string]$ConfigPath,
  [ValidateRange(1,10000)][int]$VirtualUsers = 5,
  [ValidateRange(1,3600)][int]$RampSeconds = 5,
  [ValidateRange(1,3600)][int]$HoldSeconds = 10,
  [ValidateRange(1,600000)][int]$ApiTimeoutMs = 5000,
  [ValidateRange(1,600000)][int]$P95ThresholdMs = 1000,
  [ValidateRange(1,600000)][int]$P99ThresholdMs = 2000,
  [ValidateRange(1,500)][int]$MaxPages = 20,
  [switch]$Continuous,
  [ValidateRange(1,86400)][int]$PollSeconds = 300,
  [switch]$DryRun,
  [switch]$UpdateVisualBaseline,
  [switch]$SkipToolUpdates
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$Root = $PSScriptRoot
$Play = Join-Path $Root 'playwright'
$K6 = Join-Path $Root 'k6'
$Axe = Join-Path $Root 'k6-axe-a11y'
$Newman = Join-Path $Root 'postman-cli'
$Reports = Join-Path $Root 'reports'
$TempRoot = Join-Path $Root 'tmp'
$State = Join-Path $TempRoot 'state'
$Node = Join-Path $Play 'node.exe'
$Npm = Join-Path $Play 'npm-runtime\bin\npm-cli.js'
$PlayCli = Join-Path $Play 'node_modules\playwright\cli.js'
$PlayTestCli = Join-Path $Play 'node_modules\@playwright\test\cli.js'
$NewmanCli = Join-Path $Newman 'node_modules\newman\bin\newman.js'
$K6Exe = Join-Path $K6 'k6.exe'
$PlayConfig = Join-Path $Play 'playwright.config.js'
$MockServer = Join-Path $Root 'mock\mock-server.js'
$env:TEMP = Join-Path $State 'temp'; $env:TMP = $env:TEMP
$env:USERPROFILE = Join-Path $State 'userprofile'
$env:APPDATA = Join-Path $State 'AppData\Roaming'
$env:LOCALAPPDATA = Join-Path $State 'AppData\Local'
$env:HOME = Join-Path $State 'home'
$env:NPM_CONFIG_CACHE = Join-Path $TempRoot 'npm-cache'
$env:NPM_CONFIG_PREFIX = Join-Path $Play 'npm-global'
$env:npm_config_userconfig = Join-Path $State 'userprofile\.npmrc'
$env:PLAYWRIGHT_BROWSERS_PATH = Join-Path $Play 'browsers'
$env:NODE_PATH = Join-Path $Axe 'node_modules'
$env:PATH = "$Play;$env:PATH"
foreach ($d in @($Reports,(Join-Path $Reports 'playwright'),$env:TEMP,$env:USERPROFILE,$env:APPDATA,$env:LOCALAPPDATA,$env:HOME,$env:NPM_CONFIG_CACHE,$env:NPM_CONFIG_PREFIX,$env:PLAYWRIGHT_BROWSERS_PATH)) { [IO.Directory]::CreateDirectory($d) | Out-Null }

if ($ConfigPath) {
  if (!(Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Config file not found: $ConfigPath" }
  $ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
  $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
  foreach ($name in @('TargetUrl','ApiBaseUrl','ApiCollection','ContractSchema','VirtualUsers','RampSeconds','HoldSeconds','ApiTimeoutMs','P95ThresholdMs','P99ThresholdMs','MaxPages')) {
    if (!$PSBoundParameters.ContainsKey($name) -and $cfg.PSObject.Properties[$name]) { Set-Variable -Name $name -Value $cfg.$name }
  }
  foreach ($name in @('ApiCollection','ContractSchema')) {
    $value = Get-Variable -Name $name -ValueOnly
    if ($value -and !([IO.Path]::IsPathRooted($value))) { Set-Variable -Name $name -Value (Join-Path (Split-Path -Parent $ConfigPath) $value) }
  }
}
if ($DryRun) {
  $tcp = [System.Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
  $tcp.Start(); $MockPort = ([Net.IPEndPoint]$tcp.LocalEndpoint).Port; $tcp.Stop()
  $env:QA_MOCK_PORT = [string]$MockPort
  $TargetUrl = "http://127.0.0.1:$MockPort/"
  $ApiBaseUrl = "http://127.0.0.1:$MockPort/api"
  $ContractSchema = Join-Path $Root 'collections\mock-api.schema.json'
}
if (!$TargetUrl -and $ApiBaseUrl) { $TargetUrl = $ApiBaseUrl }
if (!$TargetUrl) { $TargetUrl = Read-Host 'Target application URL' }
if (!$ApiBaseUrl) { $ApiBaseUrl = Read-Host 'API base endpoint (blank uses the target URL)' }
if (!$ApiBaseUrl) { $ApiBaseUrl = $TargetUrl }
if (!(Test-Path -LiteralPath $Node -PathType Leaf) -or !(Test-Path -LiteralPath $K6Exe -PathType Leaf) -or !(Test-Path -LiteralPath $NewmanCli -PathType Leaf) -or !(Test-Path -LiteralPath $PlayTestCli -PathType Leaf)) { throw 'One or more portable runtimes are missing. Run the installer in this suite folder.' }
foreach ($url in @($TargetUrl,$ApiBaseUrl)) {
  if (![Uri]::IsWellFormedUriString($url,[UriKind]::Absolute) -or !($url.StartsWith('http://') -or $url.StartsWith('https://'))) { throw "Expected an absolute HTTP(S) URL: $url" }
}
if ($P99ThresholdMs -lt $P95ThresholdMs) { throw 'P99ThresholdMs must be greater than or equal to P95ThresholdMs.' }

function Write-JsonFile([string]$Path,[object]$Value) {
  $json = ConvertTo-Json -InputObject $Value -Depth 80
  [IO.File]::WriteAllText($Path,$json,[Text.UTF8Encoding]::new($false))
}
function Get-SuiteFingerprint {
  $files = @()
  foreach ($dir in @($Root,$Play,$Axe,$Newman,$K6)) {
    if (Test-Path -LiteralPath $dir) { $files += [IO.Directory]::EnumerateFiles($dir,'*.*',[IO.SearchOption]::TopDirectoryOnly) }
  }
  foreach ($dir in @((Join-Path $Play 'tests'),(Join-Path $Root 'collections'),(Join-Path $Root 'mock'))) {
    if (Test-Path -LiteralPath $dir) { $files += [IO.Directory]::EnumerateFiles($dir,'*.*',[IO.SearchOption]::AllDirectories) }
  }
  $files = $files | Where-Object {
    $_ -notmatch '\\(node_modules|browsers|tmp|reports|logs|\.git)\\' -and ([IO.Path]::GetExtension($_) -in @('.ps1','.js','.json','.md','.png'))
  } | Sort-Object
  $parts = foreach ($file in $files) { $rel=$file.Substring($Root.Length); $hash=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash; "$rel|$hash" }
  $sha=[Security.Cryptography.SHA256]::Create()
  try {
    $digest=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($parts -join [char]10))))
    return $digest.Replace('-','')
  } finally { $sha.Dispose() }
}
function Get-ValueOrNull($Object,[string]$Property) {
  if ($null -eq $Object -or !$Object.PSObject.Properties[$Property]) { return $null }
  return $Object.PSObject.Properties[$Property].Value
}
function Add-QaTestHooks([object[]]$Items,[string[]]$TestLines) {
  foreach ($item in $Items) {
    if ($item.PSObject.Properties['item'] -and $item.item) { Add-QaTestHooks -Items @($item.item) -TestLines $TestLines }
    if ($item.PSObject.Properties['request'] -and $item.request) {
      $events=@(); if ($item.PSObject.Properties['event'] -and $item.event) { $events=@($item.event) }
      $events += @{ listen='test'; script=@{ type='text/javascript'; exec=$TestLines } }
      if ($item -is [System.Collections.IDictionary]) { $item['event']=$events }
      elseif ($item.PSObject.Properties['event']) { $item.event=$events }
      else { $item | Add-Member -MemberType NoteProperty -Name event -Value $events }
    }
  }
}

function Update-PortableTools {
  Write-Host 'Checking portable tool updates after a suite change...'
  foreach ($prefix in @($Play,$Axe,$Newman)) {
    & $Node $Npm 'update' '--prefix' $prefix '--no-audit' '--no-fund'
    if ($LASTEXITCODE -ne 0) { Write-Warning "npm update failed for $prefix; retaining the installed copy." }
  }
  try {
    $latest = Invoke-RestMethod -Uri 'https://api.github.com/repos/grafana/k6/releases/latest' -Headers @{ 'User-Agent'='Portable-QA-Automation'; 'Accept'='application/vnd.github+json' }
    $manifestPath = Join-Path $Root 'tool-manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($latest.tag_name -ne $manifest.k6) {
      $asset = $latest.assets | Where-Object { $_.name -match '^k6-.*-windows-amd64\.zip$' } | Select-Object -First 1
      $zip = Join-Path $TempRoot 'k6-update.zip'
      $dest = Join-Path $TempRoot 'k6-update'
      Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
      if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
      [IO.Compression.ZipFile]::ExtractToDirectory($zip,$dest)
      $exe = Get-ChildItem -LiteralPath $dest -Filter 'k6.exe' -File -Recurse | Select-Object -First 1
      if (!$exe) { throw 'Latest k6 archive does not contain k6.exe.' }
      Copy-Item -LiteralPath $exe.FullName -Destination $K6Exe -Force
      Remove-Item -LiteralPath $zip,$dest -Recurse -Force
      $manifest.k6 = $latest.tag_name
    }
    & $Node $PlayCli 'install' 'chromium' 'firefox' 'webkit'
    if ($LASTEXITCODE -ne 0) { Write-Warning 'Playwright browser refresh failed; existing browser builds remain available.' }
    $manifest.playwright = (Get-Content -LiteralPath (Join-Path $Play 'node_modules\playwright\package.json') -Raw | ConvertFrom-Json).version
    $manifest.axeCli = (Get-Content -LiteralPath (Join-Path $Axe 'node_modules\@axe-core\cli\package.json') -Raw | ConvertFrom-Json).version
    $manifest.axePlaywright = (Get-Content -LiteralPath (Join-Path $Axe 'node_modules\@axe-core\playwright\package.json') -Raw | ConvertFrom-Json).version
    $manifest.newman = (Get-Content -LiteralPath (Join-Path $Newman 'node_modules\newman\package.json') -Raw | ConvertFrom-Json).version
    $manifest.updatedUtc = [DateTime]::UtcNow.ToString('o')
    Write-JsonFile -Path $manifestPath -Value $manifest
  } catch { Write-Warning ('Portable update check failed: ' + $_.Exception.Message) }
}

function Invoke-ApiPhase {
  $reportPath = Join-Path $Reports 'api_test_results.json'
  $tempCollection = Join-Path $TempRoot 'api.collection.instrumented.json'
  $env:QA_SUITE_ROOT = $Root
  $env:QA_API_REPORT = $reportPath
  $env:QA_TEMP_COLLECTION = $tempCollection
  $env:QA_API_COLLECTION = $ApiCollection
  $env:QA_API_SCHEMA_PATH = $ContractSchema
  $env:QA_API_BASE_URL = $ApiBaseUrl
  $env:QA_API_TIMEOUT_MS = [string]$ApiTimeoutMs
  try {
    & $Node (Join-Path $Newman 'qa-newman-runner.js') | Out-Host
    $code = $LASTEXITCODE
    if (!(Test-Path -LiteralPath $reportPath -PathType Leaf)) {
      Write-JsonFile -Path $reportPath -Value @{ success=$false; exitCode=$code; error='Newman did not produce a JSON report.' }
    }
    return $code
  } finally {
    if (Test-Path -LiteralPath $tempCollection) { Remove-Item -LiteralPath $tempCollection -Force }
  }
}
function Invoke-QACycle {
  $phase = [ordered]@{ api=$false; playwright=$false; accessibility=$false; performance=$false }
  $playCurrent = Join-Path (Join-Path $Reports 'playwright') 'current'
  if (Test-Path -LiteralPath $playCurrent) {
    $fullCurrent=[IO.Path]::GetFullPath($playCurrent)
    $expected=[IO.Path]::GetFullPath((Join-Path (Join-Path $Reports 'playwright') 'current'))
    if ($fullCurrent -ne $expected -or !$fullCurrent.StartsWith($Root,[StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to clear an unexpected Playwright output path.' }
    Remove-Item -LiteralPath $fullCurrent -Recurse -Force
  }
  [IO.Directory]::CreateDirectory($playCurrent) | Out-Null
  $fragmentDir = Join-Path $playCurrent 'a11y-fragments'
  $testOutput = Join-Path $playCurrent 'test-output'
  [IO.Directory]::CreateDirectory($fragmentDir) | Out-Null
  $env:QA_TARGET_URL = $TargetUrl
  $env:QA_API_BASE_URL = $ApiBaseUrl
  $env:QA_MAX_PAGES = [string]$MaxPages
  $env:QA_UPDATE_VISUAL_BASELINE = if ($UpdateVisualBaseline) { '1' } else { '0' }
  $env:REPORT_DIR = $playCurrent
  $env:PW_OUTPUT_DIR = $testOutput
  $env:AXE_FRAGMENT_DIR = $fragmentDir
  Write-Host 'Phase 1/4: API functionality, JSON structure, response time, and schema contract'
  try {
    & $Node $NewmanCli --version | Out-Null
    $apiCode = Invoke-ApiPhase
    $phase.api = [bool]($apiCode -eq 0)
  } catch {
    Write-Warning ('API phase failed: ' + $_.Exception.Message)
    Write-JsonFile -Path (Join-Path $Reports 'api_test_results.json') -Value @{ success=$false; error=$_.Exception.Message }
    $phase.api = $false
  }
  Write-Host 'Phase 2/4: Playwright Chromium, Firefox, WebKit, screenshots, trace, and video'
  try {
    & $Node $PlayTestCli 'test' '--config' $PlayConfig '--workers' '1' | Out-Host
    $pwCode = $LASTEXITCODE
    $phase.playwright = ($pwCode -eq 0)
  } catch {
    Write-Warning ('Playwright phase failed: ' + $_.Exception.Message)
    $phase.playwright = $false
  }
  Write-Host 'Phase 3/4: axe-core WCAG 2.1 A/AA/AAA findings across discovered pages'
  $audits = @()
  foreach ($f in [IO.Directory]::EnumerateFiles($fragmentDir,'*.json')) {
    try {
      $fragment = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
      foreach ($audit in @($fragment.audits)) { $audits += $audit }
    } catch { Write-Warning ('Could not read axe result ' + $f + ': ' + $_.Exception.Message) }
  }
  $violationCount = 0
  foreach ($audit in $audits) { $violationCount += @($audit.violations).Count }
  $a11y = [ordered]@{
    generatedUtc=[DateTime]::UtcNow.ToString('o')
    standards=@('WCAG 2.1 A','WCAG 2.1 AA','WCAG 2.1 AAA')
    targetUrl=$TargetUrl
    pagesScanned=$audits.Count
    violationCount=$violationCount
    audits=$audits
  }
  Write-JsonFile -Path (Join-Path $Reports 'a11y_results.json') -Value $a11y
  $phase.accessibility = ($audits.Count -gt 0 -and $violationCount -eq 0)
  Write-Host 'Phase 4/4: k6 ramped virtual-user UI/API performance test'
  $performancePath = Join-Path $Reports 'performance_results.json'
  $perfScript = Join-Path $K6 'performance.js'
  try {
    $env:K6_SUMMARY_TREND_STATS = 'avg,min,med,max,p(90),p(95),p(99)'
    $perfArgs = @('run','--summary-export',$performancePath,'--summary-trend-stats=avg,min,med,max,p(90),p(95),p(99)','-e',"QA_TARGET_URL=$TargetUrl",'-e',"QA_API_BASE_URL=$ApiBaseUrl",'-e',"QA_VUS=$VirtualUsers",'-e',"QA_RAMP_SECONDS=$RampSeconds",'-e',"QA_HOLD_SECONDS=$HoldSeconds",'-e',"QA_P95_MS=$P95ThresholdMs",'-e',"QA_P99_MS=$P99ThresholdMs",$perfScript)
    & $K6Exe @perfArgs | Out-Host
    $k6Code = $LASTEXITCODE
    $phase.performance = ($k6Code -eq 0 -and (Test-Path -LiteralPath $performancePath -PathType Leaf))
  } catch {
    Write-Warning ('k6 phase failed: ' + $_.Exception.Message)
    $phase.performance = $false
  }
  $p95Value=$null; $p99Value=$null; $errorRate=$null; $throughput=$null
  if (Test-Path -LiteralPath $performancePath) {
    try {
      $perf = Get-Content -LiteralPath $performancePath -Raw | ConvertFrom-Json
      $durationValues = $perf.metrics.http_req_duration
      if ($durationValues.PSObject.Properties['values']) { $durationValues = $durationValues.values }
      $errorValues = $perf.metrics.http_req_failed
      if ($errorValues.PSObject.Properties['values']) { $errorValues = $errorValues.values }
      $p=$durationValues.PSObject.Properties['p(95)']; if ($p) { $p95Value=[double]$p.Value }
      $p=$durationValues.PSObject.Properties['p(99)']; if ($p) { $p99Value=[double]$p.Value }
      $p=$errorValues.PSObject.Properties['rate']; if (!$p) { $p=$errorValues.PSObject.Properties['value'] }; if ($p) { $errorRate=[double]$p.Value }
      $requests = $perf.metrics.http_reqs
      if ($requests.PSObject.Properties['values']) { $requests = $requests.values }
      $p=$requests.PSObject.Properties['rate']; if ($p) { $throughput=[double]$p.Value }
    } catch { Write-Warning ('Could not read k6 summary metrics: ' + $_.Exception.Message) }
  }
  $regressions=@()
  if ($Continuous -and $null -ne $p95Value) {
    $baseDir = Join-Path $Reports 'baselines'
    [IO.Directory]::CreateDirectory($baseDir) | Out-Null
    $keyInput = $TargetUrl + '|' + $ApiBaseUrl
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($keyInput)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    $baselinePath = Join-Path $baseDir ($key + '.json')
    if (!(Test-Path -LiteralPath $baselinePath)) {
      Write-JsonFile -Path $baselinePath -Value @{ targetUrl=$TargetUrl; apiBaseUrl=$ApiBaseUrl; p95=$p95Value; p99=$p99Value; errorRate=$errorRate; createdUtc=[DateTime]::UtcNow.ToString('o') }
      Write-Host ('Saved performance baseline: ' + $baselinePath)
    } else {
      $baseline=Get-Content -LiteralPath $baselinePath -Raw | ConvertFrom-Json
      $p95Limit=[Math]::Max(5.0,([double]$baseline.p95 * 1.2))
      if ($null -ne $baseline.p95 -and $p95Value -gt $p95Limit) { $regressions += "p95 latency rose from $($baseline.p95) ms to $p95Value ms" }
      $p99Limit=[Math]::Max(5.0,([double]$baseline.p99 * 1.2))
      if ($null -ne $baseline.p99 -and $p99Value -gt $p99Limit) { $regressions += "p99 latency rose from $($baseline.p99) ms to $p99Value ms" }
      if ($null -ne $baseline.errorRate -and $errorRate -gt ([double]$baseline.errorRate + 0.01)) { $regressions += "HTTP error rate rose from $($baseline.errorRate) to $errorRate" }
      if ($regressions.Count) { Write-Warning ('PERFORMANCE REGRESSION: ' + ($regressions -join '; ')); $phase.performance=$false }
    }
  }
  $overall = [ordered]@{
    generatedUtc=[DateTime]::UtcNow.ToString('o')
    targetUrl=$TargetUrl
    apiBaseUrl=$ApiBaseUrl
    phases=$phase
    accessibilityViolations=$violationCount
    performance=@{ p95Ms=$p95Value; p99Ms=$p99Value; errorRate=$errorRate; throughputRps=$throughput; regressions=$regressions }
    passed=(@($phase.Values | Where-Object { !$_ }).Count -eq 0)
    runtimePaths=@{ temp=$env:TEMP; appData=$env:APPDATA; localAppData=$env:LOCALAPPDATA; userProfile=$env:USERPROFILE; npmCache=$env:NPM_CONFIG_CACHE; playwrightBrowsers=$env:PLAYWRIGHT_BROWSERS_PATH }
  }
  Write-JsonFile -Path (Join-Path $Reports 'overall_results.json') -Value $overall
  if ($DryRun) {
    $required = @((Join-Path $Reports 'api_test_results.json'),(Join-Path $Reports 'a11y_results.json'),$performancePath,(Join-Path $playCurrent 'playwright-results.json'))
    foreach ($f in $required) { if (!(Test-Path -LiteralPath $f -PathType Leaf)) { $overall.passed=$false; Write-Warning ('Dry-run report missing: ' + $f) } }
    foreach ($p in @($env:TEMP,$env:TMP,$env:APPDATA,$env:LOCALAPPDATA,$env:USERPROFILE,$env:NPM_CONFIG_CACHE,$env:PLAYWRIGHT_BROWSERS_PATH)) {
      if (!$p.StartsWith($Root,[StringComparison]::OrdinalIgnoreCase)) { $overall.passed=$false; Write-Warning ('Runtime path escaped suite folder: ' + $p) }
    }
    Write-JsonFile -Path (Join-Path $Reports 'overall_results.json') -Value $overall
  }
  [PSCustomObject]@{ Succeeded=$overall.passed; P95=$p95Value; P99=$p99Value; Phases=$phase; Regressions=$regressions }
}

$mockProcess = $null
$lastSuccess = $null
$lastFingerprint = $null
try {
  if ($DryRun) {
    $mockOut = Join-Path $Root 'logs\mock-server.stdout.log'
    $mockErr = Join-Path $Root 'logs\mock-server.stderr.log'
    $mockProcess = Start-Process -FilePath $Node -ArgumentList @($MockServer) -WorkingDirectory $Root -RedirectStandardOutput $mockOut -RedirectStandardError $mockErr -PassThru -WindowStyle Hidden
    $mockUrl = "http://127.0.0.1:$env:QA_MOCK_PORT/"
    $ready = $false
    for ($i=0; $i -lt 40; $i++) {
      try { $r=[Net.HttpWebRequest]::Create($mockUrl); $r.Timeout=1000; $x=$r.GetResponse(); $x.Close(); $ready=$true; break } catch { Start-Sleep -Milliseconds 250 }
    }
    if (!$ready) { throw 'Local mock HTTP server did not become ready.' }
    Write-Host ('Local mock service ready at ' + $mockUrl)
  }
  do {
    $fingerprint = Get-SuiteFingerprint
    if ($Continuous -and $lastFingerprint -and $fingerprint -ne $lastFingerprint) {
      Write-Host 'Suite files changed; refreshing portable packages and browser builds.'
      if (!$SkipToolUpdates) { Update-PortableTools }
    }
    $result = Invoke-QACycle
    if ($null -ne $lastSuccess -and $lastSuccess -and !$result.Succeeded) { Write-Warning 'ALERT: new test failures appeared in this cycle.' }
    if ($null -ne $lastSuccess -and !$lastSuccess -and $result.Succeeded) { Write-Host 'RECOVERY: the previous cycle failures have cleared.' }
    $lastSuccess = $result.Succeeded
    $lastFingerprint = Get-SuiteFingerprint
    if (!$Continuous) {
      if ($result.Succeeded) {
        Write-Host ('All QA phases passed. Orchestrator: ' + (Join-Path $Root 'Ultimate-QA-Orchestrator.ps1'))
        break
      }
      Write-Warning 'One or more QA phases failed. See reports\overall_results.json.'
      exit 1
    }
    Write-Host ("Next full QA cycle in $PollSeconds seconds. Press Ctrl+C to stop.")
    Start-Sleep -Seconds $PollSeconds
  } while ($true)
} finally {
  if ($mockProcess -and !$mockProcess.HasExited) { Stop-Process -Id $mockProcess.Id -Force }
}
