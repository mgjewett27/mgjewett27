<#
.SYNOPSIS
    Runs PSScriptAnalyzer and the Pester tests for SqlAutoInstall, the same way locally and in GitHub Actions.

.DESCRIPTION
    Installs any missing test modules for the current user, then:
      1. PSScriptAnalyzer over the module. Any Error fails the run, warnings are reported only.
      2. Pester over tests\, writing JUnit results and code coverage to TestResults\.

    Exits non-zero when either step fails, so a CI job fails with it.

.PARAMETER SkipInstall
    Use whatever modules are already installed instead of checking PSGallery.

.EXAMPLE
    & '.\Automated Install\build\Invoke-CI.ps1'
#>
[CmdletBinding()]
param(
    [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Path $PSScriptRoot -Parent
$resultsPath = Join-Path $root 'TestResults'
New-Item -Path $resultsPath -ItemType Directory -Force | Out-Null

#dbatools is needed because the module manifest requires it, tests mock every dbatools call
$requiredModules = @(
    @{ Name = 'Pester'; MinimumVersion = '5.5.0' }
    @{ Name = 'PSScriptAnalyzer'; MinimumVersion = '1.21.0' }
    @{ Name = 'dbatools'; MinimumVersion = '2.1.0' }
)

if (-not $SkipInstall) {
    foreach ($module in $requiredModules) {
        $installed = Get-Module -ListAvailable -Name $module.Name | Where-Object Version -ge ([version]$module.MinimumVersion)
        if (-not $installed) {
            Write-Host "Installing $($module.Name) $($module.MinimumVersion)+" -ForegroundColor Cyan
            Install-Module -Name $module.Name -MinimumVersion $module.MinimumVersion -Scope CurrentUser -Force -SkipPublisherCheck -AllowClobber
        }
    }
}
Import-Module Pester -MinimumVersion 5.5.0 -Force

Write-Host "`n== PSScriptAnalyzer ==" -ForegroundColor Cyan
$analysis = Invoke-ScriptAnalyzer -Path (Join-Path $root 'SqlAutoInstall') -Recurse -Severity Error, Warning
$analysis | Format-Table -Property Severity, RuleName, ScriptName, Line, Message -AutoSize -Wrap | Out-String | Write-Host
$analyzerErrors = @($analysis | Where-Object Severity -eq 'Error')
Write-Host "Analyzer: $($analyzerErrors.Count) error(s), $(@($analysis).Count - $analyzerErrors.Count) warning(s)"

Write-Host "`n== Pester ==" -ForegroundColor Cyan
$config = New-PesterConfiguration
$config.Run.Path = Join-Path $root 'tests'
$config.Run.PassThru = $true
#Normal lists failures only, Detailed also dumps every uncovered line
$config.Output.Verbosity = 'Normal'
$config.TestResult.Enabled = $true
$config.TestResult.OutputFormat = 'JUnitXml'
$config.TestResult.OutputPath = Join-Path $resultsPath 'pester-results.xml'
$config.CodeCoverage.Enabled = $true
$config.CodeCoverage.Path = Join-Path $root 'SqlAutoInstall'
$config.CodeCoverage.OutputFormat = 'JaCoCo'
$config.CodeCoverage.OutputPath = Join-Path $resultsPath 'coverage.xml'
$pester = Invoke-Pester -Configuration $config

$coverage = if ($pester.CodeCoverage) { [math]::Round($pester.CodeCoverage.CoveragePercent, 1) } else { 0 }
$summary = "Pester: $($pester.PassedCount) passed, $($pester.FailedCount) failed. Coverage: $coverage%. Analyzer errors: $($analyzerErrors.Count)."
Write-Host "`n$summary" -ForegroundColor Cyan

#Shows on the workflow run's summary page in GitHub Actions
if ($env:GITHUB_STEP_SUMMARY) {
    $lines = @(
        '### SqlAutoInstall CI'
        ''
        '| Check | Result |'
        '|---|---|'
        "| Pester | $($pester.PassedCount) passed, $($pester.FailedCount) failed |"
        "| Code coverage | $coverage% |"
        "| PSScriptAnalyzer | $($analyzerErrors.Count) errors, $(@($analysis).Count - $analyzerErrors.Count) warnings |"
    )
    $lines | Add-Content -Path $env:GITHUB_STEP_SUMMARY
}

if ($pester.FailedCount -gt 0 -or $pester.Result -ne 'Passed' -or $analyzerErrors.Count -gt 0) {
    exit 1
}
