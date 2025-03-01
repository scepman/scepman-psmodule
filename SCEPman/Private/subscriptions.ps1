function Get-SubscriptionDetailsUsingAppName($AppServiceName, $subscriptions) {
    Write-Information "Finding correct subscription for App Service $AppServiceName among the $($subscriptions.count) selected subscriptions"
    $subscriptionsJson = Invoke-Az -azCommand @("graph", "query", "-q", "Resources | where type == 'microsoft.web/sites' and name =~ '$AppServiceName' | project name, subscriptionId")
    $scWebAppsAcrossAllAccessibleSubscriptions = Convert-LinesToObject -lines $subscriptionsJson
    if($scWebAppsAcrossAllAccessibleSubscriptions.count -eq 1) {
        Write-Verbose "App Service $AppServiceName is in subscription $($scWebAppsAcrossAllAccessibleSubscriptions.data[0].subscriptionId)"
        $fittingSubscription = $subscriptions | Where-Object { $_.id -eq $scWebAppsAcrossAllAccessibleSubscriptions.data[0].subscriptionId }
        if ($null -eq $fittingSubscription) {
            $selectedSubscriptionString = $subscriptions | ForEach-Object { "$($_.id) - $($_.name)" } | Join-String -Separator ', '
            $errorMessage = "The subscription $($scWebAppsAcrossAllAccessibleSubscriptions.data[0].subscriptionId) is not among the selected subscriptions: $selectedSubscriptionString"
            Write-Error $errorMessage
            throw $errorMessage
        }

        return $fittingSubscription
    }

    $errorMessage = "We are unable to determine the correct subscription. Please start over"
    Write-Error $errorMessage
    throw $errorMessage
}

function Get-SubscriptionDetailsUsingPlanName($AppServicePlanName, $subscriptions) {
    Write-Information "Finding correct subscription for App Service Plan $AppServicePlanName among the $($subscriptions.count) selected subscriptions"
    $scPlansAcrossAllAccessibleSubscriptions = Invoke-Az -azCommand @('graph', 'query', '-q', "Resources | where type == 'microsoft.web/serverfarms' and name =~ '$AppServicePlanName' | project name, subscriptionId") | Convert-LinesToObject
    if($scPlansAcrossAllAccessibleSubscriptions.count -eq 1) {
        Write-Verbose "App Service Plan $AppServicePlanName is in subscription $($scPlansAcrossAllAccessibleSubscriptions.data[0].subscriptionId)"
        $fittingSubscription = $subscriptions | Where-Object { $_.id -eq $scPlansAcrossAllAccessibleSubscriptions.data[0].subscriptionId }
        if ($null -eq $fittingSubscription) {
            $selectedSubscriptionString = $subscriptions | ForEach-Object { "$($_.id) - $($_.name)" } | Join-String -Separator ', '
            $errorMessage = "The subscription $($scPlansAcrossAllAccessibleSubscriptions.data[0].subscriptionId) is not among the selected subscriptions: $selectedSubscriptionString"
            Write-Error $errorMessage
            throw $errorMessage
        }
        return $fittingSubscription
    }

    $errorMessage = "We are unable to determine the correct subscription. Please start over"
    Write-Error $errorMessage
    throw $errorMessage
}

function GetSubscriptionDetails ([bool]$SearchAllSubscriptions, $SubscriptionId, $AppServiceName, $AppServicePlanName) {
  $potentialSubscription = $null
  $subscriptions = Convert-LinesToObject -lines $(az account list)
  if($false -eq [String]::IsNullOrWhiteSpace($SubscriptionId)) {
    $potentialSubscription = $subscriptions | Where-Object { $_.id -eq $SubscriptionId }
    if($null -eq $potentialSubscription) {
        Write-Warning "We are unable to find the subscription with id $SubscriptionId"
        throw "We are unable to find the subscription with id $SubscriptionId"
    }
  }
  if($null -eq $potentialSubscription) {
    if($subscriptions.count -gt 1){
        if($SearchAllSubscriptions) {
            Write-Information "User pre-selected to search all subscriptions"
            $selection = 0
        } else {
            Write-Host "Multiple subscriptions found! Select a subscription where the SCEPman is installed or press '0' to search across all of the subscriptions"
            Write-Host "0: Search All Subscriptions | Press '0'"
            for($i = 0; $i -lt $subscriptions.count; $i++){
                Write-Host "$($i + 1): $($subscriptions[$i].name) | Subscription Id: $($subscriptions[$i].id) | Press '$($i + 1)' to use this subscription"
            }
            $selection = Read-Host -Prompt "Please enter your choice and hit enter"
        }
        $subscriptionGuid = [System.Guid]::empty
        if ([System.Guid]::TryParse($selection, [System.Management.Automation.PSReference]$subscriptionGuid)) {
            $potentialSubscription = $subscriptions | Where-Object { $_.id -eq $selection }
        } elseif(0 -eq $selection) {
            if ($null -ne $AppServiceName) {
                $potentialSubscription = Get-SubscriptionDetailsUsingAppName -AppServiceName $AppServiceName -subscriptions $subscriptions
            } elseif ($null -ne $AppServicePlanName) {
                $potentialSubscription = Get-SubscriptionDetailsUsingPlanName -AppServicePlanName $AppServicePlanName -subscriptions $subscriptions
            } else {
                throw "Cannot find the subscription, because neither an App Service name nor an App Service Plan name is given"
            }
        } else {
            $potentialSubscription = $subscriptions[$($selection - 1)]
        }
        if($null -eq $potentialSubscription) {
            Write-Error "We couldn't find the selected subscription. Please try to re-run the script"
            throw "We couldn't find the selected subscription. Please try to re-run the script"
        }
      } else {
        $potentialSubscription = $subscriptions[0]
      }
  }
  $null = az account set --subscription $($potentialSubscription.id)
  return $potentialSubscription
}

function GetResourceGroup ($SCEPmanAppServiceName) {
    $scWebAppsInTheSubscription = Invoke-Az -azCommand ('graph', 'query', '-q', "Resources | where type == 'microsoft.web/sites' and name =~ '$SCEPmanAppServiceName' | project name, resourceGroup") | Convert-LinesToObject
    if($null -ne $scWebAppsInTheSubscription -and $($scWebAppsInTheSubscription.count) -eq 1) {
        return $scWebAppsInTheSubscription.data[0].resourceGroup
    }
    Write-Error "Unable to determine the resource group. This generally happens when a wrong name is entered for the SCEPman web app!"
    throw "Unable to determine the resource group. This generally happens when a wrong name is entered for the SCEPman web app!"
}

function GetResourceGroupFromPlanName ($AppServicePlanName) {
    $asplansInTheSubscription = Invoke-Az -azCommand ('graph', 'query', '-q', "Resources | where type == 'microsoft.web/serverfarms' and name =~ '$AppServicePlanName' | project name, resourceGroup") | Convert-LinesToObject
    if($null -ne $asplansInTheSubscription -and $($asplansInTheSubscription.count) -eq 1) {
        return $asplansInTheSubscription.data[0].resourceGroup
    }
    Write-Error "Unable to determine the resource group. This generally happens when a wrong name is entered for the App Service Plan!"
    throw "Unable to determine the resource group. This generally happens when a wrong name is entered for the App Service Plan!"
}

function GetAzureRegions() {
    $locationsJson = Invoke-Az @( "account", "list-locations")
    $regions = Convert-LinesToObject $locationsJson
    return $regions
}

function AreTwoRegionsInTheSameGeo($Region1, $Region2) {
    $regions = GetAzureRegions
    $region1data = $regions | Where-Object { $_.name -eq $Region1 -or $_.displayName -eq $Region1}
    $region2data = $regions | Where-Object { $_.name -eq $Region2 -or $_.displayName -eq $Region2}
    if($null -eq $region1data -or $null -eq $region2data) {
        throw "One or both regions are not valid. What we have found: $Region1 - $($null -ne $region1data); $Region2 - $($null -ne $region2data)"
    }
    return $region1data.metadata.geographyGroup -eq $region2data.metadata.geographyGroup
}