BeforeAll {
    . $PSScriptRoot/../SCEPman/Private/az-commands.ps1
    . $PSScriptRoot/../SCEPman/Private/subscriptions.ps1
}


Describe 'Geos' {
    BeforeAll {
        Mock Invoke-Az {
            param($azCommand)

            if ($azCommand[0] -ne 'account' -or $azCommand[1] -ne 'list-locations')
            {
                throw "Unexpected command: $azCommand"
            }

            return Get-Content -Path "./Tests/Data/locations.json"
        }
    }

    It 'Finds whether two regions are in the same geo' {
        $result = AreTwoRegionsInTheSameGeo -Region1 "eastus" -Region2 "eastus2"

        $result | Should -Be $true
    }

    It 'Finds when to regions are in different geos' {
        $result = AreTwoRegionsInTheSameGeo -Region1 "eastus" -Region2 "northeurope"

        $result | Should -Be $false
    }
}