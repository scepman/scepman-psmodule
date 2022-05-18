function GetSubscriptionDetailsUsingSCEPmanAppName($subscriptions) {
    $correctSubscription = $null
    Write-Information "Finding correct subscription"
    $scWebAppsAcrossAllAccessibleSubscriptions = ConvertLinesToObject -lines $(az graph query -q "Resources | where type == 'microsoft.web/sites' and name == '$SCEPmanAppServiceName' | project name, subscriptionId" -s $subscriptions.id)
    if($scWebAppsAcrossAllAccessibleSubscriptions.count -eq 1) {
        $correctSubscription = $subscriptions | Where-Object { $_.id -eq $scWebAppsAcrossAllAccessibleSubscriptions.data[0].subscriptionId }
    }
    if($null -eq $correctSubscription) {
        $errorMessage = "We are unable to determine the correct subscription. Please start over"
        Write-Error $errorMessage
        throw $errorMessage
    }
    return $correctSubscription
}

function GetSubscriptionDetails ($SearchAllSubscriptions, $SubscriptionId) {
  $potentialSubscription = $null
  $subscriptions = ConvertLinesToObject -lines $(az account list)
  if($false -eq [String]::IsNullOrWhiteSpace($SubscriptionId)) {
    $potentialSubscription = $subscriptions | Where-Object { $_.id -eq $SubscriptionId }
    if($null -eq $potentialSubscription) {
        Write-Warning "We are unable to find the subscription with id $SubscriptionId"
        throw "We are unable to find the subscription with id $SubscriptionId"
    }
  }
  if($null -eq $potentialSubscription) {
    if($subscriptions.count -gt 1){
        if($SearchAllSubscriptions.IsPresent) {
            Write-Information "User pre-selected to search all subscriptions"
            $selection = 0
        } else {
            Write-Host "Multiple subscriptions found! Select a subscription where the SCPEman is installed or press '0' to search across all of the subscriptions"
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
            $potentialSubscription = GetSubscriptionDetailsUsingSCEPmanAppName -subscriptions $subscriptions
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

function GetResourceGroup {
  if ([String]::IsNullOrWhiteSpace($SCEPmanResourceGroup)) {
    # No resource group given, search for it now
    $scWebAppsInTheSubscription = ConvertLinesToObject -lines $(az graph query -q "Resources | where type == 'microsoft.web/sites' and name == '$SCEPmanAppServiceName' | project name, resourceGroup")
    if($null -ne $scWebAppsInTheSubscription -and $($scWebAppsInTheSubscription.count) -eq 1) {
        return $scWebAppsInTheSubscription.data[0].resourceGroup
    }
    Write-Error "Unable to determine the resource group. This generally happens when a wrong name is entered for the SCEPman web app!"
    throw "Unable to determine the resource group. This generally happens when a wrong name is entered for the SCEPman web app!"
  }
  return $SCEPmanResourceGroup;
}