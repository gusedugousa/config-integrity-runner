# Configuration Integrity Runner

A PowerShell prototype that evaluates Azure VM resources against a desired-state
definition, identifies configuration drift, and produces a scored report suitable
for downstream reporting (e.g. ServiceNow).

---

## Prerequisites

- PowerShell 7.2+
- Pester 5.5+ (tests only)

```powershell
# Install PowerShell on macOS
brew install powershell

# Install Pester
pwsh -Command "Install-Module Pester -MinimumVersion 5.5.0 -Force -Scope CurrentUser"
```

No Azure subscription or Az module required — the module is self-contained and uses
pre-collected JSON as input.

---

## Quick Start

```powershell
# From repo root
pwsh ./src/Invoke-ConfigIntegrityCheck.ps1
```

The script reads `data/desired-state.json` and `data/actual-state.json` by default
and writes the report to `output/integrity-report.json`.

```powershell
# Custom paths
./src/Invoke-ConfigIntegrityCheck.ps1 `
    -DesiredStatePath ./data/desired-state.json `
    -ActualStatePath  ./data/actual-state.json  `
    -OutputPath       ./output/report.json
```

---

## Repository Layout

```
.
├── src/
│   ├── ConfigIntegrity.psm1            # Core module (importable / testable)
│   └── Invoke-ConfigIntegrityCheck.ps1 # CLI entry point
├── tests/
│   └── ConfigIntegrity.Tests.ps1       # Pester v5 test suite
├── data/
│   ├── desired-state.json              # What resources should look like
│   ├── actual-state.json               # What they actually look like (simulated)
│   └── sample-output.json             # Static reference output
├── output/                             # Generated reports (git-ignored)
└── .github/workflows/
    └── integrity-check.yml             # GitHub Actions pipeline
```

---

## How It Works

### 1 — Desired State

`data/desired-state.json` declares the authoritative configuration for each VM:

```json
{
  "name": "vm-prod-web-01",
  "vmSize": "Standard_D2s_v3",
  "location": "eastus",
  "osDiskType": "Premium_LRS",
  "diagnosticsEnabled": true,
  "tags": { "Environment": "Production", "CostCenter": "CC-1001" }
}
```

In production this file would be version-controlled and reviewed via pull request,
making it the single source of truth for infrastructure policy.

### 2 — Actual State

`data/actual-state.json` simulates the output of `Get-AzVM`. In a real pipeline
a pre-step would collect this data:

```powershell
Get-AzVM -Status | Select-Object Name, ResourceGroupName, ... |
    ConvertTo-Json | Set-Content actual-state.json
```

### 3 — Comparison Logic

`Compare-VMConfiguration` evaluates five scalar properties and all required tags
for each VM, then returns a per-resource result with:

- **Status** — `COMPLIANT`, `DRIFTED`, or `MISSING`
- **Score** — `(passed checks / total checks) * 100`
- **DriftItems** — list of individual violations with severity

### 4 — Integrity Score

`Get-IntegrityScore` aggregates across all resources:

```
Overall Score = (Σ PassedChecks) / (Σ TotalChecks) × 100
```

| Score Range | Status  | Meaning                                          |
|-------------|---------|--------------------------------------------------|
| ≥ 90%       | PASS    | Environment is well-governed                     |
| 70–89%      | WARNING | Drift exists but low blast radius; schedule fix  |
| < 70%       | FAIL    | Significant drift; pipeline gates and alerts fire |

The pipeline exits with code 1 on FAIL, blocking PRs from merging.

---

## Properties Evaluated

| Property           | Severity if drifted |
|--------------------|---------------------|
| `vmSize`           | High                |
| `location`         | High                |
| `osType`           | High                |
| `osDiskType`       | Medium              |
| `diagnosticsEnabled` | Medium            |
| Each required tag  | Medium / Low        |
| Resource not found | Critical            |

Extra tags present in actual but not in desired are **not** flagged — they are
permitted additions.

---

## Running Tests

```powershell
pwsh -Command "
  Import-Module Pester -MinimumVersion 5.5.0
  Invoke-Pester ./tests -Output Detailed
"
```

The test suite covers:
- Full compliance path
- Single and multi-property scalar drift
- MISSING resource (null actual)
- Tag missing, tag value mismatch
- Extra tags in actual (no false positive)
- No-tags edge case
- Score thresholds (PASS / WARNING / FAIL)
- Zero-check edge case

---

## GitHub Actions

The workflow (`.github/workflows/integrity-check.yml`) runs on:

- Every push to `main` / `develop`
- Every PR targeting `main`
- Daily at 06:00 UTC (scheduled drift scan)
- Manual trigger (`workflow_dispatch`) with optional path overrides

**Jobs:**
1. `pester-tests` — runs the full Pester suite; must pass before integrity check runs
2. `integrity-check` — runs the comparison, writes a job summary, uploads the report artifact, and fails the pipeline if status is FAIL

---

## ServiceNow Integration

The JSON report is structured for straightforward ingest into ServiceNow.

### Recommended mapping

| Report field               | ServiceNow target                                  |
|----------------------------|----------------------------------------------------|
| `Summary.Status`           | `cmdb_ci_server.u_integrity_status` (custom field) |
| `Summary.IntegrityScore`   | `cmdb_ci_server.u_integrity_score`                 |
| `Resources[].Status`       | Configuration Item (CI) compliance flag            |
| `Resources[].DriftItems[]` | `sn_compliance_finding` table — one row per item   |
| `DriftItems[].Severity`    | `priority` on the finding record                   |
| `RunId`                    | Correlation ID for Change / Incident linking       |

**Ingest options:**

1. **Scripted REST API** — POST the JSON to a ServiceNow Scripted REST endpoint; a
   server-side script transforms and upserts records.
2. **IntegrationHub spoke** — use the "REST Step" to call the SNOW Table API from
   the GitHub Actions workflow directly after the report is generated.
3. **MID Server / Discovery import set** — drop the JSON to a monitored share and
   use a Transform Map to load it as a scheduled job.

Critical-severity findings (MISSING resources) can auto-create Incidents;
High-severity drift can create Problem records or trigger Change requests.

---

## Assumptions

- **No live Azure connection required.** Actual state is pre-collected and
  serialised; the module is pure PowerShell with no Az module dependency, making
  it portable and fully testable in CI.
- **One resource type.** Only VMs are modelled. The `Compare-VMConfiguration`
  / `Compare-Tags` pattern is deliberately generic and can be extended to Storage
  Accounts, NSGs, Key Vaults, etc. with a new comparison function per type.
- **Desired state is the policy source of truth.** Extra properties present only
  in actual state are silently ignored; only properties declared in desired state
  are enforced.
- **Tags are additive.** Actual resources may carry tags not declared in desired
  state (e.g. auto-generated tags) without triggering drift.

---

## What I Would Do Next With More Time

1. **Live Azure collection step** — a `Get-AzVMActualState.ps1` script using
   `Get-AzVM` that generates `actual-state.json` as a pipeline pre-step.
2. **Per-property weight system** — allow desired state to declare a `weight` on
   each property so that a missed `CostCenter` tag doesn't count the same as a
   wrong `location`.
3. **Remediation hints** — attach ARM/Bicep snippets to drift items so operators
   get copy-paste fix guidance in the ServiceNow finding.
4. **Historical trending** — persist each run's summary in a lightweight store
   (Azure Table Storage or a flat JSONL file) to plot score trends over time.
5. **Multi-resource-type support** — extend the module to handle NSGs, Storage
   Accounts, and Key Vaults with a registry pattern rather than hardcoded functions.

---

## AI Usage Note

Claude (claude-sonnet-4-6) was used as a coding assistant throughout this exercise.

**Where it helped:**
- Initial scaffolding of the module, Pester test structure, and GitHub Actions workflow — getting a working skeleton in one pass rather than starting from a blank file.
- Suggesting the `ConvertTo-TagHashtable` helper to normalise `PSCustomObject` tag bags into plain hashtables, which makes comparison logic cleaner and avoids property-access fragility.
- Drafting the ServiceNow field-mapping table and the severity taxonomy for drift items.
- Structuring the scoring model as a weighted aggregate (`Σ PassedChecks / Σ TotalChecks`) rather than a simple resource-level average, so a VM with 8 checks doesn't count the same as one with 2.

**What it got wrong — and what I corrected:**

1. **`Set-StrictMode` + missing property access.**
   The generated module set `Set-StrictMode -Version Latest` (correct) but then accessed `$Desired.tags` directly. When a `PSCustomObject` doesn't declare a `tags` property, strict mode throws `"The property 'tags' cannot be found"`. Fixed by guarding access with `$Desired.PSObject.Properties['tags']` before using the value.

2. **`[PSCustomObject]` typed parameter rejecting explicit `$null`.**
   `Compare-Tags` declared `[PSCustomObject]$ActualTags`. Passing `-ActualTags $null` in a direct call (not inside a scriptblock) raised a `ParameterBindingException`. The fix was to remove the type constraint and let the internal `ConvertTo-TagHashtable` handle null — the function already did so correctly.

3. **`Should -All { scriptblock }` is not valid Pester v5 syntax.**
   The generated test used `$collection | Should -All { $_ -eq '(missing)' }`, which Pester 5.7 rejects with a `ParameterBindingException`. The correct approach for this assertion in Pester v5 is a plain `foreach` loop with individual `Should -Be` assertions.

4. **MISSING resource check count was imprecise.**
   The first draft hardcoded `TotalChecks = $checkedProperties.Count + 1` for MISSING resources (the `+1` was meant to represent tags as a single slot). This skews the overall integrity score. Fixed to count the actual number of declared tag properties in the desired spec, making the denominator consistent with present resources.
