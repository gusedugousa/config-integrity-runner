<#
.SYNOPSIS
    ConfigIntegrity module — compares desired-state VM definitions against actual state,
    flags configuration drift, and produces a scoring report.

.NOTES
    Designed to run without a live Azure connection; actual-state data is expected
    to be pre-fetched (e.g. via Get-AzVM) and serialised to JSON.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Properties evaluated for every VM resource.
$script:ScalarProperties = @('vmSize', 'location', 'osType', 'osDiskType', 'diagnosticsEnabled')

# Severity map — drives downstream triage priority in ServiceNow.
$script:PropertySeverity = @{
    vmSize             = 'High'
    location           = 'High'
    osType             = 'High'
    osDiskType         = 'Medium'
    diagnosticsEnabled = 'Medium'
}

#region ── Internal helpers ──────────────────────────────────────────────────

function ConvertTo-TagHashtable {
    <#
    .SYNOPSIS  Normalises a PSCustomObject tag bag into a plain [hashtable].
    #>
    param ([Parameter(Mandatory=$false)][PSCustomObject]$TagObject)

    $ht = @{}
    if ($null -eq $TagObject) { return $ht }
    $TagObject.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
    return $ht
}

#endregion

#region ── Public functions ──────────────────────────────────────────────────

function Compare-Tags {
    <#
    .SYNOPSIS
        Compares desired tags against actual tags for a single resource.
        Extra tags present only in actual state are NOT flagged as drift.

    .OUTPUTS
        [hashtable] with keys: TotalTagChecks, PassedTagChecks, DriftItems
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)][PSCustomObject]$DesiredTags,
        [Parameter(Mandatory=$false)]$ActualTags
    )

    $desired    = ConvertTo-TagHashtable -TagObject $DesiredTags
    $actual     = ConvertTo-TagHashtable -TagObject $ActualTags
    $driftItems = [System.Collections.Generic.List[hashtable]]::new()
    $total      = 0
    $passed     = 0

    foreach ($key in $desired.Keys) {
        $total++
        if (-not $actual.ContainsKey($key)) {
            $driftItems.Add(@{
                Property = "tag:$key"
                Expected = $desired[$key]
                Actual   = '(missing)'
                Severity = 'Medium'
            })
        } elseif ($actual[$key] -ne $desired[$key]) {
            $driftItems.Add(@{
                Property = "tag:$key"
                Expected = $desired[$key]
                Actual   = $actual[$key]
                Severity = 'Low'
            })
        } else {
            $passed++
        }
    }

    return @{
        TotalTagChecks  = $total
        PassedTagChecks = $passed
        DriftItems      = $driftItems.ToArray()
    }
}

function Compare-VMConfiguration {
    <#
    .SYNOPSIS
        Compares one VM's desired configuration against its actual state.

    .PARAMETER Desired
        PSCustomObject representing the desired VM definition.

    .PARAMETER Actual
        PSCustomObject representing the actual VM state, or $null if the resource
        was not found in the environment.

    .OUTPUTS
        [hashtable] with keys: Name, ResourceGroup, Status, Score,
                               DriftItems, TotalChecks, PassedChecks
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)][PSCustomObject]$Desired,
        [Parameter(Mandatory=$false)][PSCustomObject]$Actual
    )

    # Strict-mode-safe check: access tags only if the property is declared.
    $desiredHasTags = $null -ne $Desired.PSObject.Properties['tags']
    $actualHasTags  = ($null -ne $Actual) -and ($null -ne $Actual.PSObject.Properties['tags'])

    # ── MISSING: resource not found in actual environment ──────────────────
    if ($null -eq $Actual) {
        $desiredTagCount = if ($desiredHasTags) {
            ($Desired.tags.PSObject.Properties | Measure-Object).Count
        } else { 0 }

        return @{
            Name          = $Desired.name
            ResourceGroup = $Desired.resourceGroup
            Status        = 'MISSING'
            Score         = 0
            DriftItems    = @(@{
                Property  = 'resource'
                Expected  = 'present'
                Actual    = 'not found in environment'
                Severity  = 'Critical'
            })
            TotalChecks   = $script:ScalarProperties.Count + $desiredTagCount
            PassedChecks  = 0
        }
    }

    # ── PRESENT: compare property by property ─────────────────────────────
    $driftItems = [System.Collections.Generic.List[hashtable]]::new()
    $total      = 0
    $passed     = 0

    foreach ($prop in $script:ScalarProperties) {
        $total++
        $desiredVal = $Desired.$prop
        $actualVal  = $Actual.$prop

        if ($desiredVal -ne $actualVal) {
            $driftItems.Add(@{
                Property  = $prop
                Expected  = "$desiredVal"
                Actual    = "$actualVal"
                Severity  = $script:PropertySeverity[$prop]
            })
        } else {
            $passed++
        }
    }

    # Tags
    if ($desiredHasTags) {
        $actualTags = if ($actualHasTags) { $Actual.tags } else { $null }
        $tagResult  = Compare-Tags -DesiredTags $Desired.tags -ActualTags $actualTags
        $total     += $tagResult.TotalTagChecks
        $passed    += $tagResult.PassedTagChecks
        foreach ($item in $tagResult.DriftItems) { $driftItems.Add($item) }
    }

    $score  = if ($total -gt 0) { [math]::Round(($passed / $total) * 100, 1) } else { 100 }
    $status = if ($driftItems.Count -eq 0) { 'COMPLIANT' } else { 'DRIFTED' }

    return @{
        Name          = $Desired.name
        ResourceGroup = $Desired.resourceGroup
        Status        = $status
        Score         = $score
        DriftItems    = $driftItems.ToArray()
        TotalChecks   = $total
        PassedChecks  = $passed
    }
}

function Get-IntegrityScore {
    <#
    .SYNOPSIS
        Aggregates per-resource check results into a single weighted integrity score.

    .DESCRIPTION
        Score = (sum of all PassedChecks) / (sum of all TotalChecks) * 100
        Thresholds:  >= 90 → PASS   |   >= 70 → WARNING   |   < 70 → FAIL

    .OUTPUTS
        [hashtable] with keys: Score, Status
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)][hashtable[]]$Results
    )

    $totalChecks  = 0
    $passedChecks = 0
    foreach ($r in $Results) {
        $totalChecks  += $r.TotalChecks
        $passedChecks += $r.PassedChecks
    }

    $score = if ($totalChecks -gt 0) {
        [math]::Round(($passedChecks / $totalChecks) * 100, 1)
    } else { 100 }

    $status = if    ($score -ge 90) { 'PASS'    }
              elseif ($score -ge 70) { 'WARNING' }
              else                   { 'FAIL'    }

    return @{ Score = $score; Status = $status }
}

function Invoke-ConfigIntegrityCheck {
    <#
    .SYNOPSIS
        Orchestrates a full desired-vs-actual comparison run and writes a JSON report.

    .PARAMETER DesiredStatePath   Path to desired-state JSON file.
    .PARAMETER ActualStatePath    Path to actual-state JSON file.
    .PARAMETER OutputPath         Optional path to write the JSON report.

    .OUTPUTS
        [ordered hashtable] — the full report object (also serialised to $OutputPath).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$DesiredStatePath,
        [Parameter(Mandatory)][string]$ActualStatePath,
        [string]$OutputPath
    )

    # ── Load inputs ────────────────────────────────────────────────────────
    $desired = Get-Content $DesiredStatePath -Raw | ConvertFrom-Json
    $actual  = Get-Content $ActualStatePath  -Raw | ConvertFrom-Json

    # Index actual resources by name for O(1) lookup
    $actualIndex = @{}
    foreach ($vm in $actual.resources) { $actualIndex[$vm.name] = $vm }

    # ── Compare ────────────────────────────────────────────────────────────
    $results = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($desiredVM in $desired.resources) {
        $actualVM = $actualIndex[$desiredVM.name]
        $results.Add((Compare-VMConfiguration -Desired $desiredVM -Actual $actualVM))
    }

    # ── Score ──────────────────────────────────────────────────────────────
    $scoreData = Get-IntegrityScore -Results $results.ToArray()

    $compliant = @($results | Where-Object { $_.Status -eq 'COMPLIANT' }).Count
    $drifted   = @($results | Where-Object { $_.Status -eq 'DRIFTED'   }).Count
    $missing   = @($results | Where-Object { $_.Status -eq 'MISSING'   }).Count

    $report = [ordered]@{
        RunId   = (Get-Date -Format 'o')
        Summary = [ordered]@{
            TotalResources = $results.Count
            Compliant      = $compliant
            Drifted        = $drifted
            Missing        = $missing
            IntegrityScore = $scoreData.Score
            Status         = $scoreData.Status
        }
        Resources = $results.ToArray()
    }

    # ── Output ─────────────────────────────────────────────────────────────
    $json = $report | ConvertTo-Json -Depth 10

    if ($OutputPath) {
        $outputDir = Split-Path $OutputPath -Parent
        if ($outputDir -and -not (Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir | Out-Null
        }
        $json | Set-Content -Path $OutputPath -Encoding UTF8
        Write-Host "Report written to: $OutputPath"
    }

    Write-IntegrityReport -Report $report
    return $report
}

function Write-IntegrityReport {
    <#
    .SYNOPSIS  Writes a human-readable summary of the integrity report to the console.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)][hashtable]$Report)

    $s = $Report.Summary
    Write-Host ''
    Write-Host '============================================'
    Write-Host '  Configuration Integrity Report'
    Write-Host '============================================'
    Write-Host "  Score  : $($s.IntegrityScore)%  [$($s.Status)]"
    Write-Host "  Total  : $($s.TotalResources)   Compliant: $($s.Compliant)   Drifted: $($s.Drifted)   Missing: $($s.Missing)"
    Write-Host '============================================'

    foreach ($r in $Report.Resources) {
        $icon = switch ($r.Status) {
            'COMPLIANT' { '[  OK  ]' }
            'DRIFTED'   { '[ DRIFT ]' }
            'MISSING'   { '[MISSING]' }
        }
        Write-Host "$icon  $($r.Name)  ($($r.ResourceGroup))  —  Score: $($r.Score)%"
        foreach ($d in $r.DriftItems) {
            Write-Host "           [$($d.Severity.PadRight(8))]  $($d.Property): expected='$($d.Expected)'  actual='$($d.Actual)'"
        }
    }
    Write-Host ''
}

#endregion

Export-ModuleMember -Function Compare-VMConfiguration, Compare-Tags, Get-IntegrityScore,
                               Invoke-ConfigIntegrityCheck, Write-IntegrityReport
