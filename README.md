# Portable Website QA

**A Windows-first website QA suite for browser, accessibility, API, visual and bounded performance checks.**

Clone it, set up its local runtimes, run the orchestrator, and review a readable HTML report with links to the evidence.

| Browser | Accessibility | API | Visual | Performance |
| --- | --- | --- | --- | --- |
| Chromium, Firefox, WebKit and mobile viewport emulation | axe findings with impact, selectors and help links | Newman collection or a known endpoint | Screenshot comparison against explicit baselines | k6 Smoke or bounded Load |

Automated checks report observed coverage; they cannot prove every defect on every website has been found.

## Contents

- [Quick start](#quick-start)
- [Run a full QA pass](#run-a-full-qa-pass)
  - [Add API checks](#add-api-checks)
  - [Use JSON configuration](#use-json-configuration)
- [Performance modes and bounds](#performance-modes-and-bounds)
- [Local verification](#local-verification)
- [Coverage](#coverage)
- [Reports and exit codes](#reports-and-exit-codes)
- [Layout](#layout)
- [Troubleshooting](#troubleshooting)

## Quick start

Requirements: 64-bit Windows, Windows PowerShell 5.1, Git and internet access for setup. Setup downloads the pinned Node.js and k6 runtimes, installs the locked npm dependencies and browser builds, all under ignored folders in this checkout.

~~~powershell
git clone https://github.com/Michaelunkai/portable-qa-automation-suite.git
Set-Location .\portable-qa-automation-suite
& "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NoLogo -NonInteractive -File '.\Setup-PortableQA.ps1'
~~~

The setup script verifies both runtime archives with official SHA-256 checksums, runs npm ci using each tracked lockfile, and installs Chromium, Firefox and WebKit. It is safe to rerun; verified archives are reused and the browser installer reuses existing builds.

## Run a full QA pass

Run from the repository root after setup. Replace the example URL with a target you are authorized to test.

~~~powershell
& "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NoLogo -NonInteractive -File '.\Ultimate-QA-Orchestrator.ps1' -TargetUrl 'https://staging.example.test/' -NonInteractive -PerformanceMode Load -VirtualUsers 5 -RampSeconds 5 -HoldSeconds 10 -MaxPages 20 -SkipToolUpdates -ExitCodeOnCompletion
~~~

This runs HTTP, browser, accessibility, visual and Load checks. The example skips API checks until an endpoint or collection is supplied. Missing visual baselines are reported as incomplete. Review the report before deciding whether to record a baseline.

The Load profile uses five virtual users, a five-second ramp up and down, and a ten-second hold. k6 requests the website URL and, if supplied, one distinct API base URL. MaxPages bounds browser crawling; it does not make every crawled page a k6 scenario.

### Add API checks

Pass a known API base endpoint, a Postman collection, or both. A generated endpoint check validates successful HTTP status and response time. A supplied collection keeps its own assertions and receives a response-time assertion.

~~~powershell
& "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NoLogo -NonInteractive -File '.\Ultimate-QA-Orchestrator.ps1' -TargetUrl 'https://staging.example.test/' -ApiBaseUrl 'https://staging.example.test/api' -ContractSchema '.\path\to\your-api-schema.json' -NonInteractive -PerformanceMode Load -VirtualUsers 5 -RampSeconds 5 -HoldSeconds 10 -MaxPages 20 -SkipToolUpdates -ExitCodeOnCompletion
~~~

ContractSchema requires an API endpoint or collection. For a collection, JSON-schema assertions run only when its qaValidateJsonSchema collection variable is set to true. The sample collection and schema under collections/ demonstrate the format and match the local fixture. Replace them with your API's contract before using them against another service. API checks are explicitly skipped when neither endpoint nor collection is supplied.

### Use JSON configuration

Copy and edit staging.example.json, then run:

~~~powershell
& "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NoLogo -NonInteractive -File '.\Ultimate-QA-Orchestrator.ps1' -ConfigPath '.\staging.example.json' -NonInteractive -SkipToolUpdates -ExitCodeOnCompletion
~~~

CLI arguments override config values. Relative collection and schema paths are resolved from the config file's directory. NonInteractive requires a target URL unless DryRun is selected. Keep credentials out of checked-in config files.

## Performance modes and bounds

| Mode | Behavior |
| --- | --- |
| Smoke | Default. One paced k6 iteration with one virtual user and one request per distinct configured website/API endpoint. It checks availability; it does not estimate capacity. |
| Load | Ramps virtual users up, holds, then ramps down. Each iteration requests the website and optional distinct ApiBaseUrl, with a one-second pause between them. |
| Skip | Omits k6 checks. |

Default thresholds are p95 under 1,000 ms, p99 under 2,000 ms and HTTP error rate under 1%. Load is capped at 50 virtual users, 300 seconds per ramp or hold value, 180 seconds for both ramps plus hold (graceful stop excluded), and a 10,000-request estimate. MaxPages accepts 1-500 and defaults to 20. k6 measures HTTP response timing, not browser rendering. It does not replay a Postman collection or crawl every discovered page.

## Local verification

After setup, run the deterministic regression harness:

~~~powershell
& '.\playwright\node.exe' '.\tests\qa-regression.js'
~~~

Run every phase with the bundled local fixture:

~~~powershell
& "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NoLogo -NonInteractive -File '.\Ultimate-QA-Orchestrator.ps1' -DryRun -NonInteractive -PerformanceMode Load -VirtualUsers 5 -RampSeconds 5 -HoldSeconds 10 -MaxPages 20 -SkipToolUpdates -UpdateVisualBaseline -ExitCodeOnCompletion
~~~

DryRun starts the local mock server and does not send traffic to a public website. UpdateVisualBaseline is included for this local fixture only. For a real site, inspect screenshots first and record a baseline only after approving the captured appearance.

## Coverage

- **HTTP/API:** Newman records request status, content type, latency and assertions. API checks need a known endpoint or collection.
- **Browser/navigation:** Playwright follows same-origin links up to MaxPages in Chromium, Firefox, WebKit and a Chromium mobile viewport. It records navigation status, uncaught page errors, console errors, relevant failed requests, titles and screenshots. Routes that may mutate state or download content are excluded.
- **Accessibility:** axe reports machine-detectable WCAG 2.1 A/AA/AAA findings. Incomplete checks and items requiring human review remain visible.
- **Visual:** screenshots are compared by target, browser, viewport and route only when a baseline exists. Missing baselines are incomplete, not matches.
- **Performance:** k6 reports request counts, failures, throughput, p95/p99 latency, configured thresholds and request errors.

This is a bounded, unauthenticated website crawl unless you extend the tests. It cannot establish authenticated permissions, business-flow correctness, native mobile behavior, exhaustive accessibility, penetration-test coverage or production capacity. Add target-specific tests for those needs.

## Reports and exit codes

Each run creates an immutable reports/runs/{run-id}/ directory containing report.html, summary.txt, overall_results.json, phase reports, logs, screenshots and evidence where available. Open report.html for phase status, prioritized findings, coverage limits and evidence links. Latest-run compatibility summaries are also written under reports/.

Reports can contain tested URLs and page content; review them before sharing. reports/, tmp/, runtime binaries, browser downloads and planning artifacts are ignored by Git.

With ExitCodeOnCompletion: 0 = PASS, 1 = FAIL, 2 = INCOMPLETE, 3 = ERROR. Missing API definitions or visual baselines may make coverage incomplete even when other phases pass.

## Layout

~~~text
Portable-QA-Automation/
|-- Setup-PortableQA.ps1
|-- Ultimate-QA-Orchestrator.ps1
|-- collections/            # example Postman collection and JSON schema
|-- k6/                     # performance scenario and runner
|-- k6-axe-a11y/            # accessibility lockfile
|-- mock/                   # local fixture server
|-- playwright/             # browser tests, config and lockfile
|-- postman-cli/            # Newman runner and lockfile
|-- tests/                  # deterministic regression harness
|-- staging.example.json
|-- tool-manifest.json      # pinned versions and runtime checksums
+-- README.md
~~~

## Troubleshooting

- **Checksum failure:** keep the output and verify the published release checksum before retrying; do not bypass verification.
- **Runtime or browser missing:** rerun Setup-PortableQA.ps1 from the clone root. Runtime files stay under playwright/, k6/ and ignored tmp/ folders.
- **API skipped:** provide ApiBaseUrl or ApiCollection for a known API contract.
- **Visual phase incomplete:** review and create a baseline for that target and route, then rerun without the update switch.
- **Exit code 2:** open report.html to see which coverage is incomplete.

The suite redirects its own caches, temporary profiles, logs and reports into the checkout. Windows and third-party components may still write operating-system data elsewhere.
