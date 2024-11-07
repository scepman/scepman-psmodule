BeforeAll {
    . $PSScriptRoot/../SCEPman/Private/az-commands.ps1
}

Describe 'az-commands' {
    It 'Should find that this test does not run in Azure Cloud Shell' {
        $isAzureCloudShell = IsAzureCloudShell
        $isAzureCloudShell | Should -Be $false
    }
}