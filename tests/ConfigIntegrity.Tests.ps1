<#
.SYNOPSIS
    Pester v5 tests for the ConfigIntegrity module.
#>

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '../src/ConfigIntegrity.psm1'
    Import-Module $modulePath -Force

    # ── Shared test fixture factory ────────────────────────────────────────
    function New-TestVM {
        param (
            [string]$Name            = 'vm-test-01',
            [string]$ResourceGroup   = 'rg-test',
            [string]$VmSize          = 'Standard_D2s_v3',
            [string]$Location        = 'eastus',
            [string]$OsType          = 'Windows',
            [string]$OsDiskType      = 'Premium_LRS',
            [bool]  $DiagEnabled     = $true,
            [hashtable]$Tags         = @{ Environment = 'Production'; Owner = 'team-a'; CostCenter = 'CC-001' }
        )
        $tagObj = [PSCustomObject]$Tags
        return [PSCustomObject]@{
            name               = $Name
            resourceGroup      = $ResourceGroup
            vmSize             = $VmSize
            location           = $Location
            osType             = $OsType
            osDiskType         = $OsDiskType
            diagnosticsEnabled = $DiagEnabled
            tags               = $tagObj
        }
    }
}

# ────────────────────────────────────────────────────────────────────────────
Describe 'Compare-VMConfiguration' {

    Context 'Fully compliant — desired matches actual exactly' {
        It 'Returns COMPLIANT status' {
            $vm     = New-TestVM
            $result = Compare-VMConfiguration -Desired $vm -Actual $vm

            $result.Status     | Should -Be 'COMPLIANT'
            $result.Score      | Should -Be 100
            $result.DriftItems | Should -HaveCount 0
        }

        It 'PassedChecks equals TotalChecks' {
            $vm     = New-TestVM
            $result = Compare-VMConfiguration -Desired $vm -Actual $vm

            $result.PassedChecks | Should -Be $result.TotalChecks
        }
    }

    Context 'Single scalar property drifted — vmSize' {
        It 'Returns DRIFTED status with one drift item' {
            $desired = New-TestVM -VmSize 'Standard_D2s_v3'
            $actual  = New-TestVM -VmSize 'Standard_D4s_v3'

            $result = Compare-VMConfiguration -Desired $desired -Actual $actual

            $result.Status     | Should -Be 'DRIFTED'
            $result.DriftItems | Should -HaveCount 1
        }

        It 'Drift item captures expected and actual values correctly' {
            $desired = New-TestVM -VmSize 'Standard_D2s_v3'
            $actual  = New-TestVM -VmSize 'Standard_D4s_v3'

            $result = Compare-VMConfiguration -Desired $desired -Actual $actual
            $item   = $result.DriftItems[0]

            $item.Property | Should -Be 'vmSize'
            $item.Expected | Should -Be 'Standard_D2s_v3'
            $item.Actual   | Should -Be 'Standard_D4s_v3'
            $item.Severity | Should -Be 'High'
        }
    }

    Context 'Multiple scalar properties drifted' {
        It 'Flags all drifted properties' {
            $desired = New-TestVM -VmSize 'Standard_D2s_v3' -OsDiskType 'Premium_LRS' -DiagEnabled $true
            $actual  = New-TestVM -VmSize 'Standard_D4s_v3' -OsDiskType 'Standard_LRS' -DiagEnabled $false

            $result     = Compare-VMConfiguration -Desired $desired -Actual $actual
            $properties = $result.DriftItems.Property

            $properties | Should -Contain 'vmSize'
            $properties | Should -Contain 'osDiskType'
            $properties | Should -Contain 'diagnosticsEnabled'
        }
    }

    Context 'Resource not found in actual environment (null)' {
        It 'Returns MISSING status' {
            $result = Compare-VMConfiguration -Desired (New-TestVM) -Actual $null

            $result.Status | Should -Be 'MISSING'
        }

        It 'Returns score of 0' {
            $result = Compare-VMConfiguration -Desired (New-TestVM) -Actual $null

            $result.Score | Should -Be 0
        }

        It 'Has zero PassedChecks' {
            $result = Compare-VMConfiguration -Desired (New-TestVM) -Actual $null

            $result.PassedChecks | Should -Be 0
        }

        It 'TotalChecks reflects all properties that would have been evaluated' {
            $result = Compare-VMConfiguration -Desired (New-TestVM) -Actual $null

            # 5 scalar properties + 3 tags = 8
            $result.TotalChecks | Should -Be 8
        }
    }

    Context 'Tag drift — required tag missing from actual' {
        It 'Returns DRIFTED and includes the missing tag' {
            $desired = New-TestVM -Tags @{ Environment = 'Production'; CostCenter = 'CC-001' }
            $actual  = New-TestVM -Tags @{ Environment = 'Production' }

            $result   = Compare-VMConfiguration -Desired $desired -Actual $actual
            $tagDrift = $result.DriftItems | Where-Object { $_.Property -eq 'tag:CostCenter' }

            $result.Status | Should -Be 'DRIFTED'
            $tagDrift      | Should -Not -BeNullOrEmpty
            $tagDrift.Actual   | Should -Be '(missing)'
            $tagDrift.Expected | Should -Be 'CC-001'
        }
    }

    Context 'Tag drift — tag value mismatch' {
        It 'Reports the wrong tag value' {
            $desired = New-TestVM -Tags @{ Environment = 'Production' }
            $actual  = New-TestVM -Tags @{ Environment = 'Development' }

            $result = Compare-VMConfiguration -Desired $desired -Actual $actual
            $item   = $result.DriftItems | Where-Object { $_.Property -eq 'tag:Environment' }

            $item.Expected | Should -Be 'Production'
            $item.Actual   | Should -Be 'Development'
        }
    }

    Context 'Edge case — extra tags in actual are not flagged as drift' {
        It 'Returns COMPLIANT when actual has additional tags beyond desired' {
            $desired = New-TestVM -Tags @{ Environment = 'Production' }
            $actual  = New-TestVM -Tags @{ Environment = 'Production'; ExtraTag = 'Unexpected' }

            $result = Compare-VMConfiguration -Desired $desired -Actual $actual

            $result.Status     | Should -Be 'COMPLIANT'
            $result.DriftItems | Should -HaveCount 0
        }
    }

    Context 'Edge case — desired has no tags defined' {
        It 'Does not error and evaluates only scalar properties' {
            $desired = [PSCustomObject]@{
                name               = 'vm-notags'
                resourceGroup      = 'rg-test'
                vmSize             = 'Standard_B2s'
                location           = 'eastus'
                osType             = 'Linux'
                osDiskType         = 'Standard_LRS'
                diagnosticsEnabled = $false
            }
            $actual = $desired.PSObject.Copy()

            { Compare-VMConfiguration -Desired $desired -Actual $actual } | Should -Not -Throw
        }
    }
}

# ────────────────────────────────────────────────────────────────────────────
Describe 'Compare-Tags' {

    It 'Returns zero drift when tags match' {
        $tags   = [PSCustomObject]@{ Env = 'Prod'; Owner = 'team' }
        $result = Compare-Tags -DesiredTags $tags -ActualTags $tags

        $result.TotalTagChecks  | Should -Be 2
        $result.PassedTagChecks | Should -Be 2
        $result.DriftItems      | Should -HaveCount 0
    }

    It 'Handles null ActualTags without throwing' {
        $tags = [PSCustomObject]@{ Env = 'Prod' }
        { Compare-Tags -DesiredTags $tags -ActualTags $null } | Should -Not -Throw
    }

    It 'Flags all desired tags as missing when actual has no tags' {
        $tags   = [PSCustomObject]@{ Env = 'Prod'; Owner = 'team' }
        # Omitting ActualTags (optional parameter) is equivalent to passing $null
        $result = Compare-Tags -DesiredTags $tags

        $result.DriftItems | Should -HaveCount 2
        foreach ($item in $result.DriftItems) {
            $item.Actual | Should -Be '(missing)'
        }
    }
}

# ────────────────────────────────────────────────────────────────────────────
Describe 'Get-IntegrityScore' {

    It 'Returns 100 and PASS when all checks pass' {
        $results = @(
            @{ TotalChecks = 8; PassedChecks = 8 },
            @{ TotalChecks = 8; PassedChecks = 8 }
        )
        $score = Get-IntegrityScore -Results $results

        $score.Score  | Should -Be 100
        $score.Status | Should -Be 'PASS'
    }

    It 'Returns PASS for score >= 90' {
        $results = @(@{ TotalChecks = 10; PassedChecks = 9 })
        $score   = Get-IntegrityScore -Results $results

        $score.Status | Should -Be 'PASS'
    }

    It 'Returns WARNING for score between 70 and 89' {
        $results = @(@{ TotalChecks = 10; PassedChecks = 8 })
        $score   = Get-IntegrityScore -Results $results

        $score.Status | Should -Be 'WARNING'
    }

    It 'Returns FAIL for score below 70' {
        $results = @(@{ TotalChecks = 10; PassedChecks = 5 })
        $score   = Get-IntegrityScore -Results $results

        $score.Status | Should -Be 'FAIL'
    }

    It 'Weights checks across multiple resources correctly' {
        # 8 passed out of 16 total = 50% → FAIL
        $results = @(
            @{ TotalChecks = 8; PassedChecks = 8 },
            @{ TotalChecks = 8; PassedChecks = 0 }
        )
        $score = Get-IntegrityScore -Results $results

        $score.Score  | Should -Be 50
        $score.Status | Should -Be 'FAIL'
    }

    It 'Edge case: returns 100 and PASS when TotalChecks is zero' {
        $results = @(@{ TotalChecks = 0; PassedChecks = 0 })
        $score   = Get-IntegrityScore -Results $results

        $score.Score  | Should -Be 100
        $score.Status | Should -Be 'PASS'
    }
}
