[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot)
$environmentNames = @(
  'TEMP','TMP','USERPROFILE','APPDATA','LOCALAPPDATA','HOME','PATH',
  'NPM_CONFIG_CACHE','NPM_CONFIG_PREFIX','npm_config_userconfig',
  'PLAYWRIGHT_BROWSERS_PATH','NODE_PATH'
)
$savedEnvironment = @{}
foreach ($name in $environmentNames) {
  $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name,'Process')
}
$savedSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
$stageRoot = $null
$setupError = $null

function Get-Sha256([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-PublishedSha256([string]$ChecksumPath,[string]$FileName) {
  $escapedName = [regex]::Escape($FileName)
  foreach ($line in [IO.File]::ReadAllLines($ChecksumPath)) {
    if ($line -match ('^\s*([0-9a-fA-F]{64})\s+\*?' + $escapedName + '\s*$')) {
      return $Matches[1].ToLowerInvariant()
    }
  }
  throw ('The official checksum file does not contain an SHA-256 entry for ' + $FileName)
}

function Get-JsonFile([string]$Path) {
  return ([IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8) | ConvertFrom-Json)
}

function Invoke-HttpsDownload([string]$Uri,[string]$Destination) {
  Write-Host ('Downloading ' + [IO.Path]::GetFileName($Destination))
  Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop
  if (!(Test-Path -LiteralPath $Destination -PathType Leaf)) {
    throw ('The download did not create its destination file: ' + $Destination)
  }
}

function Get-VerifiedArchive([string]$Uri,[string]$Destination,[string]$ExpectedSha256) {
  if (Test-Path -LiteralPath $Destination -PathType Leaf) {
    if ((Get-Sha256 $Destination) -eq $ExpectedSha256) {
      Write-Host ('Using verified cached archive ' + [IO.Path]::GetFileName($Destination))
      return
    }
    Remove-Item -LiteralPath $Destination -Force
  }
  Invoke-HttpsDownload $Uri $Destination
  $actual = Get-Sha256 $Destination
  if ($actual -ne $ExpectedSha256) {
    Remove-Item -LiteralPath $Destination -Force
    throw ('SHA-256 verification failed for ' + [IO.Path]::GetFileName($Destination))
  }
  Write-Host ('SHA-256 verified: ' + [IO.Path]::GetFileName($Destination))
}

function Test-ExecutableVersion([string]$Path,[string[]]$Arguments,[string]$ExpectedText) {
  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  try {
    $output = & $Path @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { return $false }
    return (($output -join "`n") -match [regex]::Escape($ExpectedText))
  } catch {
    return $false
  }
}

try {
  if (![Environment]::Is64BitOperatingSystem -or ![Environment]::Is64BitProcess) {
    throw 'Setup requires 64-bit Windows and 64-bit Windows PowerShell 5.1.'
  }

  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $manifestPath = Join-Path $root 'tool-manifest.json'
  if (!(Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'tool-manifest.json is missing.' }
  $manifest = Get-JsonFile $manifestPath

  $nodeVersion = [string]$manifest.node
  $k6Version = [string]$manifest.k6
  $nodeExpectedHash = ([string]$manifest.nodeWinX64ZipSha256).ToLowerInvariant()
  $k6ExpectedHash = ([string]$manifest.k6WinX64ZipSha256).ToLowerInvariant()
  $k6ChecksumsExpectedHash = ([string]$manifest.k6ChecksumsSha256).ToLowerInvariant()
  if ($nodeVersion -notmatch '^\d+\.\d+\.\d+$' -or $k6Version -notmatch '^v\d+\.\d+\.\d+$') {
    throw 'tool-manifest.json contains an invalid Node.js or k6 version.'
  }
  foreach ($hash in @($nodeExpectedHash,$k6ExpectedHash,$k6ChecksumsExpectedHash)) {
    if ($hash -notmatch '^[0-9a-f]{64}$') { throw 'tool-manifest.json is missing a pinned SHA-256 value.' }
  }

  $playwrightRoot = Join-Path $root 'playwright'
  $k6Root = Join-Path $root 'k6'
  $downloadsRoot = Join-Path $root 'tmp\setup-cache'
  $stateRoot = Join-Path $root 'tmp\state'
  $npmCache = Join-Path $root 'tmp\npm-cache'
  $nodeExe = Join-Path $playwrightRoot 'node.exe'
  $nodeRuntimeRoot = Join-Path $playwrightRoot ('npm-runtime\node-v' + $nodeVersion + '-win-x64')
  $npmCli = Join-Path $nodeRuntimeRoot 'node_modules\npm\bin\npm-cli.js'
  $k6Exe = Join-Path $k6Root 'k6.exe'
  [IO.Directory]::CreateDirectory($downloadsRoot) | Out-Null

  $env:TEMP = Join-Path $stateRoot 'temp'
  $env:TMP = $env:TEMP
  $env:USERPROFILE = Join-Path $stateRoot 'userprofile'
  $env:APPDATA = Join-Path $stateRoot 'AppData\Roaming'
  $env:LOCALAPPDATA = Join-Path $stateRoot 'AppData\Local'
  $env:HOME = Join-Path $stateRoot 'home'
  $env:NPM_CONFIG_CACHE = $npmCache
  $env:NPM_CONFIG_PREFIX = Join-Path $playwrightRoot 'npm-global'
  $env:npm_config_userconfig = Join-Path $env:USERPROFILE '.npmrc'
  $env:PLAYWRIGHT_BROWSERS_PATH = Join-Path $playwrightRoot 'browsers'
  $env:NODE_PATH = Join-Path $playwrightRoot 'node_modules'
  $env:PATH = $playwrightRoot + ';' + $env:PATH
  foreach ($directory in @(
    $env:TEMP,$env:USERPROFILE,$env:APPDATA,$env:LOCALAPPDATA,$env:HOME,
    $env:NPM_CONFIG_CACHE,$env:NPM_CONFIG_PREFIX,$env:PLAYWRIGHT_BROWSERS_PATH,
    $env:NODE_PATH,$nodeRuntimeRoot,$k6Root
  )) { [IO.Directory]::CreateDirectory($directory) | Out-Null }

  $nodeZipName = 'node-v' + $nodeVersion + '-win-x64.zip'
  $nodeZipPath = Join-Path $downloadsRoot $nodeZipName
  $nodeChecksumsPath = Join-Path $downloadsRoot ('node-v' + $nodeVersion + '-SHASUMS256.txt')
  $nodeBaseUrl = 'https://nodejs.org/dist/v' + $nodeVersion + '/'
  Invoke-HttpsDownload ($nodeBaseUrl + 'SHASUMS256.txt') $nodeChecksumsPath
  $nodePublishedHash = Get-PublishedSha256 $nodeChecksumsPath $nodeZipName
  if ($nodePublishedHash -ne $nodeExpectedHash) {
    throw 'Node.js published checksum does not match nodeWinX64ZipSha256 in tool-manifest.json.'
  }

  if (!(Test-ExecutableVersion $nodeExe @('--version') ('v' + $nodeVersion)) -or !(Test-Path -LiteralPath $npmCli -PathType Leaf)) {
    $stageRoot = Join-Path (Join-Path $root 'tmp\setup') ('stage-' + [Guid]::NewGuid().ToString('N'))
    $nodeExtract = Join-Path $stageRoot 'node'
    [IO.Directory]::CreateDirectory($nodeExtract) | Out-Null
    Get-VerifiedArchive ($nodeBaseUrl + $nodeZipName) $nodeZipPath $nodeExpectedHash
    Expand-Archive -LiteralPath $nodeZipPath -DestinationPath $nodeExtract -Force
    $nodeArchiveRoot = Join-Path $nodeExtract ('node-v' + $nodeVersion + '-win-x64')
    if (!(Test-Path -LiteralPath (Join-Path $nodeArchiveRoot 'node.exe') -PathType Leaf)) {
      throw 'The verified Node.js archive did not contain its expected Windows runtime.'
    }
    if (!(Test-ExecutableVersion $nodeExe @('--version') ('v' + $nodeVersion))) {
      Copy-Item -LiteralPath (Join-Path $nodeArchiveRoot 'node.exe') -Destination $nodeExe -Force
    }
    if (!(Test-Path -LiteralPath $npmCli -PathType Leaf)) {
      $npmParent = Join-Path $nodeRuntimeRoot 'node_modules'
      [IO.Directory]::CreateDirectory($npmParent) | Out-Null
      Copy-Item -LiteralPath (Join-Path $nodeArchiveRoot 'node_modules\npm') -Destination (Join-Path $npmParent 'npm') -Recurse -Force
    }
  }
  if (!(Test-ExecutableVersion $nodeExe @('--version') ('v' + $nodeVersion))) {
    throw ('The installed portable Node.js version is not v' + $nodeVersion + '.')
  }
  if (!(Test-Path -LiteralPath $npmCli -PathType Leaf)) { throw 'The pinned Node.js archive did not provide its npm CLI.' }
  Write-Host ('Node.js ready: v' + $nodeVersion)

  $k6ZipName = 'k6-' + $k6Version + '-windows-amd64.zip'
  $k6ZipPath = Join-Path $downloadsRoot $k6ZipName
  $k6ChecksumsName = 'k6-' + $k6Version + '-checksums.txt'
  $k6ChecksumsPath = Join-Path $downloadsRoot $k6ChecksumsName
  $k6BaseUrl = 'https://github.com/grafana/k6/releases/download/' + $k6Version + '/'
  Invoke-HttpsDownload ($k6BaseUrl + $k6ChecksumsName) $k6ChecksumsPath
  if ((Get-Sha256 $k6ChecksumsPath) -ne $k6ChecksumsExpectedHash) {
    throw 'The official k6 checksum asset does not match k6ChecksumsSha256 in tool-manifest.json.'
  }
  $k6PublishedHash = Get-PublishedSha256 $k6ChecksumsPath $k6ZipName
  if ($k6PublishedHash -ne $k6ExpectedHash) {
    throw 'The official k6 archive checksum does not match k6WinX64ZipSha256 in tool-manifest.json.'
  }

  if (!(Test-ExecutableVersion $k6Exe @('version') $k6Version)) {
    if (!$stageRoot) { $stageRoot = Join-Path (Join-Path $root 'tmp\setup') ('stage-' + [Guid]::NewGuid().ToString('N')) }
    $k6Extract = Join-Path $stageRoot 'k6'
    [IO.Directory]::CreateDirectory($k6Extract) | Out-Null
    Get-VerifiedArchive ($k6BaseUrl + $k6ZipName) $k6ZipPath $k6ExpectedHash
    Expand-Archive -LiteralPath $k6ZipPath -DestinationPath $k6Extract -Force
    $k6ArchiveBinary = Get-ChildItem -LiteralPath $k6Extract -Filter 'k6.exe' -File -Recurse | Select-Object -First 1
    if (!$k6ArchiveBinary) { throw 'The verified k6 archive did not contain k6.exe.' }
    Copy-Item -LiteralPath $k6ArchiveBinary.FullName -Destination $k6Exe -Force
  }
  if (!(Test-ExecutableVersion $k6Exe @('version') $k6Version)) {
    throw ('The installed k6 version is not ' + $k6Version + '.')
  }
  Write-Host ('k6 ready: ' + $k6Version)

  if (!$stageRoot) { $stageRoot = Join-Path (Join-Path $root 'tmp\setup') ('stage-' + [Guid]::NewGuid().ToString('N')) }
  $setupSucceeded = $false
  foreach ($project in @('playwright','postman-cli','k6-axe-a11y')) {
    $projectRoot = Join-Path $root $project
    if (!(Test-Path -LiteralPath (Join-Path $projectRoot 'package-lock.json') -PathType Leaf)) {
      throw ('A package-lock.json is missing from ' + $project + '.')
    }
    Write-Host ('Installing locked npm dependencies: ' + $project)
    Push-Location -LiteralPath $projectRoot
    try {
      & $nodeExe $npmCli 'ci' '--no-audit' '--no-fund' '--cache' $npmCache
      if ($LASTEXITCODE -ne 0) { throw ('npm ci failed in ' + $project + ' with exit code ' + $LASTEXITCODE + '.') }
    } finally {
      Pop-Location
    }
  }

  $playwrightCli = Join-Path $playwrightRoot 'node_modules\@playwright\test\cli.js'
  if (!(Test-Path -LiteralPath $playwrightCli -PathType Leaf)) { throw '@playwright/test CLI was not installed.' }
  Write-Host 'Installing Playwright Chromium, Firefox and WebKit builds'
  & $nodeExe $playwrightCli 'install' 'chromium' 'firefox' 'webkit'
  if ($LASTEXITCODE -ne 0) { throw ('Playwright browser installation failed with exit code ' + $LASTEXITCODE + '.') }

  $packageChecks = @(
    @{ Path=(Join-Path $playwrightRoot 'node_modules\playwright\package.json'); Version=[string]$manifest.playwright; Label='Playwright' },
    @{ Path=(Join-Path $playwrightRoot 'node_modules\@playwright\test\package.json'); Version=[string]$manifest.playwright; Label='@playwright/test' },
    @{ Path=(Join-Path $root 'k6-axe-a11y\node_modules\@axe-core\cli\package.json'); Version=[string]$manifest.axeCli; Label='axe CLI' },
    @{ Path=(Join-Path $root 'k6-axe-a11y\node_modules\@axe-core\playwright\package.json'); Version=[string]$manifest.axePlaywright; Label='axe Playwright' },
    @{ Path=(Join-Path $root 'postman-cli\node_modules\newman\package.json'); Version=[string]$manifest.newman; Label='Newman' }
  )
  foreach ($check in $packageChecks) {
    if (!(Test-Path -LiteralPath $check.Path -PathType Leaf)) { throw ($check.Label + ' package is missing after npm ci.') }
    $package = Get-JsonFile $check.Path
    if ([string]$package.version -ne $check.Version) {
      throw ($check.Label + ' version ' + $package.version + ' does not match pinned ' + $check.Version + '.')
    }
    Write-Host ($check.Label + ' ready: ' + $package.version)
  }

  $browserDirectories = @(Get-ChildItem -LiteralPath $env:PLAYWRIGHT_BROWSERS_PATH -Directory -ErrorAction SilentlyContinue)
  foreach ($engine in @('chromium','firefox','webkit')) {
    if (!($browserDirectories | Where-Object { $_.Name -match ('^' + $engine + '-') })) {
      throw ('The Playwright ' + $engine + ' build was not found under playwright\browsers.')
    }
  }
  Write-Host ('Playwright browsers ready: ' + (($browserDirectories | ForEach-Object Name) -join ', '))
  $setupSucceeded = $true
} catch {
  $setupError = $_.Exception.Message
} finally {
  foreach ($name in $environmentNames) {
    [Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name],'Process')
  }
  [Net.ServicePointManager]::SecurityProtocol = $savedSecurityProtocol
  if ($setupSucceeded -and $stageRoot -and (Test-Path -LiteralPath $stageRoot)) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
  }
}

if ($setupError) {
  Write-Host ('SETUP FAILED: ' + $setupError) -ForegroundColor Red
  if ($stageRoot -and (Test-Path -LiteralPath $stageRoot)) { Write-Host ('Staging files were retained at: ' + $stageRoot) }
  exit 1
}

Write-Host 'PORTABLE QA SETUP PASS' -ForegroundColor Green
