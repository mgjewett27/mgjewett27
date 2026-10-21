@{
    RootModule        = 'SqlAutoInstall.psm1'
    ModuleVersion     = '2.0.0'
    GUID              = 'b6f1d0c2-6a8e-4c43-9a57-3f2e8d4b7a10'
    Author            = 'Mike Jewett'
    Description       = 'Builds a blank Windows cluster node into a patched, maintained and monitored SQL Server instance.'
    PowerShellVersion = '5.1'
    # 2.1.0 is the oldest version this module has been tested with
    RequiredModules   = @(@{ ModuleName = 'dbatools'; ModuleVersion = '2.1.0' })
    FunctionsToExport = @('Invoke-SqlBuild', 'Test-SqlBuild')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
