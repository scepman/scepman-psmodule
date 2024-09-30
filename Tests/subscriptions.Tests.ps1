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

Describe 'Get-SubscriptionDetailsUsingAppName' {
    BeforeAll {
        Mock Invoke-Az {
            param($azCommand)

            if ($azCommand[0] -eq "graph" -and $azCommand[1] -eq "query")
            {
                return Get-Content -Path "./Tests/Data/subscriptions.json"
            }

            throw "Unexpected command: $Command"
        }
    }

    It 'Can successfully get matching subscription details' {
        $subscriptionsJson = Get-Content -Path "./Tests/Data/accounts.json"
        $subscriptions = Convert-LinesToObject $subscriptionsJson
        $result = Get-SubscriptionDetailsUsingAppName -AppServiceName "app-service-name" -subscriptions $subscriptions
        $expected = $subscriptions[0]
        $result | Should -Be $expected
    }


    It 'Will throw an error if no matching subscription exists in accounts' {
        $subscriptionsJson = Get-Content -Path "./Tests/Data/accounts-no-match.json"
        $subscriptions = Convert-LinesToObject $subscriptionsJson
        { Get-SubscriptionDetailsUsingAppName -AppServiceName "app-service-name" -subscriptions $subscriptions 2>$null } | Should -Throw
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

Describe 'GetSubscriptionDetails' {
    BeforeAll {
        Mock az {
            param($azCommand)

            if ($azCommand -eq "account")
            {
                return Get-Content -Path "./Tests/Data/accounts.json"
            }
            elseif ($azCommand -eq "graph")
            {
                return Get-Content -Path "./Tests/Data/subscriptions.json"
            }

            throw "Unexpected command: $azCommand"
        }

        Mock Invoke-Az {
            param($azCommand)

            if ($azCommand[0] -eq "graph" -and $azCommand[1] -eq "query")
            {
                return Get-Content -Path "./Tests/Data/subscriptions.json"
            }

            throw "Unexpected command: $azCommand"
        }
    }

    It 'Can successfully get matching subscription details' {
        $result = GetSubscriptionDetails -SubscriptionId "subscription-id"
        $subscriptions = Convert-LinesToObject $(Get-Content -Path "./Tests/Data/accounts.json")

        $expected = $subscriptions[0]
        # TODO: Work out why pester doesn't think these two objects are equal when they clearly are (without ["id"])
        $result["id"] | Should -Be $expected["id"]
    }

    It 'Lets you select a subscription with the app service name flag' {
        $result = GetSubscriptionDetails -SearchAllSubscriptions $true -AppServiceName app-service-name
        $subscriptionsJson = Get-Content -Path "./Tests/Data/accounts.json"
        $subscriptions = Convert-LinesToObject $subscriptionsJson

        $expected = $subscriptions[0]
        $result["id"] | Should -Be $expected["id"]
    }

    It 'Lets you select a subscription with the app service plan name flag' {
        $result = GetSubscriptionDetails -SearchAllSubscriptions $true -AppServicePlanName app-service-plan-name
        $subscriptionsJson = Get-Content -Path "./Tests/Data/accounts.json"
        $subscriptions = Convert-LinesToObject $subscriptionsJson

        $expected = $subscriptions[0]
        $result["id"] | Should -Be $expected["id"]
    }

    It 'Will return a single subscription if only 1 exists' {
        Mock az {
            param($Command)

            if ($Command -eq "account")
            {
                return Get-Content -Path "./Tests/Data/accounts-no-match.json"
            }
        }
        $result = GetSubscriptionDetails -SearchAllSubscriptions $true
        $subscriptionsJson = Get-Content -Path "./Tests/Data/accounts-no-match.json"
        $subscriptions = Convert-LinesToObject $subscriptionsJson

        $expected = $subscriptions[0]
        $result["id"] | Should -Be $expected["id"]

    }

    It 'Will throw an error if no matching subscription exists in accounts' {
        { GetSubscriptionDetails -SubscriptionId "incorrect-subscription-id" 3>$null } | Should -Throw
    }

    It 'Will throw an error if no id, app service name or app service plan name (and multiple subscriptions)' {
        { GetSubscriptionDetails -SearchAllSubscriptions $true } | Should -Throw
    }

    # TODO: how to simulate user input inline??
    # Write-Output 1 | GetSubscriptionDetails
}