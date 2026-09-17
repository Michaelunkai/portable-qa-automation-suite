# Portable QA Automation

The suite and its installed entry point are:

- Public entry point: F:\backup\windowsapps\installed\Ultimate-QA-Orchestrator.ps1
- Suite source: F:\backup\windowsapps\installed\Portable-QA-Automation\Ultimate-QA-Orchestrator.ps1

Run with Windows PowerShell 5.1 and no profile:

    powershell.exe -NoProfile -File 'F:\backup\windowsapps\installed\Ultimate-QA-Orchestrator.ps1' -TargetUrl 'https://staging.example.test/' -NonInteractive -PerformanceMode Smoke -MaxPages 3 -SkipToolUpdates

The Smoke mode is the default. It performs one paced k6 iteration with one virtual user and at most one request per distinct website/API URL. Load must be selected explicitly. Load is capped by the configured VU, duration and request bounds and paces requests. Skip omits k6.

    powershell.exe -NoProfile -File 'F:\backup\windowsapps\installed\Ultimate-QA-Orchestrator.ps1' -TargetUrl 'https://staging.example.test/' -ApiBaseUrl 'https://staging.example.test/api' -PerformanceMode Load -VirtualUsers 5 -RampSeconds 5 -HoldSeconds 10 -MaxPages 10 -SkipToolUpdates

Use an API endpoint or a Postman collection only when one is known:

    powershell.exe -NoProfile -File 'F:\backup\windowsapps\installed\Ultimate-QA-Orchestrator.ps1' -TargetUrl 'https://staging.example.test/' -ApiBaseUrl 'https://staging.example.test/api' -ContractSchema 'F:\path\api.schema.json' -NonInteractive -PerformanceMode Smoke -SkipToolUpdates

Without ApiBaseUrl or ApiCollection, API checks are reported as skipped; the website is not treated as an API. For a supplied Postman collection, its own response expectations are kept. A response-time assertion is added. To apply ContractSchema to collection requests, set the collection variable qaValidateJsonSchema to true. A generated API request checks successful HTTP status and response time; JSON parsing/schema checks run only when a schema was explicitly supplied.

Settings may also come from JSON:

    powershell.exe -NoProfile -File 'F:\backup\windowsapps\installed\Ultimate-QA-Orchestrator.ps1' -ConfigPath 'F:\backup\windowsapps\installed\Portable-QA-Automation\staging.example.json' -NonInteractive -SkipToolUpdates

CLI values override the config file. Relative collection and schema paths in a config are resolved from that config file. NonInteractive requires a target URL (unless using DryRun) and avoids Read-Host. In interactive use, an empty API prompt means skip API checks.

## Local checks

DryRun starts a local HTTP fixture and runs the real browser, axe, Newman and k6 components without contacting a live site:

    powershell.exe -NoProfile -File 'F:\backup\windowsapps\installed\Ultimate-QA-Orchestrator.ps1' -DryRun -SkipToolUpdates -UpdateVisualBaseline -PerformanceMode Smoke -MaxPages 2

The deterministic regression harness exercises API semantics, a same-process positive run and deliberate local failures:

    F:\backup\windowsapps\installed\Portable-QA-Automation\playwright\node.exe F:\backup\windowsapps\installed\Portable-QA-Automation\tests\qa-regression.js

It preserves test reports under reports\acceptance and removes its temporary test files. A passing fixture run is a tool check, not evidence about the quality of a production target.

## Checks and coverage

- HTTP/API: Newman records request names, status, content type, latency and assertion results. Blank API input is skipped. Collections keep their response semantics; explicit contracts can fail with assertion details.
- Browser/navigation: Playwright visits same-origin routes within MaxPages using Chromium, Firefox and WebKit, plus Chromium mobile viewport emulation. It records navigation status, uncaught page errors, JavaScript console errors, relevant failed requests, titles and screenshots. Routes that may mutate state or download content are excluded.
- Accessibility: axe checks supported WCAG 2.1 A/AA/AAA rules and reports impact, selector, failure text and help link. Incomplete/manual-review items remain explicit. Findings are grouped across browser/page locations.
- Visual regression: Baselines are keyed by target, browser, viewport and route. A missing baseline is INCOMPLETE; UpdateVisualBaseline records one only when explicitly requested. Review a visual change before replacing a baseline.
- Performance: k6 reports request count, observed failures and rate, throughput, p95/p99, configured thresholds and any request errors. Smoke is paced and bounded. Load is optional and bounded. HTTP timings do not measure browser rendering.

The crawler proves only the routes it visited. It does not establish authenticated permissions, custom business workflows, native desktop/mobile behavior, exhaustive accessibility, security penetration coverage or production capacity unless matching scenarios and environments are provided. No custom business-flow scenario is bundled.

## Results and exit behavior

Each invocation writes an immutable directory to reports\runs\run-id containing report.html, summary.txt, overall_results.json, phase reports, logs and browser evidence. Open report.html for a readable overview with phase cards, prioritized findings, accessibility review, coverage limits and links to the evidence. reports\summary.html, reports\summary.txt and related root JSON files are compatibility copies of the latest run. The terminal summary keeps the artifact list concise; overall_results.json retains the full trace and video inventory. The final same-terminal summary reports PASS, FAIL, INCOMPLETE or ERROR, findings, coverage limits, remediation and absolute evidence paths.

By default the script returns to the invoking PowerShell session and sets $LASTEXITCODE; it does not terminate that session. Add ExitCodeOnCompletion when a process exit is required: 0 means pass, 1 fail, 2 incomplete and 3 runtime/configuration error.

Known tool caches, browser downloads, temporary profiles, logs and reports are redirected under this suite on F:. Windows and third-party components may still create operating-system data outside the suite. A fresh checkout needs the portable Node.js, k6, Newman, Playwright packages and browser builds installed in their documented suite folders.
