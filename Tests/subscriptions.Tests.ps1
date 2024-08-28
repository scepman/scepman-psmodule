BeforeAll {
    . $PSScriptRoot/../SCEPman/Private/az-commands.ps1
    . $PSScriptRoot/../SCEPman/Private/subscriptions.ps1
}


Describe 'Geos' {
    BeforeAll {
        Mock Invoke-Az {
            param($azCommand)

            if ($azCommand[0] -eq 'account' -and $azCommand[1] -eq 'list-locations') 
            {
                return Get-Content -Path "./Tests/Data/locations.json"
            }

            throw "Unexpected command: $azCommand"
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

Describe 'GetResources' {
    BeforeAll {
        Mock Invoke-Az {
            param($Command)

            if ($Command[0] -eq "graph" -and $Command[1] -eq "query")
            {
                return Get-Content -Path "./Tests/Data/subscriptions.json"
            } 

            throw "Unexpected command: $Command"
        }
    }

    It 'Can successfully get matching subscription details' {
        $subscriptionsJson = Get-Content -Path "./Tests/Data/accounts.json"
        $subscriptions = Convert-LinesToObject $subscriptionsJson
        $result = GetSubscriptionDetailsUsingAppName -AppServiceName "app-service-name" -subscriptions $subscriptions

        $expected = $subscriptions[0], $subscriptions[1]
        $result | Should -Be $expected
    }

    
    It 'Will throw an error if no matching subscription exists from graph' {
        $subscriptionsJson = Get-Content -Path "./Tests/Data/accounts-no-match.json"
        $subscriptions = Convert-LinesToObject $subscriptionsJson
        { GetSubscriptionDetailsUsingAppName -AppServiceName "app-service-name" -subscriptions $subscriptions } | Should -Throw
    }

    It 'Will throw an error if graph query has no output' {
        Mock Invoke-Az {
            param($Command)

            if ($Command[0] -eq "graph" -and $Command[1] -eq "query")
            {
                return $null
            } 

            throw "Unexpected command: $Command"
        }

        $subscriptionsJson = Get-Content -Path "./Tests/Data/accounts.json"
        $subscriptions = Convert-LinesToObject $subscriptionsJson
        { GetSubscriptionDetailsUsingAppName -AppServiceName "app-service-name" -subscriptions $subscriptions } | Should -Throw

    }


}
