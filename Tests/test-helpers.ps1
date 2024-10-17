function NormalizeNativeParameters($argsFromCommand) {
    if ($argsFromCommand[0].Count -gt 1) {  # Sometimes the args are passed as an array as the first element of the args array. Sometimes they are the first array directly
        $argsFromCommand = $argsFromCommand[0]
    }

    $quotedCommandArguments = $argsFromCommand | ForEach-Object {
        if ($_.Contains(' ')) {
            return "`"$($_)`""
        } else {
            return $_
        }
    }
    return $quotedCommandArguments -join ' '
}

function CheckAzParameters($argsFromCommand, [string] $azCommandPrefix = $null, [string] $azCommandMidfix = $null, [string] $azCommandSuffix = $null) {
    $theCommand = NormalizeNativeParameters -argsFromCommand $argsFromCommand

    if ($azCommandPrefix -ne $null -and -not $theCommand.StartsWith($azCommandPrefix)) {
        return $false
    }

    if ($azCommandMidfix -ne $null -and -not $theCommand.Contains($azCommandMidfix)) {
        return $false
    }

    if ($azCommandSuffix -ne $null -and -not $theCommand.EndsWith($azCommandSuffix)) {
        return $false
    }

    return $true
}

function EnsureNoAdditionalAzCalls {
    Mock az {
        $theCommand = NormalizeNativeParameters -argsFromCommand $args
        throw "Unexpected parameter for az: $theCommand (with array values $($args[0]), $($args[1]), ... -- #$($args.Count) in total)"
    }
}

function MockAzInitals ([bool]$findSubscription = $true) {
    function GetSubscriptionDetails ([bool]$SearchAllSubscriptions, $SubscriptionId, $AppServiceName, $AppServicePlanName) { }  # Mocked

    MockAzVersion
    Mock AzLogin {
        return $null
    }
    if ($findSubscription) {
        Mock GetSubscriptionDetails {
            return @{
                "name" = "Test Subscription"
                "tenantId" = "123"
                "id" = "12345678-1234-1234-aaaabbbbcccc"
            }
        } -ParameterFilter { $null -eq $AppServicePlanName }
    }
}

function CheckAzInitials ([bool]$findSubscription = $true) {
    Should -Invoke az -ParameterFilter { $args[0] -eq 'version' } -Exactly 1
    Should -Invoke AzLogin -Exactly 1
    if ($findSubscription) {
        Should -Invoke GetSubscriptionDetails -Exactly 1 -ParameterFilter { $null -eq $AppServicePlanName }
    }
}

function MockAzVersion {
    Mock az {
        return '{
  "azure-cli": "2.60.0",
  "azure-cli-core": "2.60.0",
  "azure-cli-telemetry": "1.1.0",
  "extensions": {
    "resource-graph": "2.1.0"
  }
}'
    } -ParameterFilter { $args[0] -eq 'version' }
}