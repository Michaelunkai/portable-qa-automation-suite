[CmdletBinding()]
param(
  [string]$TargetUrl,
  [string]$ApiBaseUrl,
  [string]$ApiCollection,
  [string]$ContractSchema,
  [string]$ConfigPath,
  [int]$VirtualUsers = 5,
  [int]$RampSeconds = 5,
  [int]$HoldSeconds = 10,
  [int]$ApiTimeoutMs = 5000,
  [int]$ApiMaxRequests = 1000,
  [int]$P95ThresholdMs = 1000,
  [int]$P99ThresholdMs = 2000,
  [double]$ErrorRateThresholdPercent = 1,
  [int]$MaxPages = 20,
  [int]$BrowserTimeoutMs = 600000,
  [string]$PerformanceMode = 'Smoke',
  [switch]$Continuous,
  [int]$PollSeconds = 300,
  [switch]$NonInteractive,
  [switch]$DryRun,
  [switch]$UpdateVisualBaseline,
  [switch]$SkipToolUpdates,
  [switch]$ExitCodeOnCompletion
)

$ErrorActionPreference = 'Stop'
$script:Root = [IO.Path]::GetFullPath($PSScriptRoot)
$script:Reports = Join-Path $script:Root 'reports'
$script:RunId = ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
$script:RunDir = Join-Path (Join-Path $script:Reports 'runs') $script:RunId
$script:RunStartedUtc = [DateTime]::UtcNow
$script:TargetUrl = $TargetUrl
$script:ApiBaseUrl = $ApiBaseUrl
$script:MockProcess = $null
$script:MockUrl = ''
$script:FatalError = ''
$script:ExitCode = 3
$script:FinalStatus = 'ERROR'
$script:SummaryPath = Join-Path $script:RunDir 'summary.txt'
$script:HtmlPath = Join-Path $script:RunDir 'report.html'
$script:OverallPath = Join-Path $script:RunDir 'overall_results.json'
$script:PublicScript = Join-Path $script:Root 'Ultimate-QA-Orchestrator.ps1'
$script:SavedCurrentDirectory = [Environment]::CurrentDirectory
$script:SavedLocation = Get-Location
$script:SavedOutputEncoding = $OutputEncoding
$script:SavedConsoleOutputEncoding = $null
$script:SavedConsoleInputEncoding = $null
$script:SavedEnvironment = @{}
$script:EnvironmentNames = @(
  'TEMP','TMP','USERPROFILE','APPDATA','LOCALAPPDATA','HOME','PATH',
  'NPM_CONFIG_CACHE','NPM_CONFIG_PREFIX','npm_config_userconfig',
  'PLAYWRIGHT_BROWSERS_PATH','NODE_PATH','QA_SUITE_ROOT','QA_RUN_ID',
  'QA_RUN_DIR','QA_TARGET_URL','QA_API_BASE_URL','QA_API_REPORT',
  'QA_API_COLLECTION','QA_API_SCHEMA_PATH','QA_API_TIMEOUT_MS','QA_API_MAX_REQUESTS',
  'QA_MAX_PAGES','QA_UPDATE_VISUAL_BASELINE','REPORT_DIR','PW_OUTPUT_DIR',
  'AXE_FRAGMENT_DIR','QA_PLAYWRIGHT_REPORT','QA_PLAYWRIGHT_STDOUT',
  'QA_PLAYWRIGHT_STDERR','QA_PLAYWRIGHT_OUTPUT_DIR','QA_PLAYWRIGHT_TIMEOUT_MS',
  'QA_BROWSER_TEST_TIMEOUT_MS','QA_NAVIGATION_TIMEOUT_MS','QA_K6_EXE','QA_K6_SCRIPT',
  'QA_K6_REPORT','QA_K6_STDOUT','QA_K6_STDERR','QA_K6_TIMEOUT_MS',
  'QA_PERFORMANCE_MODE','QA_VUS','QA_RAMP_SECONDS','QA_HOLD_SECONDS',
  'QA_P95_MS','QA_P99_MS','QA_ERROR_RATE_PERCENT','K6_SUMMARY_TREND_STATS',
  'QA_MOCK_PORT'
)
foreach ($name in [Environment]::GetEnvironmentVariables('Process').Keys) {
  if ($name -like 'QA_*' -and $script:EnvironmentNames -notcontains $name) { $script:EnvironmentNames += [string]$name }
}
foreach ($name in $script:EnvironmentNames) {
  $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name,'Process')
}
try { $script:SavedConsoleOutputEncoding = [Console]::OutputEncoding } catch {}
try { $script:SavedConsoleInputEncoding = [Console]::InputEncoding } catch {}

function Write-JsonAtomic([string]$Path,[object]$Value) {
  $directory = [IO.Path]::GetDirectoryName($Path)
  [IO.Directory]::CreateDirectory($directory) | Out-Null
  $temporary = $Path + '.tmp'
  $json = ConvertTo-Json -InputObject $Value -Depth 80
  [IO.File]::WriteAllText($temporary,$json + [Environment]::NewLine,[Text.UTF8Encoding]::new($false))
  if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary,$Path,$null) }
  else { [IO.File]::Move($temporary,$Path) }
}

function ConvertTo-ReportUrl([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  try {
    $builder = [UriBuilder]::new([Uri]$Value)
    if ($builder.UserName) { $builder.UserName = 'REDACTED' }
    if ($builder.Password) { $builder.Password = 'REDACTED' }
    $query = $builder.Query.TrimStart('?')
    if ($query) {
      $pairs = @()
      foreach ($part in ($query -split '&')) {
        $pieces = $part -split '=',2
        $key = [Uri]::UnescapeDataString($pieces[0])
        if ($key -match '(?i)token|key|secret|password|passwd|auth|session|code|signature') {
          $pairs += ($pieces[0] + '=REDACTED')
        } elseif ($pieces.Count -gt 1) {
          $pairs += ($pieces[0] + '=' + $pieces[1])
        } else {
          $pairs += $pieces[0]
        }
      }
      $builder.Query = ($pairs -join '&')
    }
    return $builder.Uri.AbsoluteUri
  } catch {
    return '[URL unavailable]'
  }
}

function ConvertTo-QuotedPowerShellString([string]$Value) {
  return ("'" + ([string]$Value).Replace("'","''") + "'")
}

function Get-JsonFile([string]$Path) {
  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { throw ('Required report was not created: ' + $Path) }
  return (Get-Content -Encoding UTF8 -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Get-PhaseStatus([object]$Value,[string]$Fallback='error') {
  if ($null -eq $Value) { return $Fallback }
  $status = [string]$Value.status
  if ($status -notin @('passed','failed','error','incomplete','skipped')) { return $Fallback }
  return $status
}

function Format-Number([object]$Value,[int]$Digits=1) {
  if ($null -eq $Value) { return 'n/a' }
  $number = [double]$Value
  if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { return 'n/a' }
  return $number.ToString(('F' + $Digits),[Globalization.CultureInfo]::InvariantCulture)
}

function Format-SummaryText([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  return [regex]::Replace(([string]$Value).Trim(),'[\r\n\t]+',' ')
}

function Get-ConciseRunnerMessage([string]$Message) {
  if ([string]::IsNullOrWhiteSpace($Message)) { return '' }
  $value = [regex]::Replace([string]$Message,'\s+\d+\s+\|\s.*$','')
  $value = [regex]::Replace($value,'\s+at\s+.*$','')
  return Format-SummaryText $value
}

function Get-OverallStatus([System.Collections.IDictionary]$Phases) {
  $statuses = @($Phases.Values | ForEach-Object { [string]$_.status })
  if ($statuses -contains 'error') { return 'ERROR' }
  if ($statuses -contains 'failed') { return 'FAIL' }
  if ($statuses -contains 'incomplete' -or $statuses -contains 'skipped' -or $statuses -contains 'not-run') { return 'INCOMPLETE' }
  return 'PASS'
}

function Get-RunSummaryLines([object]$Report) {
  $lines = New-Object 'System.Collections.Generic.List[string]'
  [void]$lines.Add('PORTABLE QA AUTOMATION')
  [void]$lines.Add(('QA RESULT: ' + $Report.status))
  [void]$lines.Add(('Run ID: ' + $Report.runId))
  [void]$lines.Add(('Target: ' + $Report.targetUrl))
  [void]$lines.Add(('Started (UTC): ' + $Report.startedUtc))
  [void]$lines.Add(('Duration: ' + (Format-Number $Report.durationSeconds 1) + ' seconds'))
  [void]$lines.Add('')
  [void]$lines.Add(('CAPABILITY'.PadRight(27) + 'RESULT'.PadRight(14) + 'DETAILS'))
  [void]$lines.Add(('HTTP / API'.PadRight(27) + ([string]$Report.phases.api.status).ToUpperInvariant().PadRight(14) + [string]$Report.phases.api.details))
  [void]$lines.Add(('Browser / navigation'.PadRight(27) + ([string]$Report.phases.browser.status).ToUpperInvariant().PadRight(14) + [string]$Report.phases.browser.details))
  [void]$lines.Add(('Accessibility'.PadRight(27) + ([string]$Report.phases.accessibility.status).ToUpperInvariant().PadRight(14) + [string]$Report.phases.accessibility.details))
  [void]$lines.Add(('Visual regression'.PadRight(27) + ([string]$Report.phases.visual.status).ToUpperInvariant().PadRight(14) + [string]$Report.phases.visual.details))
  [void]$lines.Add(('Performance'.PadRight(27) + ([string]$Report.phases.performance.status).ToUpperInvariant().PadRight(14) + [string]$Report.phases.performance.details))
  $browserProjects = @($Report.coverage.browserProjects | Where-Object { $_ } | Sort-Object -Unique)
  if ($browserProjects.Count) { [void]$lines.Add(('Browser projects: ' + ($browserProjects -join ', '))) }

  [void]$lines.Add('')
  $actionableFindings = @($Report.findings)
  [void]$lines.Add(('FINDINGS (' + $actionableFindings.Count + ' item(s); all reported items shown)'))
  if ($actionableFindings.Count -eq 0) {
    [void]$lines.Add('  No actionable findings from the checks that completed.')
  } else {
    foreach ($finding in $actionableFindings) {
      $severity = ([string]$finding.severity).ToUpperInvariant()
      $where = @()
      if ($finding.browser) { $where += [string]$finding.browser }
      if ($finding.request) { $where += [string]$finding.request }
      if ($null -ne $finding.status) { $where += ('HTTP ' + [string]$finding.status) }
      if ($finding.statusText) { $where += [string]$finding.statusText }
      if ($finding.target) { $where += ('target ' + [string]$finding.target) }
      if ($finding.test) { $where += ('test ' + [string]$finding.test) }
      if ($finding.url) { $where += [string]$finding.url }
      if ($finding.selector) { $where += ('selector ' + [string]$finding.selector) }
      $sourceLocations = @($finding.sourceLocations | Where-Object { $_ })
      if ($sourceLocations.Count -eq 1) { $where += ('source ' + [string]$sourceLocations[0]) }
      [void]$lines.Add(('  [' + $severity + '] ' + (Format-SummaryText ([string]$finding.title))))
      if ($where.Count) { [void]$lines.Add(('    ' + ($where -join ' | '))) }
      if ($finding.details) { [void]$lines.Add(('    ' + (Format-SummaryText ([string]$finding.details)))) }
      if ([int]$finding.occurrences -gt 1) { [void]$lines.Add(('    Observed in ' + [string]$finding.occurrences + ' unique browser/page location(s).')) }
      if ($sourceLocations.Count -gt 1) { [void]$lines.Add(('    ' + $sourceLocations.Count + ' source locations recorded in Browser data fragments.')) }
      if ($finding.baseline) { [void]$lines.Add(('    Baseline: ' + [string]$finding.baseline)) }
      if ($finding.screenshot) { [void]$lines.Add(('    Screenshot: ' + [string]$finding.screenshot)) }
      if ($finding.helpUrl) { [void]$lines.Add(('    Rule guidance: ' + [string]$finding.helpUrl)) }
      if ($finding.nextAction) { [void]$lines.Add(('    Action: ' + (Format-SummaryText ([string]$finding.nextAction)))) }
    }
  }

  [void]$lines.Add('')
  [void]$lines.Add('ACCESSIBILITY REVIEW')
  if ($null -eq $Report.accessibility) {
    [void]$lines.Add('  No accessibility report was produced.')
  } else {
    $violationOccurrences = [int]$Report.accessibility.violationOccurrences
    $violationGroups = @($Report.accessibility.violations).Count
    $incompleteItems = @($Report.accessibility.incomplete)
    [void]$lines.Add(('  Confirmed automated violations: ' + $violationOccurrences + ' node occurrence(s) across ' + $violationGroups + ' grouped finding(s).'))
    [void]$lines.Add(('  Incomplete checks requiring review: ' + $incompleteItems.Count + '. These are not confirmed violations.'))
    if ($incompleteItems.Count -gt 0) {
      $reviewGroups = @{}
      foreach ($item in $incompleteItems) {
        $check = [string]$item.check
        $rule = [string]$item.rule
        $impact = [string]$item.impact
        $help = [string]$item.help
        $message = [string]$item.message
        $key = [string]::Join([string][char]31,[string[]]@($check,$rule,$impact,$help,$message))
        if (!$reviewGroups.ContainsKey($key)) {
          $reviewGroups[$key] = [ordered]@{
            check = $check
            rule = $rule
            impact = $impact
            help = $help
            message = $message
            count = 0
            browsers = @()
            urls = @()
          }
        }
        $group = $reviewGroups[$key]
        $group.count = [int]$group.count + 1
        $browser = [string]$item.browser
        $url = [string]$item.url
        if ($browser -and @($group.browsers) -notcontains $browser) { $group.browsers = @($group.browsers) + $browser }
        if ($url -and @($group.urls) -notcontains $url) { $group.urls = @($group.urls) + $url }
      }
      foreach ($group in @($reviewGroups.Values | Sort-Object rule,check)) {
        $label = if ($group.rule) { [string]$group.rule } elseif ($group.check) { [string]$group.check } else { 'Unspecified accessibility check' }
        $impact = if ($group.impact) { [string]$group.impact } else { 'unspecified impact' }
        [void]$lines.Add(('  [' + $impact.ToUpperInvariant() + '] ' + $label + ' - incomplete in ' + [string]$group.count + ' browser/page check(s).'))
        if (@($group.browsers).Count) { [void]$lines.Add(('    Browsers: ' + ((@($group.browsers) | Sort-Object -Unique) -join ', '))) }
        if (@($group.urls).Count) { [void]$lines.Add(('    Pages: ' + ((@($group.urls) | Sort-Object -Unique) -join ', '))) }
        $guidance = if ($group.help) { [string]$group.help } else { [string]$group.message }
        if ($guidance) { [void]$lines.Add(('    Review: ' + (Format-SummaryText $guidance))) }
      }
    }
  }

  [void]$lines.Add('')
  [void]$lines.Add('COVERAGE AND LIMITS')
  foreach ($item in @($Report.coverage.notes)) { [void]$lines.Add(('  - ' + [string]$item)) }
  [void]$lines.Add('')
  [void]$lines.Add('EVIDENCE')
  $evidenceSpecs = @(
    [ordered]@{ key='htmlReport'; label='HTML report' },
    [ordered]@{ key='summary'; label='Text summary' },
    [ordered]@{ key='overall'; label='Full results' },
    [ordered]@{ key='api'; label='API results' },
    [ordered]@{ key='accessibility'; label='Accessibility report' },
    [ordered]@{ key='performance'; label='Performance report' },
    [ordered]@{ key='playwrightHtml'; label='Playwright browser report' },
    [ordered]@{ key='playwrightRunner'; label='Playwright runner results' },
    [ordered]@{ key='browserFragments'; label='Browser data fragments' },
    [ordered]@{ key='screenshots'; label='Screenshots' },
    [ordered]@{ key='logs'; label='Logs' }
  )
  foreach ($spec in $evidenceSpecs) {
    $key = [string]$spec.key
    $value = $null
    if ($Report.evidence -is [System.Collections.IDictionary]) { $value = $Report.evidence[$key] }
    elseif ($null -ne $Report.evidence) {
      $property = $Report.evidence.PSObject.Properties[$key]
      if ($property) { $value = $property.Value }
    }
    if ($value) { [void]$lines.Add(('  ' + [string]$spec.label + ': ' + [string]$value)) }
  }
  $traceFiles = @()
  $videoFiles = @()
  if ($null -ne $Report.evidence) {
    $traceValue = if ($Report.evidence -is [System.Collections.IDictionary]) { [string]$Report.evidence['traces'] } else { [string]$Report.evidence.traces }
    $videoValue = if ($Report.evidence -is [System.Collections.IDictionary]) { [string]$Report.evidence['videos'] } else { [string]$Report.evidence.videos }
    $traceFiles = @($traceValue -split ';' | Where-Object { ![string]::IsNullOrWhiteSpace($_) })
    $videoFiles = @($videoValue -split ';' | Where-Object { ![string]::IsNullOrWhiteSpace($_) })
  }
  $summaryPathValue = if ($Report.evidence -is [System.Collections.IDictionary]) { [string]$Report.evidence['summary'] } elseif ($Report.evidence) { [string]$Report.evidence.summary } else { '' }
  $runDirectory = if ($summaryPathValue) { [IO.Path]::GetDirectoryName($summaryPathValue) } else { [string]$script:RunDir }
  if ($traceFiles.Count) { [void]$lines.Add(('  browser traces: ' + $traceFiles.Count + ' file(s) under ' + (Join-Path $runDirectory 'playwright-output'))) }
  if ($videoFiles.Count) { [void]$lines.Add(('  Videos: ' + $videoFiles.Count + ' file(s) under ' + $runDirectory + ' (Playwright output and HTML report data)')) }
  if ($traceFiles.Count -or $videoFiles.Count) { [void]$lines.Add('  Open overall_results.json for the complete artifact inventory.') }
  [void]$lines.Add('')
  [void]$lines.Add('RERUN')
  [void]$lines.Add('  ' + [string]$Report.rerunCommand)
  $asciiLines = foreach ($line in $lines) {
    $value = [string]$line
    $value = $value.Replace([string][char]0x2018,"'").Replace([string][char]0x2019,"'")
    $value = $value.Replace([string][char]0x201C,'"').Replace([string][char]0x201D,'"')
    $value = $value.Replace([string][char]0x2013,'-').Replace([string][char]0x2014,'-').Replace([string][char]0x2026,'...')
    $value = $value.Replace([string][char]0x00A0,' ')
    [regex]::Replace($value,'[^\x20-\x7E]','?')
  }
  return $asciiLines
}

function Get-ReportValue([object]$Object,[string]$Name) {
  if ($null -eq $Object) { return $null }
  if ($Object -is [System.Collections.IDictionary]) {
    if ($Object.Contains($Name)) { return $Object[$Name] }
    return $null
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($property) { return $property.Value }
  return $null
}

function ConvertTo-HtmlText([object]$Value) {
  if ($null -eq $Value) { return '' }
  return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-HtmlStatusClass([string]$Value) {
  switch ($Value.ToLowerInvariant()) {
    { $_ -in @('pass','passed') } { return 'good' }
    { $_ -in @('fail','failed','error') } { return 'bad' }
    { $_ -in @('incomplete','skipped','not-run') } { return 'warn' }
    default { return 'neutral' }
  }
}

function Get-ReportHref([string]$Path,[string]$LinkBase) {
  if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($LinkBase)) { return '' }
  try {
    $basePath = [IO.Path]::GetFullPath($LinkBase).TrimEnd([char[]]@([char]92,[char]47)) + [IO.Path]::DirectorySeparatorChar
    $baseUri = [Uri]::new($basePath)
    $targetUri = [Uri]::new([IO.Path]::GetFullPath($Path))
    return $baseUri.MakeRelativeUri($targetUri).ToString()
  } catch { return '' }
}

function Get-RunHtmlReport([object]$Report,[string]$LinkBase) {
  if ([string]::IsNullOrWhiteSpace($LinkBase)) {
    $summaryValue = [string](Get-ReportValue $Report.evidence 'summary')
    if ($summaryValue) { $LinkBase = [IO.Path]::GetDirectoryName($summaryValue) } else { $LinkBase = [string]$script:RunDir }
  }
  $html = New-Object System.Text.StringBuilder
  $status = [string](Get-ReportValue $Report 'status')
  $statusClass = Get-HtmlStatusClass $status
  $target = [string](Get-ReportValue $Report 'targetUrl')
  $targetHtml = ConvertTo-HtmlText $target
  $targetHref = ''
  try {
    $targetUri = [Uri]::new($target)
    if ($targetUri.IsAbsoluteUri -and $targetUri.Scheme -in @('http','https')) { $targetHref = $targetUri.AbsoluteUri }
  } catch { }
  $findings = @((Get-ReportValue $Report 'findings'))
  $coverage = Get-ReportValue $Report 'coverage'
  $accessibility = Get-ReportValue $Report 'accessibility'
  $incomplete = @((Get-ReportValue $accessibility 'incomplete'))
  $violationCount = [int](Get-ReportValue $accessibility 'violationOccurrences')
  $pagesVisited = [int](Get-ReportValue $coverage 'pagesVisited')
  $browserProjectCount = [int](Get-ReportValue $coverage 'browserProjectCount')
  $runId = ConvertTo-HtmlText (Get-ReportValue $Report 'runId')
  $duration = ConvertTo-HtmlText ((Format-Number (Get-ReportValue $Report 'durationSeconds') 1) + ' seconds')
  $verdictText = switch ($status.ToUpperInvariant()) {
    'PASS' { 'All configured checks passed for the coverage listed below.' }
    'FAIL' { 'One or more configured checks found issues that need attention.' }
    'INCOMPLETE' { 'Some checks passed, but coverage is missing or needs human review.' }
    default { 'The run could not complete because setup or a test component failed.' }
  }
  [void]$html.AppendLine('<!doctype html>')
  [void]$html.AppendLine('<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">')
  [void]$html.AppendLine('<title>QA report - ' + $runId + '</title>')
  [void]$html.AppendLine('<style>')
  [void]$html.AppendLine(':root{color-scheme:light;--ink:#17243a;--muted:#607089;--line:#dce4ef;--surface:#fff;--canvas:#f3f6fb;--blue:#3156a6;--green:#16794b;--red:#b42318;--amber:#9a6700}*{box-sizing:border-box}body{margin:0;background:var(--canvas);color:var(--ink);font:15px/1.55 "Segoe UI",Arial,sans-serif}.wrap{max-width:1120px;margin:0 auto;padding:32px 22px 56px}.hero{padding:30px 34px;border-radius:20px;background:linear-gradient(125deg,#15294b,#3156a6);color:#fff;box-shadow:0 16px 40px #1c31521c}.eyebrow{text-transform:uppercase;letter-spacing:.14em;font-size:12px;font-weight:700;opacity:.76}.hero h1{margin:7px 0 4px;font-size:30px;line-height:1.2}.hero a{color:#dbeafe;overflow-wrap:anywhere}.hero p{margin:8px 0;color:#e6edf9}.verdict{display:inline-flex;align-items:center;margin-top:14px;padding:7px 12px;border-radius:999px;background:#ffffff20;border:1px solid #ffffff55;font-weight:800;letter-spacing:.04em}.meta{font-size:13px;opacity:.82}.metrics{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:14px;margin:20px 0}.metric,.panel,.phase,.finding{background:var(--surface);border:1px solid var(--line);border-radius:14px;box-shadow:0 4px 16px #1d35570a}.metric{padding:17px 18px}.metric strong{display:block;font-size:25px;line-height:1.2}.metric span{display:block;margin-top:5px;color:var(--muted);font-size:13px}.panel{padding:23px 25px;margin:16px 0}.panel h2{margin:0 0 14px;font-size:20px}.phase-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}.phase{padding:15px 16px;box-shadow:none}.phase-top{display:flex;justify-content:space-between;align-items:center;gap:12px}.phase h3{margin:0;font-size:16px}.phase p{margin:8px 0 0;color:var(--muted)}.badge{display:inline-flex;align-items:center;padding:3px 9px;border-radius:999px;font-size:11px;font-weight:800;letter-spacing:.05em;text-transform:uppercase;white-space:nowrap}.good{background:#e8f6ee;color:var(--green)}.bad{background:#fff0ef;color:var(--red)}.warn{background:#fff6dc;color:var(--amber)}.neutral{background:#edf1f7;color:#475467}.finding-list{display:grid;gap:11px}.finding{padding:16px 18px;border-left:4px solid #b42318;box-shadow:none}.finding.warning{border-left-color:#c38700}.finding h3{display:flex;align-items:center;gap:9px;margin:0 0 7px;font-size:16px}.finding p{margin:6px 0;overflow-wrap:anywhere}.where,.quiet{color:var(--muted);font-size:13px}.action{margin-top:10px!important;padding:10px 12px;background:#f5f7fb;border-radius:9px}.empty{padding:15px;border-radius:10px;background:#e8f6ee;color:var(--green)}ul{padding-left:22px}li{margin:7px 0}details{margin:10px 0}summary{cursor:pointer;font-weight:700}code,pre{font-family:Consolas,"Cascadia Code",monospace}code{overflow-wrap:anywhere}.evidence{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:9px}.evidence a{display:block;padding:11px 13px;border:1px solid var(--line);border-radius:10px;background:#fff;color:var(--blue);text-decoration:none;overflow-wrap:anywhere}.evidence a:hover{text-decoration:underline;background:#f7f9fe}.evidence small{display:block;margin-top:3px;color:var(--muted)}pre{padding:14px;background:#f5f7fb;border:1px solid var(--line);border-radius:10px;white-space:pre-wrap;overflow-wrap:anywhere}footer{margin-top:23px;color:var(--muted);font-size:12px}@media(max-width:720px){.wrap{padding:16px 12px 36px}.hero{padding:23px 20px}.hero h1{font-size:25px}.metrics{grid-template-columns:repeat(2,minmax(0,1fr))}.phase-grid,.evidence{grid-template-columns:1fr}.panel{padding:19px 17px}}@media print{body{background:#fff}.wrap{max-width:none;padding:0}.hero{box-shadow:none}.metric,.panel,.phase,.finding{box-shadow:none;break-inside:avoid}a{color:inherit}}</style></head><body><main class="wrap">')
  [void]$html.AppendLine('<header class="hero"><div class="eyebrow">Portable QA Automation</div><h1>Website test report</h1>')
  [void]$html.AppendLine('<div class="verdict ' + $statusClass + '">' + (ConvertTo-HtmlText $status) + '</div><p>' + (ConvertTo-HtmlText $verdictText) + '</p>')
  if ($targetHref) { [void]$html.AppendLine('<p>Target: <a href="' + (ConvertTo-HtmlText $targetHref) + '" target="_blank" rel="noopener">' + $targetHtml + '</a></p>') }
  elseif ($targetHtml) { [void]$html.AppendLine('<p>Target: ' + $targetHtml + '</p>') }
  [void]$html.AppendLine('<p class="meta">Run ' + $runId + ' &middot; ' + $duration + ' &middot; Started ' + (ConvertTo-HtmlText (Get-ReportValue $Report 'startedUtc')) + '</p></header>')
  [void]$html.AppendLine('<section class="metrics" aria-label="Run totals"><div class="metric"><strong>' + $findings.Count + '</strong><span>reported finding(s)</span></div>')
  [void]$html.AppendLine('<div class="metric"><strong>' + $pagesVisited + '</strong><span>page visit(s)</span></div><div class="metric"><strong>' + $browserProjectCount + '</strong><span>browser / viewport project(s)</span></div>')
  [void]$html.AppendLine('<div class="metric"><strong>' + $violationCount + ' / ' + $incomplete.Count + '</strong><span>confirmed accessibility violations / checks needing review</span></div></section>')
  [void]$html.AppendLine('<section class="panel"><h2>What was tested</h2><div class="phase-grid">')
  $phaseSpecs = @(
    [ordered]@{ label='HTTP and API'; key='api' },
    [ordered]@{ label='Browser and navigation'; key='browser' },
    [ordered]@{ label='Accessibility'; key='accessibility' },
    [ordered]@{ label='Visual regression'; key='visual' },
    [ordered]@{ label='Performance'; key='performance' }
  )
  foreach ($spec in $phaseSpecs) {
    $phase = Get-ReportValue (Get-ReportValue $Report 'phases') ([string]$spec.key)
    $phaseStatus = if ($phase) { [string](Get-ReportValue $phase 'status') } else { 'not-run' }
    $phaseDetails = if ($phase) { [string](Get-ReportValue $phase 'details') } else { 'No result was recorded for this phase.' }
    [void]$html.AppendLine('<article class="phase"><div class="phase-top"><h3>' + (ConvertTo-HtmlText $spec.label) + '</h3><span class="badge ' + (Get-HtmlStatusClass $phaseStatus) + '">' + (ConvertTo-HtmlText $phaseStatus) + '</span></div><p>' + (ConvertTo-HtmlText $phaseDetails) + '</p></article>')
  }
  [void]$html.AppendLine('</div></section><section class="panel"><h2>Findings</h2>')
  if ($findings.Count -eq 0) { [void]$html.AppendLine('<p class="empty">No findings were reported by the checks that completed.</p>') }
  else {
    [void]$html.AppendLine('<div class="finding-list">')
    foreach ($finding in $findings) {
      $severity = [string](Get-ReportValue $finding 'severity')
      $severityClass = Get-HtmlStatusClass $severity
      if ($severity.ToLowerInvariant() -eq 'warning') { $severityClass = 'warn' }
      $phaseName = [string](Get-ReportValue $finding 'phase')
      $title = [string](Get-ReportValue $finding 'title')
      $locations = @()
      foreach ($name in @('browser','request','test','selector')) {
        $part = [string](Get-ReportValue $finding $name)
        if ($part) { $locations += $part }
      }
      $code = Get-ReportValue $finding 'status'
      if ($null -ne $code) { $locations += ('HTTP ' + [string]$code) }
      $url = [string](Get-ReportValue $finding 'url')
      if ($url) { $locations += $url }
      $details = [string](Get-ReportValue $finding 'details')
      $nextAction = [string](Get-ReportValue $finding 'nextAction')
      $findingClass = if ($severity.ToLowerInvariant() -eq 'warning') { 'finding warning' } else { 'finding' }
      [void]$html.AppendLine('<article class="' + $findingClass + '"><h3><span class="badge ' + $severityClass + '">' + (ConvertTo-HtmlText $severity) + '</span>' + (ConvertTo-HtmlText $title) + '</h3>')
      if ($phaseName -or $locations.Count) { [void]$html.AppendLine('<p class="where">' + (ConvertTo-HtmlText $phaseName) + $(if ($locations.Count) { ' &middot; ' + (ConvertTo-HtmlText ($locations -join ' | ')) } else { '' }) + '</p>') }
      if ($details) { [void]$html.AppendLine('<p>' + (ConvertTo-HtmlText $details) + '</p>') }
      if ($null -ne (Get-ReportValue $finding 'occurrences') -and [int](Get-ReportValue $finding 'occurrences') -gt 1) { [void]$html.AppendLine('<p class="quiet">Observed ' + [string](Get-ReportValue $finding 'occurrences') + ' time(s) across the listed browser/page locations.</p>') }
      $sourceLocations = @((Get-ReportValue $finding 'sourceLocations') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
      if ($sourceLocations.Count) {
        [void]$html.AppendLine('<details><summary>' + $sourceLocations.Count + ' source location(s)</summary><ul>')
        foreach ($sourceLocation in $sourceLocations) { [void]$html.AppendLine('<li><code>' + (ConvertTo-HtmlText $sourceLocation) + '</code></li>') }
        [void]$html.AppendLine('</ul></details>')
      }
      if ($nextAction) { [void]$html.AppendLine('<p class="action"><strong>Suggested next step:</strong> ' + (ConvertTo-HtmlText $nextAction) + '</p>') }
      foreach ($name in @('screenshot','baseline')) {
        $pathValue = [string](Get-ReportValue $finding $name)
        if ($pathValue) {
          $href = Get-ReportHref $pathValue $LinkBase
          if ($href) { [void]$html.AppendLine('<p><a href="' + (ConvertTo-HtmlText $href) + '">' + (ConvertTo-HtmlText $name) + ': ' + (ConvertTo-HtmlText $pathValue) + '</a></p>') }
        }
      }
      $helpUrl = [string](Get-ReportValue $finding 'helpUrl')
      try {
        $helpUri = [Uri]::new($helpUrl)
        if ($helpUri.IsAbsoluteUri -and $helpUri.Scheme -in @('http','https')) { [void]$html.AppendLine('<p><a href="' + (ConvertTo-HtmlText $helpUri.AbsoluteUri) + '" target="_blank" rel="noopener">Rule guidance</a></p>') }
      } catch { }
      [void]$html.AppendLine('</article>')
    }
    [void]$html.AppendLine('</div>')
  }
  [void]$html.AppendLine('</section><section class="panel"><h2>Accessibility review</h2>')
  if ($null -eq $accessibility) { [void]$html.AppendLine('<p>No accessibility report was produced.</p>') }
  else {
    [void]$html.AppendLine('<p><strong>' + $violationCount + '</strong> confirmed automated violation occurrence(s). <strong>' + $incomplete.Count + '</strong> check(s) need review; incomplete checks are not confirmed violations.</p>')
    if ($incomplete.Count) {
      [void]$html.AppendLine('<details><summary>Review ' + $incomplete.Count + ' incomplete accessibility check(s)</summary><ul>')
      foreach ($item in $incomplete) {
        $label = [string](Get-ReportValue $item 'rule')
        if (!$label) { $label = [string](Get-ReportValue $item 'check') }
        if (!$label) { $label = [string](Get-ReportValue $item 'id') }
        $impact = [string](Get-ReportValue $item 'impact')
        $help = [string](Get-ReportValue $item 'help')
        $browsers = Get-ReportValue $item 'browsers'
        if (!$browsers) { $browsers = Get-ReportValue $item 'browser' }
        $urls = Get-ReportValue $item 'urls'
        if (!$urls) { $urls = Get-ReportValue $item 'url' }
        $scope = @()
        if ($browsers) { $scope += ('Browsers: ' + (@($browsers) -join ', ')) }
        if ($urls) { $scope += ('Pages: ' + (@($urls) -join ', ')) }
        $reviewText = if ($impact) { '[' + $impact.ToUpperInvariant() + '] ' } else { '' }
        $reviewText += $label
        if ($help) { $reviewText += ' - ' + $help }
        if ($scope.Count) { $reviewText += ' (' + ($scope -join '; ') + ')' }
        [void]$html.AppendLine('<li>' + (ConvertTo-HtmlText $reviewText) + '</li>')
      }
      [void]$html.AppendLine('</ul></details>')
    }
  }
  [void]$html.AppendLine('</section><section class="panel"><h2>Coverage and limits</h2>')
  $notes = @((Get-ReportValue $coverage 'notes'))
  if ($notes.Count) { [void]$html.AppendLine('<ul>'); foreach ($note in $notes) { [void]$html.AppendLine('<li>' + (ConvertTo-HtmlText $note) + '</li>') }; [void]$html.AppendLine('</ul>') }
  else { [void]$html.AppendLine('<p>No additional coverage notes were recorded.</p>') }
  [void]$html.AppendLine('</section><section class="panel"><h2>Evidence</h2><div class="evidence">')
  $evidence = Get-ReportValue $Report 'evidence'
  $reportEvidenceSpecs = @(
    [ordered]@{ label='HTML report'; key='htmlReport' },
    [ordered]@{ label='Text summary'; key='summary' },
    [ordered]@{ label='Full results (JSON)'; key='overall' },
    [ordered]@{ label='API results (JSON)'; key='api' },
    [ordered]@{ label='Accessibility results (JSON)'; key='accessibility' },
    [ordered]@{ label='Performance results (JSON)'; key='performance' },
    [ordered]@{ label='Playwright browser report'; key='playwrightHtml' },
    [ordered]@{ label='Playwright runner results'; key='playwrightRunner' },
    [ordered]@{ label='Browser data fragments'; key='browserFragments' },
    [ordered]@{ label='Screenshots'; key='screenshots' },
    [ordered]@{ label='Logs'; key='logs' }
  )
  foreach ($spec in $reportEvidenceSpecs) {
    $pathValue = [string](Get-ReportValue $evidence ([string]$spec.key))
    if (!$pathValue) { continue }
    $href = Get-ReportHref $pathValue $LinkBase
    if ($href) { [void]$html.AppendLine('<a href="' + (ConvertTo-HtmlText $href) + '">' + (ConvertTo-HtmlText $spec.label) + '<small>' + (ConvertTo-HtmlText $pathValue) + '</small></a>') }
    else { [void]$html.AppendLine('<div><strong>' + (ConvertTo-HtmlText $spec.label) + '</strong><small>' + (ConvertTo-HtmlText $pathValue) + '</small></div>') }
  }
  [void]$html.AppendLine('</div>')
  $rerun = [string](Get-ReportValue $Report 'rerunCommand')
  if ($rerun) { [void]$html.AppendLine('<details><summary>Rerun this check</summary><pre>' + (ConvertTo-HtmlText $rerun) + '</pre></details>') }
  [void]$html.AppendLine('</section><footer>Automated results describe only the checks and pages listed in this report. Review incomplete checks and validate important user workflows separately.</footer></main></body></html>')
  return $html.ToString()
}

function Write-RunHtmlReport([object]$Report,[string]$OutputPath,[string]$LinkBase) {
  if ([string]::IsNullOrWhiteSpace($OutputPath)) { return }
  $content = Get-RunHtmlReport $Report $LinkBase
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($OutputPath))) | Out-Null
  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  [IO.File]::WriteAllText($OutputPath,$content,$utf8NoBom)
}

function Write-RunSummary([object]$Report) {
  $lines = Get-RunSummaryLines $Report
  $content = ($lines -join [Environment]::NewLine) + [Environment]::NewLine
  [IO.File]::WriteAllText([string]$Report.evidence.summary,$content,[Text.Encoding]::ASCII)
  $htmlPath = [string](Get-ReportValue $Report.evidence 'htmlReport')
  if (!$htmlPath) { $htmlPath = Join-Path ([IO.Path]::GetDirectoryName([string]$Report.evidence.summary)) 'report.html' }
  Write-RunHtmlReport $Report $htmlPath ([IO.Path]::GetDirectoryName($htmlPath))
  foreach ($line in $lines) { Write-Host $line }
}

function Save-ChildLog([string]$Path,[object[]]$Output) {
  $text = (@($Output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
  [IO.File]::WriteAllText($Path,$text,[Text.UTF8Encoding]::new($false))
}

function Get-BrowserFragments([string]$Directory) {
  $fragments = @()
  if (!(Test-Path -LiteralPath $Directory -PathType Container)) { return $fragments }
  foreach ($path in [IO.Directory]::EnumerateFiles($Directory,'*.json',[IO.SearchOption]::TopDirectoryOnly)) {
    try { $fragments += Get-Content -Encoding UTF8 -LiteralPath $path -Raw | ConvertFrom-Json }
    catch { $script:FatalError = 'Could not read accessibility evidence ' + $path + ': ' + $_.Exception.Message }
  }
  return ,$fragments
}

function New-A11yFindings([object[]]$Audits) {
  $groups = @{}
  foreach ($audit in $Audits) {
    foreach ($violation in @($audit.violations)) {
      foreach ($node in @($violation.nodes)) {
        $selector = (@($node.target) -join ', ')
        if (!$selector) { $selector = '[selector unavailable]' }
        $key = (([string]$violation.id + '|' + [string]$violation.impact + '|' + $selector).ToLowerInvariant())
        if (!$groups.ContainsKey($key)) {
          $groups[$key] = [ordered]@{
            severity = [string]$violation.impact
            phase = 'accessibility'
            title = ([string]$violation.id + ' (' + [string]$violation.impact + ')')
            rule = [string]$violation.id
            selector = $selector
            help = [string]$violation.help
            helpUrl = [string]$violation.helpUrl
            details = [string]$node.failureSummary
            occurrences = 0
            locations = @()
            nextAction = ''
          }
        }
        $group = $groups[$key]
        $group.occurrences = [int]$group.occurrences + 1
        $location = ([string]$audit.browser + ' ' + [string]$audit.url)
        if (@($group.locations) -notcontains $location) { $group.locations += $location }
        if (!$group.details -and $node.failureSummary) { $group.details = [string]$node.failureSummary }
        if ([string]$violation.id -eq 'color-contrast') {
          $group.nextAction = 'Adjust foreground and background colors to meet WCAG contrast guidance: 4.5:1 for normal text and 3:1 for large text; recheck the affected component.'
        } else {
          $group.nextAction = ('Review the affected node against the rule guidance at ' + [string]$violation.helpUrl)
        }
      }
    }
  }
  return ,@($groups.Values)
}

function Invoke-QARun {
  $script:RunId = ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
  $script:RunStartedUtc = [DateTime]::UtcNow
  $script:RunDir = Join-Path (Join-Path $script:Reports 'runs') $script:RunId
  $script:SummaryPath = Join-Path $script:RunDir 'summary.txt'
  $script:HtmlPath = Join-Path $script:RunDir 'report.html'
  $script:OverallPath = Join-Path $script:RunDir 'overall_results.json'
  $logs = Join-Path $script:RunDir 'logs'
  $fragmentDir = Join-Path (Join-Path $script:RunDir 'accessibility') 'fragments'
  $playOutput = Join-Path $script:RunDir 'playwright-output'
  $screenshots = Join-Path $script:RunDir 'screenshots'
  $apiPath = Join-Path $script:RunDir 'api_results.json'
  $a11yPath = Join-Path $script:RunDir 'a11y_results.json'
  $performancePath = Join-Path $script:RunDir 'performance_results.json'
  $playwrightPath = Join-Path $script:RunDir 'playwright-results.json'
  $playwrightRunnerPath = Join-Path $script:RunDir 'playwright-runner.json'
  $htmlReport = Join-Path (Join-Path $script:RunDir 'playwright-html') 'index.html'
  $phase = [ordered]@{
    api = [ordered]@{ status='not-run'; details='Not started.' }
    browser = [ordered]@{ status='not-run'; details='Not started.' }
    accessibility = [ordered]@{ status='not-run'; details='Not started.' }
    visual = [ordered]@{ status='not-run'; details='Not started.' }
    performance = [ordered]@{ status='not-run'; details='Not started.' }
  }
  $findings = @()
  $audits = @()
  $fragments = @()
  $apiResult = $null
  $browserResult = $null
  $performanceResult = $null
  $a11yResult = $null
  $executionError = ''
  $runtimeVersions = [ordered]@{}
  $coverageNotes = @(
    'Browser testing uses Chromium, Firefox, WebKit, and a Chromium mobile viewport emulation; it is not native mobile or desktop application testing.',
    'The crawl covers same-origin links visited up to MaxPages. It does not prove authenticated permissions or application-specific business workflows unless those are supplied as tests.',
    'Visual results are compared only when an explicit target-and-route baseline exists. A missing baseline is reported as not compared.',
    'Accessibility automation reports machine-detectable WCAG checks; incomplete axe checks and human review items remain separate evidence.',
    'No dedicated penetration test, native-device test, or production-capacity test is performed by this suite.'
  )

  try {
    foreach ($directory in @($script:RunDir,$logs,$fragmentDir,$playOutput,$screenshots)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    $play = Join-Path $script:Root 'playwright'
    $newman = Join-Path $script:Root 'postman-cli'
    $k6 = Join-Path $script:Root 'k6'
    $node = Join-Path $play 'node.exe'
    $apiRunner = Join-Path $newman 'qa-newman-runner.js'
    $browserRunner = Join-Path $play 'qa-playwright-runner.js'
    $k6Runner = Join-Path $k6 'qa-k6-runner.js'
    $k6Script = Join-Path $k6 'performance.js'

    foreach ($requiredPath in @($node,$apiRunner,$browserRunner,(Join-Path $play 'playwright.config.js'),
      (Join-Path $play 'tests\qa.spec.js'),(Join-Path $play 'node_modules\@playwright\test\cli.js'),
      (Join-Path $script:Root 'k6-axe-a11y\node_modules\@axe-core\playwright\package.json'),
      (Join-Path $newman 'node_modules\newman\package.json'))) {
      if (!(Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw ('Required portable QA component is missing: ' + $requiredPath) }
    }
    $k6Exe = Join-Path $k6 'k6.exe'
    if ($PerformanceMode -ne 'Skip' -and !(Test-Path -LiteralPath $k6Exe -PathType Leaf)) { throw ('k6 runtime is missing: ' + $k6Exe) }
    if (![Uri]::IsWellFormedUriString($script:TargetUrl,[UriKind]::Absolute) -or !($script:TargetUrl.StartsWith('http://') -or $script:TargetUrl.StartsWith('https://'))) {
      throw 'TargetUrl must be an absolute HTTP or HTTPS URL.'
    }
    if ($script:ApiBaseUrl -and (![Uri]::IsWellFormedUriString($script:ApiBaseUrl,[UriKind]::Absolute) -or !($script:ApiBaseUrl.StartsWith('http://') -or $script:ApiBaseUrl.StartsWith('https://')))) {
      throw 'ApiBaseUrl must be an absolute HTTP or HTTPS URL.'
    }
    if ($PerformanceMode -notin @('Smoke','Load','Skip')) { throw 'PerformanceMode must be Smoke, Load, or Skip.' }
    if ($VirtualUsers -lt 1 -or $VirtualUsers -gt 50) { throw 'VirtualUsers must be between 1 and 50.' }
    if ($RampSeconds -lt 1 -or $RampSeconds -gt 300 -or $HoldSeconds -lt 1 -or $HoldSeconds -gt 300) { throw 'RampSeconds and HoldSeconds must each be between 1 and 300.' }
    if ($PerformanceMode -eq 'Load' -and (2 * $RampSeconds + $HoldSeconds) -gt 180) { throw 'The configured load test may run no longer than 180 seconds, excluding graceful stop.' }
    if ($PerformanceMode -eq 'Load' -and ($VirtualUsers * (2 * $RampSeconds + $HoldSeconds + 2)) -gt 10000) { throw 'The configured load exceeds the bounded 10000-request estimate. Reduce VUs or duration.' }
    if ($ApiTimeoutMs -lt 100 -or $ApiTimeoutMs -gt 600000) { throw 'ApiTimeoutMs must be between 100 and 600000.' }
    if ($ApiMaxRequests -lt 1 -or $ApiMaxRequests -gt 10000) { throw 'ApiMaxRequests must be between 1 and 10000.' }
    if ($P95ThresholdMs -lt 1 -or $P99ThresholdMs -lt $P95ThresholdMs -or $P99ThresholdMs -gt 600000) { throw 'Latency thresholds must be positive and P99ThresholdMs must be greater than or equal to P95ThresholdMs.' }
    if ($ErrorRateThresholdPercent -lt 0 -or $ErrorRateThresholdPercent -gt 10) { throw 'ErrorRateThresholdPercent must be between 0 and 10 percent.' }
    if ($MaxPages -lt 1 -or $MaxPages -gt 500) { throw 'MaxPages must be between 1 and 500.' }
    if ($BrowserTimeoutMs -lt 10000 -or $BrowserTimeoutMs -gt 1800000) { throw 'BrowserTimeoutMs must be between 10000 and 1800000.' }
    if ($Continuous -and ($PollSeconds -lt 1 -or $PollSeconds -gt 86400)) { throw 'PollSeconds must be between 1 and 86400.' }
    if ($ContractSchema -and !$script:ApiBaseUrl -and !$ApiCollection) { throw 'ContractSchema requires an API endpoint or Postman collection.' }
    if ($ApiCollection) { $ApiCollection = [IO.Path]::GetFullPath($ApiCollection) }
    if ($ContractSchema) { $ContractSchema = [IO.Path]::GetFullPath($ContractSchema) }
    if ($ApiCollection -and !(Test-Path -LiteralPath $ApiCollection -PathType Leaf)) { throw ('Postman collection was not found: ' + $ApiCollection) }
    if ($ContractSchema -and !(Test-Path -LiteralPath $ContractSchema -PathType Leaf)) { throw ('Contract schema was not found: ' + $ContractSchema) }

    $runtimeVersions.node = ((& $node '--version') -join '').Trim()
    $runtimeVersions.playwright = (Get-Content -Encoding UTF8 -LiteralPath (Join-Path $play 'node_modules\playwright\package.json') -Raw | ConvertFrom-Json).version
    $runtimeVersions.axePlaywright = (Get-Content -Encoding UTF8 -LiteralPath (Join-Path $script:Root 'k6-axe-a11y\node_modules\@axe-core\playwright\package.json') -Raw | ConvertFrom-Json).version
    $runtimeVersions.newman = (Get-Content -Encoding UTF8 -LiteralPath (Join-Path $newman 'node_modules\newman\package.json') -Raw | ConvertFrom-Json).version
    if ($PerformanceMode -ne 'Skip') { $runtimeVersions.k6 = ((& $k6Exe 'version') -join '').Trim() }

    $script:TargetUrl = [Uri]::new($script:TargetUrl).AbsoluteUri
    if ($script:ApiBaseUrl) { $script:ApiBaseUrl = [Uri]::new($script:ApiBaseUrl).AbsoluteUri }
    $env:QA_SUITE_ROOT = $script:Root
    $env:QA_RUN_ID = $script:RunId
    $env:QA_RUN_DIR = $script:RunDir
    $env:QA_TARGET_URL = $script:TargetUrl
    $env:QA_API_BASE_URL = $script:ApiBaseUrl
    $env:QA_MAX_PAGES = [string]$MaxPages
    $env:QA_UPDATE_VISUAL_BASELINE = if ($UpdateVisualBaseline) { '1' } else { '0' }
    $env:TEMP = Join-Path (Join-Path $script:Root 'tmp\state') 'temp'
    $env:TMP = $env:TEMP
    $env:USERPROFILE = Join-Path (Join-Path $script:Root 'tmp\state') 'userprofile'
    $env:APPDATA = Join-Path (Join-Path $script:Root 'tmp\state') 'AppData\Roaming'
    $env:LOCALAPPDATA = Join-Path (Join-Path $script:Root 'tmp\state') 'AppData\Local'
    $env:HOME = Join-Path (Join-Path $script:Root 'tmp\state') 'home'
    $env:NPM_CONFIG_CACHE = Join-Path (Join-Path $script:Root 'tmp') 'npm-cache'
    $env:NPM_CONFIG_PREFIX = Join-Path $play 'npm-global'
    $env:npm_config_userconfig = Join-Path $env:USERPROFILE '.npmrc'
    $env:PLAYWRIGHT_BROWSERS_PATH = Join-Path $play 'browsers'
    $env:NODE_PATH = Join-Path $play 'node_modules'
    $env:PATH = $play + ';' + $env:PATH
    foreach ($path in @($env:TEMP,$env:USERPROFILE,$env:APPDATA,$env:LOCALAPPDATA,$env:HOME,$env:NPM_CONFIG_CACHE,$env:NPM_CONFIG_PREFIX,$env:PLAYWRIGHT_BROWSERS_PATH,$env:NODE_PATH)) {
      [IO.Directory]::CreateDirectory($path) | Out-Null
    }
    $utf8 = [Text.UTF8Encoding]::new($false)
    $OutputEncoding = $utf8
    [Console]::OutputEncoding = $utf8
    [Console]::InputEncoding = $utf8

    $env:QA_API_REPORT = $apiPath
    $env:QA_API_COLLECTION = $ApiCollection
    $env:QA_API_SCHEMA_PATH = $ContractSchema
    $env:QA_API_TIMEOUT_MS = [string]$ApiTimeoutMs
    $env:QA_API_MAX_REQUESTS = [string]$ApiMaxRequests
    Write-Host ('Run ' + $script:RunId + ' started. Evidence is being written under ' + $script:RunDir)

    Write-Host 'Phase 1/5: HTTP and API checks'
    $phaseErrorAction = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $apiOutput = & $node $apiRunner 2>&1
      $apiCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $phaseErrorAction }
    Save-ChildLog (Join-Path $logs 'api-runner.log') $apiOutput
    $apiResult = Get-JsonFile $apiPath
    $phase.api.status = Get-PhaseStatus $apiResult
    $apiRequestCount = @($apiResult.requests).Count
    $phase.api.details = if ($phase.api.status -eq 'skipped') {
      [string]$apiResult.reason
    } else {
      ($apiRequestCount.ToString() + ' request(s); ' + [string]$apiResult.assertions.passed + '/' + [string]$apiResult.assertions.total + ' assertions passed; ' + [string]$apiResult.assertions.failed + ' failed.')
    }
    foreach ($finding in @($apiResult.findings)) {
      $requestRecord = @($apiResult.requests | Where-Object {
        ([string]$_.name -eq [string]$finding.request) -and (!$finding.url -or [string]$_.url -eq [string]$finding.url)
      } | Select-Object -First 1)
      $findings += [ordered]@{
        severity = if ($phase.api.status -eq 'failed') { 'high' } else { 'error' }
        phase = 'api'
        title = ([string]$finding.request + ': ' + [string]$finding.message)
        request = [string]$finding.request
        url = [string]$finding.url
        status = if ($requestRecord.Count) { $requestRecord[0].statusCode } else { $null }
        statusText = if ($requestRecord.Count) { [string]$requestRecord[0].status } else { '' }
        details = [string]$finding.message
        nextAction = 'Review the request expectation, endpoint response, and the linked Postman assertion before changing the contract.'
      }
    }
    if ($apiCode -gt 2 -and $phase.api.status -notin @('failed','error')) { $phase.api.status = 'error'; $phase.api.details = 'API runner returned exit code ' + $apiCode + '.' }

    Write-Host 'Phase 2/5: Browser navigation across Chromium, Firefox, WebKit, and mobile emulation'
    $env:REPORT_DIR = $script:RunDir
    $env:PW_OUTPUT_DIR = $playOutput
    $env:AXE_FRAGMENT_DIR = $fragmentDir
    $env:QA_PLAYWRIGHT_REPORT = $playwrightPath
    $env:QA_PLAYWRIGHT_STDOUT = Join-Path $logs 'playwright.stdout.log'
    $env:QA_PLAYWRIGHT_STDERR = Join-Path $logs 'playwright.stderr.log'
    $env:QA_PLAYWRIGHT_OUTPUT_DIR = $playOutput
    $env:QA_PLAYWRIGHT_TIMEOUT_MS = [string]$BrowserTimeoutMs
    $env:QA_BROWSER_TEST_TIMEOUT_MS = [string]([Math]::Min(900000,$BrowserTimeoutMs))
    $env:QA_NAVIGATION_TIMEOUT_MS = '20000'
    $phaseErrorAction = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $browserOutput = & $node $browserRunner 2>&1
      $browserCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $phaseErrorAction }
    Save-ChildLog (Join-Path $logs 'browser-runner.log') $browserOutput
    if (Test-Path -LiteralPath $playwrightRunnerPath -PathType Leaf) { $browserResult = Get-JsonFile $playwrightRunnerPath }
    else { $browserResult = [ordered]@{ status='error'; totalTests=0; passedTests=0; failedTests=0; findings=@(@{ message='Playwright did not produce its runner report.' }) } }
    $phase.browser.status = Get-PhaseStatus $browserResult

    Write-Host 'Phase 3/5: Accessibility and visual evidence'
    $fragments = Get-BrowserFragments $fragmentDir
    foreach ($fragment in $fragments) {
      foreach ($audit in @($fragment.audits)) { $audits += $audit }
    }
    $violationFindings = New-A11yFindings $audits
    $violationOccurrences = 0
    foreach ($audit in $audits) { foreach ($violation in @($audit.violations)) { $violationOccurrences += @($violation.nodes).Count } }
    $a11yIncomplete = @()
    $browserFindings = @()
    $networkWarnings = @()
    $visualFindings = @()
    $visualCompared = 0
    $visualRecorded = 0
    $visualNotCompared = 0
    $visualMismatched = 0
    foreach ($fragment in $fragments) {
      $a11yIncomplete += @($fragment.incomplete)
      foreach ($finding in @($fragment.browserFindings)) {
        $browserFindings += [ordered]@{
          browser = [string]$fragment.browser
          type = [string]$finding.type
          url = ConvertTo-ReportUrl ([string]$finding.url)
          source = ConvertTo-ReportUrl ([string]$finding.source)
          status = $finding.status
          statusText = [string]$finding.statusText
          message = [string]$finding.message
        }
      }
      foreach ($finding in @($fragment.networkWarnings)) {
        $networkWarnings += [ordered]@{
          browser = [string]$fragment.browser
          type = [string]$finding.type
          url = ConvertTo-ReportUrl ([string]$finding.url)
          status = $finding.status
          statusText = [string]$finding.statusText
          message = [string]$finding.message
        }
      }
      $visualFindings += @($fragment.visualFindings)
      $visualCompared += [int]$fragment.visual.compared
      $visualRecorded += [int]$fragment.visual.recorded
      $visualNotCompared += [int]$fragment.visual.notCompared
      $visualMismatched += [int]$fragment.visual.mismatched
    }
    foreach ($audit in $audits) {
      foreach ($item in @($audit.incomplete)) {
        $a11yIncomplete += [ordered]@{ browser=$audit.browser; url=$audit.url; check='axe manual review'; rule=$item.id; impact=$item.impact; help=$item.help }
      }
    }
    foreach ($finding in $violationFindings) {
      $findings += [ordered]@{
        severity = if ($finding.severity -in @('critical','serious')) { 'high' } else { 'medium' }
        phase = 'accessibility'
        title = [string]$finding.title
        browser = (@($finding.locations | ForEach-Object { ($_ -split ' ')[0] } | Select-Object -Unique) -join ', ')
        url = (@($finding.locations | Select-Object -Unique) -join '; ')
        selector = [string]$finding.selector
        details = ([string]$finding.details + ' (' + [string]$finding.occurrences + ' occurrence(s) across ' + @($finding.locations).Count + ' browser/page location(s))')
        helpUrl = [string]$finding.helpUrl
        nextAction = [string]$finding.nextAction
      }
    }
    $browserFindingGroups = @{}
    foreach ($finding in $browserFindings) {
      $statusText = if ($null -ne $finding.status) { [string]$finding.status } else { '' }
      $kind = if ($statusText) { 'http-response' } elseif ($finding.type) { [string]$finding.type } else { 'browser-failure' }
      $message = Format-SummaryText ([string]$finding.message)
      $keyParts = if ($statusText) { @($kind,[string]$finding.url,$statusText) } elseif ($finding.type -eq 'console-error') { @($kind,[string]$finding.url,$message) } else { @($kind,[string]$finding.url,$statusText,$message) }
      $key = [string]::Join([string][char]31,[string[]]$keyParts)
      if (!$browserFindingGroups.ContainsKey($key)) {
        $title = if ($statusText) { 'HTTP response failure' } elseif ($finding.type -eq 'pageerror') { 'JavaScript page error' } elseif ($finding.type -eq 'console-error') { 'JavaScript console error' } elseif ($finding.type -eq 'request-failed') { 'Browser request failed' } else { 'Browser failure' }
        $statusDescription = if ($finding.statusText) { ' ' + [string]$finding.statusText } else { '' }
        $details = if ($statusText) { 'Same-origin request returned HTTP ' + $statusText + $statusDescription + '.' } elseif ($message) { $message } else { 'The browser check reported a failure without further detail.' }
        $browserFindingGroups[$key] = [ordered]@{
          title = $title
          type = [string]$finding.type
          url = [string]$finding.url
          status = $finding.status
          statusText = [string]$finding.statusText
          details = $details
          browsers = @()
          observations = @()
          sources = @()
          sourceLocations = @()
        }
      }
      $group = $browserFindingGroups[$key]
      $browser = [string]$finding.browser
      $observation = [string]::Join([string][char]31,[string[]]@($browser,[string]$finding.url,$statusText,$kind))
      if ($observation -and @($group.observations) -notcontains $observation) {
        $group.observations = @($group.observations) + $observation
        $group.browsers = @((@($group.browsers) + $browser) | Where-Object { $_ } | Sort-Object -Unique)
      }
      if ($finding.type -and @($group.sources) -notcontains [string]$finding.type) { $group.sources = @($group.sources) + [string]$finding.type }
      $sourceLocation = [string]$finding.source
      if ($sourceLocation -and @($group.sourceLocations) -notcontains $sourceLocation) { $group.sourceLocations = @($group.sourceLocations) + $sourceLocation }
    }
    foreach ($group in $browserFindingGroups.Values) {
      $findings += [ordered]@{
        severity = 'high'
        phase = 'browser'
        title = [string]$group.title
        browser = (@($group.browsers | Sort-Object -Unique) -join ', ')
        url = [string]$group.url
        status = $group.status
        statusText = [string]$group.statusText
        occurrences = @($group.observations).Count
        sources = @($group.sources)
        sourceLocations = @($group.sourceLocations | Sort-Object -Unique)
        details = [string]$group.details
        nextAction = if ($group.type -eq 'console-error') { 'Review the browser console message and its source location in the browser evidence.' } else { 'Inspect the affected route and the corresponding browser response evidence.' }
      }
    }
    $networkWarningGroups = @{}
    foreach ($finding in $networkWarnings) {
      $statusText = if ($null -ne $finding.status) { [string]$finding.status } else { '' }
      $kind = if ($statusText) { 'http-response' } elseif ($finding.type) { [string]$finding.type } else { 'network-warning' }
      $message = Format-SummaryText ([string]$finding.message)
      $keyParts = if ($statusText) { @($kind,[string]$finding.url,$statusText) } else { @($kind,[string]$finding.url,$statusText,$message) }
      $key = [string]::Join([string][char]31,[string[]]$keyParts)
      if (!$networkWarningGroups.ContainsKey($key)) {
        $statusDescription = if ($finding.statusText) { ' ' + [string]$finding.statusText } else { '' }
        $details = if ($statusText) { 'Cross-origin resource returned HTTP ' + $statusText + $statusDescription + '.' } elseif ($message) { $message } else { 'A cross-origin resource request did not complete successfully.' }
        $networkWarningGroups[$key] = [ordered]@{
          url = [string]$finding.url
          status = $finding.status
          statusText = [string]$finding.statusText
          details = $details
          browsers = @()
          observations = @()
        }
      }
      $group = $networkWarningGroups[$key]
      $browser = [string]$finding.browser
      $observation = [string]::Join([string][char]31,[string[]]@($browser,[string]$finding.url,$statusText,$kind))
      if ($observation -and @($group.observations) -notcontains $observation) {
        $group.observations = @($group.observations) + $observation
        $group.browsers = @((@($group.browsers) + $browser) | Where-Object { $_ } | Sort-Object -Unique)
      }
    }
    foreach ($group in $networkWarningGroups.Values) {
      $findings += [ordered]@{
        severity = 'warning'
        phase = 'browser-network'
        title = 'Cross-origin network warning'
        browser = (@($group.browsers | Sort-Object -Unique) -join ', ')
        url = [string]$group.url
        status = $group.status
        statusText = [string]$group.statusText
        occurrences = @($group.observations).Count
        details = [string]$group.details
        nextAction = 'Verify this external resource response; the service may be outside the target application.'
      }
    }
    foreach ($finding in @($browserResult.findings)) {
      if ($finding.message) {
        $runnerMessage = [string]$finding.message
        if (($runnerMessage -match '^(?:Error:\s*)?QA_BROWSER_FAILURES:' -and $browserFindings.Count -gt 0) -or
            ($runnerMessage -match '^(?:Error:\s*)?QA_VISUAL_FINDINGS:' -and $visualFindings.Count -gt 0) -or
            ($runnerMessage -match '^(?:Error:\s*)?QA_A11Y_FINDINGS:' -and $violationFindings.Count -gt 0)) { continue }
        $findings += [ordered]@{
          severity = 'error'
          phase = 'browser'
          title = 'Playwright runner finding'
          browser = [string]$finding.project
          test = [string]$finding.test
          details = Get-ConciseRunnerMessage $runnerMessage
          nextAction = 'Review the Playwright HTML report and the failing test evidence.'
        }
      }
    }
    foreach ($finding in $visualFindings) {
      $findings += [ordered]@{
        severity = 'high'
        phase = 'visual'
        title = 'Visual regression'
        browser = [string]$finding.browser
        url = [string]$finding.url
        details = [string]$finding.message
        baseline = [string]$finding.baseline
        screenshot = [string]$finding.screenshot
        nextAction = 'Review the screenshot and baseline pair; update the baseline only after approving the visual change.'
      }
    }
    $a11yResult = [ordered]@{
      schemaVersion = 1
      generatedUtc = [DateTime]::UtcNow.ToString('o')
      targetUrl = ConvertTo-ReportUrl $script:TargetUrl
      standards = @('WCAG 2.1 A','WCAG 2.1 AA','WCAG 2.1 AAA')
      pagesScanned = $audits.Count
      violationOccurrences = $violationOccurrences
      uniqueRuleSelectorFindings = $violationFindings.Count
      violations = $violationFindings
      incompleteCount = $a11yIncomplete.Count
      incomplete = $a11yIncomplete
      audits = $audits
    }
    Write-JsonAtomic $a11yPath $a11yResult
    if ($violationOccurrences -gt 0) {
      $phase.accessibility.status = 'failed'
      $phase.accessibility.details = ($audits.Count.ToString() + ' page audit(s); ' + $violationOccurrences + ' confirmed violation node occurrence(s) across ' + $violationFindings.Count + ' grouped finding(s); ' + $a11yIncomplete.Count + ' incomplete check(s).')
    } elseif ($audits.Count -eq 0) {
      $phase.accessibility.status = 'incomplete'
      $phase.accessibility.details = ('No completed accessibility audit was available; ' + $a11yIncomplete.Count + ' incomplete check(s).')
    } elseif ($a11yIncomplete.Count -gt 0) {
      $phase.accessibility.status = 'incomplete'
      $phase.accessibility.details = ($audits.Count.ToString() + ' page audit(s); 0 detected violations; ' + $a11yIncomplete.Count + ' incomplete check(s).')
    } else {
      $phase.accessibility.status = 'passed'
      $phase.accessibility.details = ($audits.Count.ToString() + ' page audit(s); 0 detected violations; 0 incomplete checks.')
    }
    if ($visualMismatched -gt 0) {
      $phase.visual.status = 'failed'
      $phase.visual.details = $visualMismatched.ToString() + ' visual mismatch(es); ' + $visualCompared.ToString() + ' comparison(s).'
    } elseif ($visualNotCompared -gt 0 -and !$UpdateVisualBaseline) {
      $phase.visual.status = 'incomplete'
      $phase.visual.details = $visualCompared.ToString() + ' compared; ' + $visualNotCompared.ToString() + ' route(s) have no baseline.'
    } elseif ($visualRecorded -gt 0) {
      $phase.visual.status = 'passed'
      $phase.visual.details = $visualRecorded.ToString() + ' baseline image(s) recorded by explicit request.'
    } elseif ($visualCompared -gt 0) {
      $phase.visual.status = 'passed'
      $phase.visual.details = $visualCompared.ToString() + ' baseline comparison(s) matched.'
    } else {
      $phase.visual.status = 'incomplete'
      $phase.visual.details = 'No screenshot comparison completed.'
    }
    $visitedCount = 0
    $discoveredCount = 0
    foreach ($fragment in $fragments) { $visitedCount += [int]$fragment.visitedCount; $discoveredCount += [int]$fragment.discoveredCount }
    $testDetails = if ($null -ne $browserResult.totalTests) {
      'Playwright tests: ' + [string]$browserResult.passedTests + ' passed, ' + [string]$browserResult.failedTests + ' failed, ' + [string]$browserResult.skippedTests + ' skipped.'
    } else { 'Playwright test totals unavailable.' }
    $phase.browser.details = ($visitedCount.ToString() + ' page visit(s) across ' + $fragments.Count.ToString() + ' browser/viewport project(s); ' + $discoveredCount.ToString() + ' same-origin link(s) discovered; ' + $testDetails)
    if ($browserFindings.Count -gt 0 -and $phase.browser.status -notin @('error','failed')) { $phase.browser.status = 'failed' }
    if ($phase.browser.status -eq 'passed' -and $fragments.Count -lt 4) { $phase.browser.status = 'incomplete'; $phase.browser.details += ' Required browser/viewport coverage is incomplete.' }

    Write-Host 'Phase 4/5: Performance'
    if ($PerformanceMode -eq 'Skip') {
      $performanceResult = [ordered]@{
        schemaVersion=1; generatedUtc=[DateTime]::UtcNow.ToString('o'); status='skipped'; mode='Skip'
        requests=@{ count=0; failed=0; errorRate=$null; throughputRps=$null }
        latency=@{ p95Ms=$null; p99Ms=$null }
        thresholds=@{ p95Ms=$P95ThresholdMs; p99Ms=$P99ThresholdMs; errorRatePercent=$ErrorRateThresholdPercent }
        findings=@(); reason='PerformanceMode Skip was requested.'
      }
      Write-JsonAtomic $performancePath $performanceResult
      $phase.performance.status = 'skipped'
      $phase.performance.details = $performanceResult.reason
    } else {
      $env:QA_K6_EXE = $k6Exe
      $env:QA_K6_SCRIPT = $k6Script
      $env:QA_K6_REPORT = $performancePath
      $env:QA_K6_STDOUT = Join-Path $logs 'k6.stdout.log'
      $env:QA_K6_STDERR = Join-Path $logs 'k6.stderr.log'
      $env:QA_K6_TIMEOUT_MS = [string]([Math]::Min(1800000,((2 * $RampSeconds + $HoldSeconds + 15) * 1000)))
      $env:QA_PERFORMANCE_MODE = $PerformanceMode.ToLowerInvariant()
      $env:QA_VUS = if ($PerformanceMode -eq 'Smoke') { '1' } else { [string]$VirtualUsers }
      $env:QA_RAMP_SECONDS = [string]$RampSeconds
      $env:QA_HOLD_SECONDS = [string]$HoldSeconds
      $env:QA_P95_MS = [string]$P95ThresholdMs
      $env:QA_P99_MS = [string]$P99ThresholdMs
      $env:QA_ERROR_RATE_PERCENT = [string]$ErrorRateThresholdPercent
      $phaseErrorAction = $ErrorActionPreference
      try {
        $ErrorActionPreference = 'Continue'
        $perfOutput = & $node $k6Runner 2>&1
        $perfCode = $LASTEXITCODE
      } finally { $ErrorActionPreference = $phaseErrorAction }
      Save-ChildLog (Join-Path $logs 'k6-runner.log') $perfOutput
      $performanceResult = Get-JsonFile $performancePath
      $phase.performance.status = Get-PhaseStatus $performanceResult
      if ($phase.performance.status -eq 'skipped') {
        $phase.performance.details = [string]$performanceResult.reason
      } else {
        $errorPercent = $null
        if ($null -ne $performanceResult.requests.errorRate) { $errorPercent = [double]$performanceResult.requests.errorRate * 100 }
        $p95Check = @($performanceResult.thresholds | Where-Object { [string]$_.name -like 'p(95)<*' } | Select-Object -First 1)
        $p99Check = @($performanceResult.thresholds | Where-Object { [string]$_.name -like 'p(99)<*' } | Select-Object -First 1)
        $errorCheck = @($performanceResult.thresholds | Where-Object { [string]$_.name -like 'rate<*' } | Select-Object -First 1)
        $p95Status = if ($p95Check.Count -and $p95Check[0].passed) { 'PASS' } elseif ($p95Check.Count) { 'FAIL' } else { 'UNKNOWN' }
        $p99Status = if ($p99Check.Count -and $p99Check[0].passed) { 'PASS' } elseif ($p99Check.Count) { 'FAIL' } else { 'UNKNOWN' }
        $errorStatus = if ($errorCheck.Count -and $errorCheck[0].passed) { 'PASS' } elseif ($errorCheck.Count) { 'FAIL' } else { 'UNKNOWN' }
        $phase.performance.details = ([string]$PerformanceMode + '; ' + [string]$performanceResult.requests.count + ' request(s), ' +
          [string]$performanceResult.requests.failed + ' failed; error rate ' + (Format-Number $errorPercent 4) + '%; ' +
          'p95 ' + (Format-Number $performanceResult.latency.p95Ms) + ' ms (limit < ' + $P95ThresholdMs + ' ms: ' + $p95Status + '); ' +
          'p99 ' + (Format-Number $performanceResult.latency.p99Ms) + ' ms (limit < ' + $P99ThresholdMs + ' ms: ' + $p99Status + '); ' +
          'error budget < ' + (Format-Number $ErrorRateThresholdPercent 2) + '%: ' + $errorStatus + '.')
      }
      foreach ($finding in @($performanceResult.findings)) {
        $findings += [ordered]@{
          severity = if ($finding.severity -eq 'warning') { 'warning' } else { 'high' }
          phase = 'performance'
          title = if ($null -ne $finding.status) { 'Performance HTTP response failure' } elseif ($finding.kind -eq 'threshold') { 'Performance threshold not met' } else { [string]$finding.message }
          target = [string]$finding.target
          url = [string]$finding.url
          status = $finding.status
          details = if ($null -ne $finding.status) { 'HTTP ' + [string]$finding.status + ': ' + [string]$finding.message } else { [string]$finding.message }
          nextAction = if ($finding.kind -eq 'threshold') { 'Review the measured latency or error rate against the required service objective before changing the threshold.' } else { 'Review the k6 request summary and response timing in this run before making capacity or service changes.' }
        }
      }
      if ($perfCode -gt 2 -and $phase.performance.status -notin @('failed','error')) {
        $phase.performance.status = 'error'
        $phase.performance.details = 'k6 runner returned exit code ' + $perfCode + '.'
      }
    }

    if ($Continuous -and $phase.performance.status -eq 'passed' -and $performanceResult.latency.p95Ms -ne $null) {
      $baselineDirectory = Join-Path $script:Reports 'baselines'
      [IO.Directory]::CreateDirectory($baselineDirectory) | Out-Null
      $baselineInput = $script:TargetUrl + '|' + $script:ApiBaseUrl + '|' + $PerformanceMode + '|' + $VirtualUsers + '|' + $RampSeconds + '|' + $HoldSeconds + '|' + $P95ThresholdMs + '|' + $P99ThresholdMs + '|' + $ErrorRateThresholdPercent
      $sha = [Security.Cryptography.SHA256]::Create()
      try { $baselineKey = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($baselineInput)))).Replace('-','').ToLowerInvariant() }
      finally { $sha.Dispose() }
      $baselinePath = Join-Path $baselineDirectory ($baselineKey + '.json')
      if (!(Test-Path -LiteralPath $baselinePath -PathType Leaf)) {
        Write-JsonAtomic $baselinePath ([ordered]@{
          targetUrl=(ConvertTo-ReportUrl $script:TargetUrl); apiBaseUrl=(ConvertTo-ReportUrl $script:ApiBaseUrl)
          performanceMode=$PerformanceMode; virtualUsers=$VirtualUsers; rampSeconds=$RampSeconds; holdSeconds=$HoldSeconds
          p95Ms=$performanceResult.latency.p95Ms; p99Ms=$performanceResult.latency.p99Ms
          errorRate=$performanceResult.requests.errorRate; createdUtc=[DateTime]::UtcNow.ToString('o')
        })
        $coverageNotes += 'Continuous performance baseline created only after a completed run that met all configured thresholds.'
      } else {
        $baseline = Get-JsonFile $baselinePath
        $regressions = @()
        if ($performanceResult.latency.p95Ms -gt ([double]$baseline.p95Ms * 1.2)) { $regressions += 'p95 exceeded the saved baseline by more than 20 percent.' }
        if ($performanceResult.latency.p99Ms -gt ([double]$baseline.p99Ms * 1.2)) { $regressions += 'p99 exceeded the saved baseline by more than 20 percent.' }
        if ($performanceResult.requests.errorRate -gt ([double]$baseline.errorRate + 0.01)) { $regressions += 'HTTP error rate increased by more than one percentage point.' }
        if ($regressions.Count -gt 0) {
          $phase.performance.status = 'failed'
          $phase.performance.details += ' Baseline regression: ' + ($regressions -join ' ')
          foreach ($message in $regressions) {
            $findings += [ordered]@{ severity='high'; phase='performance'; title='Continuous performance regression'; details=$message; nextAction='Investigate the regression in the run metrics and compare with the saved baseline.' }
          }
          $performanceResult.status = 'failed'
          $performanceResult.regressions = $regressions
          Write-JsonAtomic $performancePath $performanceResult
        }
      }
    }
  } catch {
    $executionError = $_.Exception.Message
    $script:FatalError = $executionError
    foreach ($name in @('api','browser','accessibility','visual','performance')) {
      if ($phase[$name].status -eq 'not-run') {
        $phase[$name].status = 'error'
        $phase[$name].details = $executionError
      }
    }
    $findings += [ordered]@{
      severity='error'
      phase='orchestrator'
      title='QA run could not complete'
      details=$executionError
      nextAction='Correct the configuration or runtime problem described above, then rerun the public entry point.'
    }
  }

  $visualFiles = @()
  $traceFiles = @()
  $videoFiles = @()
  try {
    if (Test-Path -LiteralPath $script:RunDir -PathType Container) {
      $traceFiles = @([IO.Directory]::EnumerateFiles($script:RunDir,'trace.zip',[IO.SearchOption]::AllDirectories))
      $videoFiles = @([IO.Directory]::EnumerateFiles($script:RunDir,'*.webm',[IO.SearchOption]::AllDirectories))
      if (Test-Path -LiteralPath $screenshots -PathType Container) { $visualFiles = @([IO.Directory]::EnumerateFiles($screenshots,'*.png',[IO.SearchOption]::AllDirectories)) }
    }
  } catch {}
  if ($audits.Count -ge ($MaxPages * 3) -and $MaxPages -gt 0) {
    $coverageNotes += ('The configured per-project page cap was reached (' + $MaxPages + ' pages per browser/viewport); additional routes may remain unvisited.')
  }
  if (!$script:ApiBaseUrl -and !$ApiCollection) { $coverageNotes += 'API checks were skipped because no API endpoint or collection was supplied.' }
  if ($phase.visual.status -eq 'incomplete') { $coverageNotes += 'Visual coverage is incomplete until baselines are explicitly recorded or supplied for this target.' }
  if ($PerformanceMode -eq 'Smoke') { $coverageNotes += 'Smoke performance mode uses one request per distinct configured endpoint and does not establish production capacity.' }
  $coverageNotes += 'No custom business-flow scenario was supplied or run.'

  $status = Get-OverallStatus $phase
  $startedText = $script:RunStartedUtc.ToString('o')
  $duration = [Math]::Max(0,([DateTime]::UtcNow - $script:RunStartedUtc).TotalSeconds)
  $rerun = '& ' + (ConvertTo-QuotedPowerShellString $script:PublicScript) + ' -TargetUrl ' + (ConvertTo-QuotedPowerShellString (ConvertTo-ReportUrl $script:TargetUrl)) +
    ' -NonInteractive -PerformanceMode ' + $PerformanceMode + ' -MaxPages ' + $MaxPages + ' -SkipToolUpdates'
  if ($script:ApiBaseUrl) { $rerun += ' -ApiBaseUrl ' + (ConvertTo-QuotedPowerShellString (ConvertTo-ReportUrl $script:ApiBaseUrl)) }
  if ($ApiCollection) { $rerun += ' -ApiCollection ' + (ConvertTo-QuotedPowerShellString $ApiCollection) }
  if ($ContractSchema) { $rerun += ' -ContractSchema ' + (ConvertTo-QuotedPowerShellString $ContractSchema) }
  if ($UpdateVisualBaseline) { $rerun += ' -UpdateVisualBaseline' }
  if ($script:TargetUrl -match '(?i)(?:token|key|secret|password|passwd|auth|session|code|signature)=|://[^/]*@') {
    $rerun = '& ' + (ConvertTo-QuotedPowerShellString $script:PublicScript) + ' -TargetUrl ''<set the original target URL securely>'' -NonInteractive -PerformanceMode ' + $PerformanceMode + ' -MaxPages ' + $MaxPages + ' -SkipToolUpdates'
  }
  $report = [ordered]@{
    schemaVersion = 1
    runId = $script:RunId
    startedUtc = $startedText
    completedUtc = [DateTime]::UtcNow.ToString('o')
    durationSeconds = $duration
    status = $status
    exitCode = switch ($status) { 'PASS' {0} 'FAIL' {1} 'INCOMPLETE' {2} default {3} }
    targetUrl = ConvertTo-ReportUrl $script:TargetUrl
    apiBaseUrl = ConvertTo-ReportUrl $script:ApiBaseUrl
    performanceMode = $PerformanceMode
    effectiveConfiguration = [ordered]@{
      apiCollection = if ($ApiCollection) { [IO.Path]::GetFullPath($ApiCollection) } else { '' }
      contractSchema = if ($ContractSchema) { [IO.Path]::GetFullPath($ContractSchema) } else { '' }
      maxPagesPerBrowser = $MaxPages
      performanceMode = $PerformanceMode
      virtualUsers = if ($PerformanceMode -eq 'Smoke') { 1 } else { $VirtualUsers }
      rampSeconds = $RampSeconds
      holdSeconds = $HoldSeconds
      p95ThresholdMs = $P95ThresholdMs
      p99ThresholdMs = $P99ThresholdMs
      errorRateThresholdPercent = $ErrorRateThresholdPercent
      apiTimeoutMs = $ApiTimeoutMs
      apiMaxRequests = $ApiMaxRequests
      browserTimeoutMs = $BrowserTimeoutMs
      visualBaselineUpdateRequested = [bool]$UpdateVisualBaseline
    }
    phases = $phase
    coverage = [ordered]@{
      browserProjects = @($fragments | ForEach-Object { [string]$_.browser })
      browserProjectCount = $fragments.Count
      pagesVisited = $visitedCount
      pagesAudited = $audits.Count
      maxPagesPerBrowser = $MaxPages
      visual = [ordered]@{ compared=$visualCompared; recorded=$visualRecorded; notCompared=$visualNotCompared; mismatched=$visualMismatched }
      api = [ordered]@{ enabled=([bool]($script:ApiBaseUrl -or $ApiCollection)); status=[string]$phase.api.status }
      customBusinessScenarios = 'none supplied'
      authenticatedFlows = 'not tested unless represented by supplied browser/API scenarios'
      nativeDesktopOrMobileApps = 'not tested'
      securityPenetration = 'not tested'
      manualAccessibilityReview = if ($a11yIncomplete.Count) { 'required for incomplete checks listed in a11y_results.json' } else { 'not performed' }
      notes = @($coverageNotes)
    }
    findings = @($findings)
    performance = $performanceResult
    accessibility = $a11yResult
    dependencies = $runtimeVersions
    runtimePaths = [ordered]@{
      temp = $env:TEMP
      userProfile = $env:USERPROFILE
      appData = $env:APPDATA
      localAppData = $env:LOCALAPPDATA
      npmCache = $env:NPM_CONFIG_CACHE
      playwrightBrowsers = $env:PLAYWRIGHT_BROWSERS_PATH
    }
    fatalError = $executionError
    evidence = [ordered]@{
      summary = [IO.Path]::GetFullPath($script:SummaryPath)
      htmlReport = [IO.Path]::GetFullPath($script:HtmlPath)
      overall = [IO.Path]::GetFullPath($script:OverallPath)
      api = if (Test-Path -LiteralPath $apiPath -PathType Leaf) { [IO.Path]::GetFullPath($apiPath) } else { '' }
      accessibility = if (Test-Path -LiteralPath $a11yPath -PathType Leaf) { [IO.Path]::GetFullPath($a11yPath) } else { '' }
      performance = if (Test-Path -LiteralPath $performancePath -PathType Leaf) { [IO.Path]::GetFullPath($performancePath) } else { '' }
      performanceRaw = if (Test-Path -LiteralPath ($performancePath + '.raw.json') -PathType Leaf) { [IO.Path]::GetFullPath($performancePath + '.raw.json') } else { '' }
      playwrightJson = if (Test-Path -LiteralPath $playwrightPath -PathType Leaf) { [IO.Path]::GetFullPath($playwrightPath) } else { '' }
      playwrightRunner = if (Test-Path -LiteralPath $playwrightRunnerPath -PathType Leaf) { [IO.Path]::GetFullPath($playwrightRunnerPath) } else { '' }
      playwrightHtml = if (Test-Path -LiteralPath $htmlReport -PathType Leaf) { [IO.Path]::GetFullPath($htmlReport) } else { '' }
      browserFragments = if (Test-Path -LiteralPath $fragmentDir -PathType Container) { [IO.Path]::GetFullPath($fragmentDir) } else { '' }
      screenshots = if ($visualFiles.Count) { [IO.Path]::GetFullPath($screenshots) } else { '' }
      traces = if ($traceFiles.Count) { ($traceFiles -join '; ') } else { '' }
      videos = if ($videoFiles.Count) { ($videoFiles -join '; ') } else { '' }
      logs = [IO.Path]::GetFullPath($logs)
      rerunCommand = $rerun
    }
    rerunCommand = $rerun
  }
  $script:FinalStatus = $status
  $script:ExitCode = [int]$report.exitCode
  Write-JsonAtomic $script:OverallPath $report
  Write-RunSummary $report
  foreach ($pair in @(
    @($apiPath,(Join-Path $script:Reports 'api_test_results.json')),
    @($a11yPath,(Join-Path $script:Reports 'a11y_results.json')),
    @($performancePath,(Join-Path $script:Reports 'performance_results.json')),
    @($script:OverallPath,(Join-Path $script:Reports 'overall_results.json')),
    @($script:SummaryPath,(Join-Path $script:Reports 'summary.txt'))
  )) {
    if (Test-Path -LiteralPath $pair[0] -PathType Leaf) { Copy-Item -LiteralPath $pair[0] -Destination $pair[1] -Force }
  }
  Write-RunHtmlReport $report (Join-Path $script:Reports 'summary.html') $script:Reports
  return [PSCustomObject]@{ Status=$status; ExitCode=$script:ExitCode; Performance=$performanceResult; RunId=$script:RunId }
}

function Write-SetupFailureSummary([string]$Message) {
  try {
    [IO.Directory]::CreateDirectory($script:RunDir) | Out-Null
    $script:FatalError = $Message
    $phase = [ordered]@{
      api = [ordered]@{ status='error'; details=$Message }
      browser = [ordered]@{ status='error'; details=$Message }
      accessibility = [ordered]@{ status='incomplete'; details='No accessibility phase ran.' }
      visual = [ordered]@{ status='incomplete'; details='No visual comparison ran.' }
      performance = [ordered]@{ status='incomplete'; details='No performance phase ran.' }
    }
    $script:FinalStatus = 'ERROR'
    $script:ExitCode = 3
    $report = [ordered]@{
      schemaVersion=1
      runId=$script:RunId
      startedUtc=$script:RunStartedUtc.ToString('o')
      completedUtc=[DateTime]::UtcNow.ToString('o')
      durationSeconds=([DateTime]::UtcNow - $script:RunStartedUtc).TotalSeconds
      status='ERROR'
      exitCode=3
      targetUrl=(ConvertTo-ReportUrl $script:TargetUrl)
      apiBaseUrl=(ConvertTo-ReportUrl $script:ApiBaseUrl)
      performanceMode=$PerformanceMode
      phases=$phase
      findings=@([ordered]@{severity='error';phase='configuration';title='Configuration or preflight error';details=$Message;nextAction='Fix the reported input or missing runtime and rerun.'})
      coverage=[ordered]@{notes=@('No QA phase completed because configuration or preflight failed.')}
      evidence=[ordered]@{summary=[IO.Path]::GetFullPath($script:SummaryPath);htmlReport=[IO.Path]::GetFullPath($script:HtmlPath);overall=[IO.Path]::GetFullPath($script:OverallPath);logs=[IO.Path]::GetFullPath((Join-Path $script:RunDir 'logs'));rerunCommand=''}
      rerunCommand=''
      fatalError=$Message
      performance=$null
      accessibility=$null
      dependencies=@{}
      runtimePaths=@{}
    }
    Write-JsonAtomic $script:OverallPath $report
    Write-RunSummary $report
    [IO.Directory]::CreateDirectory($script:Reports) | Out-Null
    Copy-Item -LiteralPath $script:OverallPath -Destination (Join-Path $script:Reports 'overall_results.json') -Force
    Copy-Item -LiteralPath $script:SummaryPath -Destination (Join-Path $script:Reports 'summary.txt') -Force
    Write-RunHtmlReport $report (Join-Path $script:Reports 'summary.html') $script:Reports
  } catch {
    Write-Host ('QA RESULT: ERROR - ' + $Message)
    Write-Host ('Evidence path: ' + $script:RunDir)
  }
}

try {
  [IO.Directory]::CreateDirectory((Join-Path $script:Reports 'runs')) | Out-Null
  [IO.Directory]::CreateDirectory($script:RunDir) | Out-Null
  $explicit = @{}
  foreach ($key in $PSBoundParameters.Keys) { $explicit[$key] = $true }

  if ($ConfigPath) {
    if (!(Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw ('Config file was not found: ' + $ConfigPath) }
    $configFullPath = [IO.Path]::GetFullPath($ConfigPath)
    $config = Get-Content -Encoding UTF8 -LiteralPath $configFullPath -Raw | ConvertFrom-Json
    foreach ($name in @('TargetUrl','ApiBaseUrl','ApiCollection','ContractSchema','VirtualUsers','RampSeconds','HoldSeconds',
      'ApiTimeoutMs','ApiMaxRequests','P95ThresholdMs','P99ThresholdMs','ErrorRateThresholdPercent','MaxPages',
      'BrowserTimeoutMs','PerformanceMode')) {
      if (!$explicit.ContainsKey($name) -and $config.PSObject.Properties[$name]) {
        Set-Variable -Name $name -Value $config.$name
      }
    }
    foreach ($name in @('ApiCollection','ContractSchema')) {
      $value = Get-Variable -Name $name -ValueOnly
      if ($value -and ![IO.Path]::IsPathRooted([string]$value)) {
        Set-Variable -Name $name -Value (Join-Path (Split-Path -Parent $configFullPath) ([string]$value))
      }
    }
    $script:TargetUrl = $TargetUrl
    $script:ApiBaseUrl = $ApiBaseUrl
  }

  if ($DryRun) {
    $script:TargetUrl = ''
    $script:ApiBaseUrl = ''
  }
  if (!$script:TargetUrl -and $script:ApiBaseUrl) { $script:TargetUrl = $script:ApiBaseUrl }
  if (!$script:TargetUrl -and !$DryRun) {
    if ($NonInteractive) { throw 'TargetUrl is required in noninteractive mode.' }
    $script:TargetUrl = Read-Host 'Target application URL'
  }
  if (!$script:TargetUrl -and !$DryRun) { throw 'TargetUrl is required.' }
  if (!$script:ApiBaseUrl -and !$ApiCollection -and !$NonInteractive -and !$DryRun) {
    $script:ApiBaseUrl = Read-Host 'API base endpoint (blank skips API checks)'
  }

  $script:Root = [IO.Path]::GetFullPath($PSScriptRoot)
  $script:PublicScript = Join-Path $script:Root 'Ultimate-QA-Orchestrator.ps1'
  $play = Join-Path $script:Root 'playwright'
  $node = Join-Path $play 'node.exe'
  if (!(Test-Path -LiteralPath $node -PathType Leaf)) { throw ('Portable Node.js was not found: ' + $node) }

  $env:TEMP = Join-Path (Join-Path $script:Root 'tmp\state') 'temp'
  $env:TMP = $env:TEMP
  $env:USERPROFILE = Join-Path (Join-Path $script:Root 'tmp\state') 'userprofile'
  $env:APPDATA = Join-Path (Join-Path $script:Root 'tmp\state') 'AppData\Roaming'
  $env:LOCALAPPDATA = Join-Path (Join-Path $script:Root 'tmp\state') 'AppData\Local'
  $env:HOME = Join-Path (Join-Path $script:Root 'tmp\state') 'home'
  $env:NPM_CONFIG_CACHE = Join-Path (Join-Path $script:Root 'tmp') 'npm-cache'
  $env:NPM_CONFIG_PREFIX = Join-Path $play 'npm-global'
  $env:npm_config_userconfig = Join-Path $env:USERPROFILE '.npmrc'
  $env:PLAYWRIGHT_BROWSERS_PATH = Join-Path $play 'browsers'
  $env:NODE_PATH = Join-Path $play 'node_modules'
  $env:PATH = $play + ';' + $env:PATH
  foreach ($path in @($env:TEMP,$env:USERPROFILE,$env:APPDATA,$env:LOCALAPPDATA,$env:HOME,$env:NPM_CONFIG_CACHE,$env:NPM_CONFIG_PREFIX,$env:PLAYWRIGHT_BROWSERS_PATH,$env:NODE_PATH)) {
    [IO.Directory]::CreateDirectory($path) | Out-Null
  }
  $utf8 = [Text.UTF8Encoding]::new($false)
  $OutputEncoding = $utf8
  [Console]::OutputEncoding = $utf8
  [Console]::InputEncoding = $utf8

  if ($DryRun) {
    $mockServer = Join-Path $script:Root 'mock\mock-server.js'
    if (!(Test-Path -LiteralPath $mockServer -PathType Leaf)) { throw ('Local mock server is missing: ' + $mockServer) }
    $mockOut = Join-Path $script:RunDir 'mock.stdout.log'
    $mockErr = Join-Path $script:RunDir 'mock.stderr.log'
    $portListener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
    $portListener.Start()
    $port = [int]$portListener.LocalEndpoint.Port
    $portListener.Stop()
    $env:QA_MOCK_PORT = [string]$port
    $script:MockProcess = Start-Process -FilePath $node -ArgumentList @($mockServer) -WorkingDirectory $script:Root -RedirectStandardOutput $mockOut -RedirectStandardError $mockErr -PassThru -WindowStyle Hidden
    $mockReady = $false
    for ($i=0; $i -lt 60; $i++) {
      $client = New-Object Net.Sockets.TcpClient
      try {
        $connect = $client.BeginConnect('127.0.0.1',$port,$null,$null)
        if ($connect.AsyncWaitHandle.WaitOne(50)) {
          $client.EndConnect($connect)
          $script:MockUrl = 'http://127.0.0.1:' + $port + '/'
          $script:TargetUrl = $script:MockUrl
          $script:ApiBaseUrl = $script:MockUrl + 'api'
          $ContractSchema = Join-Path $script:Root 'collections\mock-api.schema.json'
          $mockReady = $true
          break
        }
      } catch {
      } finally {
        $client.Close()
      }
      if ($script:MockProcess.HasExited) { break }
      Start-Sleep -Milliseconds 150
    }
    if (!$mockReady) { throw 'Local mock HTTP server did not become ready within 12 seconds.' }
    Write-Host ('Local mock service ready at ' + $script:MockUrl)
  }

  if (!$script:TargetUrl) { throw 'TargetUrl is required.' }
  if (![Uri]::IsWellFormedUriString($script:TargetUrl,[UriKind]::Absolute) -or !($script:TargetUrl.StartsWith('http://') -or $script:TargetUrl.StartsWith('https://'))) {
    throw 'TargetUrl must be an absolute HTTP or HTTPS URL.'
  }
  if ($script:ApiBaseUrl -and (![Uri]::IsWellFormedUriString($script:ApiBaseUrl,[UriKind]::Absolute) -or !($script:ApiBaseUrl.StartsWith('http://') -or $script:ApiBaseUrl.StartsWith('https://')))) {
    throw 'ApiBaseUrl must be an absolute HTTP or HTTPS URL.'
  }
  if ($ContractSchema -and !$script:ApiBaseUrl -and !$ApiCollection) { throw 'ContractSchema requires an API endpoint or Postman collection.' }
  if ($ApiCollection -and !(Test-Path -LiteralPath $ApiCollection -PathType Leaf)) { throw ('Postman collection was not found: ' + $ApiCollection) }
  if ($ContractSchema -and !(Test-Path -LiteralPath $ContractSchema -PathType Leaf)) { throw ('Contract schema was not found: ' + $ContractSchema) }
  $script:TargetUrl = [Uri]::new($script:TargetUrl).AbsoluteUri
  if ($script:ApiBaseUrl) { $script:ApiBaseUrl = [Uri]::new($script:ApiBaseUrl).AbsoluteUri }

  if ($NonInteractive -and !$script:TargetUrl) { throw 'TargetUrl is required in noninteractive mode.' }
  $cycle = $null
  do {
    $cycle = Invoke-QARun
    if (!$Continuous) { break }
    Write-Host ('Next complete QA run in ' + $PollSeconds + ' seconds. Press Ctrl+C to stop.')
    Start-Sleep -Seconds $PollSeconds
  } while ($true)
} catch {
  Write-SetupFailureSummary $_.Exception.Message
} finally {
  if ($script:MockProcess -and !$script:MockProcess.HasExited) {
    try { Stop-Process -Id $script:MockProcess.Id -Force -ErrorAction SilentlyContinue } catch {}
  }
  foreach ($name in $script:EnvironmentNames) {
    try { [Environment]::SetEnvironmentVariable($name,$script:SavedEnvironment[$name],'Process') } catch {}
  }
  try { $OutputEncoding = $script:SavedOutputEncoding } catch {}
  try { if ($script:SavedConsoleOutputEncoding) { [Console]::OutputEncoding = $script:SavedConsoleOutputEncoding } } catch {}
  try { if ($script:SavedConsoleInputEncoding) { [Console]::InputEncoding = $script:SavedConsoleInputEncoding } } catch {}
  try { if ($script:SavedLocation.Provider.Name -eq 'FileSystem') { Set-Location -LiteralPath $script:SavedLocation.Path -ErrorAction SilentlyContinue } } catch {}
  try { [Environment]::CurrentDirectory = $script:SavedCurrentDirectory } catch {}
  $global:LASTEXITCODE = $script:ExitCode
}
if ($ExitCodeOnCompletion) { exit $script:ExitCode }
