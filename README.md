# Portable QA Automation

Everything for this suite lives in this folder. Portable Node.js is under playwright; k6 is under k6; axe-core CLI and its Playwright engine are under k6-axe-a11y; Newman is under postman-cli. Browser builds, package caches, temporary profiles, logs, reports, and the Git repository also stay here.

## Run

Use Windows PowerShell 5.1 without loading a user profile:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Ultimate-QA-Orchestrator.ps1 -DryRun

Provide target settings directly:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Ultimate-QA-Orchestrator.ps1 -TargetUrl https://staging.example.test -ApiBaseUrl https://staging.example.test/api -ApiCollection .\collections\example.postman_collection.json -ContractSchema .\collections\mock-api.schema.json

Or pass a JSON configuration file:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Ultimate-QA-Orchestrator.ps1 -ConfigPath .\staging.json

Run continuously until Ctrl+C:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Ultimate-QA-Orchestrator.ps1 -ConfigPath .\staging.json -Continuous -PollSeconds 300

Continuous mode reruns all four phases at each interval, alerts when a previously passing cycle fails, compares p95/p99 latency and HTTP error rate with the first successful baseline for that target, and checks for changed suite files. When tracked suite files change, it refreshes npm packages and Playwright browser builds and checks Grafana k6 for a newer release. Use -SkipToolUpdates to disable that update behavior.

## Phases and outputs

- Newman runs the supplied Postman collection, or generates a GET request for ApiBaseUrl. It adds status, JSON shape, latency, and optional JSON Schema assertions to every request. Output: reports\api_test_results.json.
- Playwright crawls same-origin links up to MaxPages in Chromium, Firefox, and WebKit. It writes screenshots, traces, video, and a JSON test report under reports\playwright\current.
- axe-core evaluates discovered pages for WCAG 2.1 A, AA, and AAA. Findings: reports\a11y_results.json. Any reported violation fails the browser test.
- k6 applies a ramping VU scenario to both the target UI URL and API endpoint and exports p95/p99 and error metrics to reports\performance_results.json.
- reports\overall_results.json records phase status and the runtime paths used.
- Pass -UpdateVisualBaseline to record screenshot baselines for the configured target. Later runs compare against those baselines.

Runtime environment variables for temp, user profile, app data, npm cache, and Playwright browsers point inside this suite. This redirects the suite's known caches and profiles to F:. Windows and third-party components can still create OS-level data outside the suite, so this configuration cannot guarantee that absolutely no data is written to C:.

The tracked repository contains scripts, configuration, sample contract data, and package manifests. It deliberately excludes runtimes, node_modules, browsers, reports, traces, videos, npm cache, and local profiles.
