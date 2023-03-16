function GetCertMasterAppServiceName ($CertMasterResourceGroup, $SCEPmanAppServiceName) {
  #       Criteria:
  #       - Configuration value AppConfig:SCEPman:URL must be present, then it must be a CertMaster
  #       - In a default installation, the URL must contain SCEPman's app service name. We require this.

  $strangeCertMasterFound = $false

  $rgwebapps =  Convert-LinesToObject -lines $(az graph query -q "Resources | where type == 'microsoft.web/sites' and resourceGroup == '$CertMasterResourceGroup' and name !~ '$SCEPmanAppServiceName' | project name")
  Write-Information "$($rgwebapps.count) web apps found in the resource group $CertMasterResourceGroup (excluding SCEPman). We are finding if the CertMaster app is already created"
  if($rgwebapps.count -gt 0) {
    ForEach($potentialcmwebapp in $rgwebapps.data) {
        $scepmanurlsettingcount = ExecuteAzCommandRobustly -azCommand ("az webapp config appsettings list --name $($potentialcmwebapp.name) --resource-group $CertMasterResourceGroup --query ""[?name=='AppConfig:SCEPman:URL'].value | length(@)""")
        if($scepmanurlsettingcount -eq 1) {
            $scepmanUrl = ExecuteAzCommandRobustly -azCommand ("az webapp config appsettings list --name $($potentialcmwebapp.name) --resource-group $CertMasterResourceGroup --query ""[?name=='AppConfig:SCEPman:URL'].value | [0]"" --output tsv")
            $hascorrectscepmanurl = $scepmanUrl.ToUpperInvariant().Contains($SCEPmanAppServiceName.ToUpperInvariant())  # this works for deployment slots, too
            if($hascorrectscepmanurl -eq $true) {
              Write-Information "Certificate Master web app $($potentialcmwebapp.name) found."
              return $potentialcmwebapp.name
            } else {
                Write-Information "Certificate Master web app $($potentialcmwebapp.name) found, but its setting AppConfig:SCEPman:URL is $scepmanURL, which we could not identify with the SCEPman app service. It may or may not be the correct Certificate Master and we ignore it."
                $strangeCertMasterFound = $true
            }
        } else {
          Write-Verbose "Web app $($potentialcmwebapp.name) is not a Certificate Master, continuing search ..."
        }
    }
  }
  if ($strangeCertMasterFound) {
    Write-Warning "There is at least one Certificate Master App Service in resource group $CertMasterResourceGroup, but we are not sure whether it belongs to SCEPman $SCEPmanAppServiceName."
  }

  Write-Warning "Unable to determine the Certificate Master app service name"
  return $null
}

function SelectBestDotNetRuntime {
  try
  {
      $runtimes = ExecuteAzCommandRobustly -azCommand "az webapp list-runtimes --os windows" | Convert-LinesToObject
      [String []]$WindowsDotnetRuntimes = $runtimes | Where-Object { $_.ToLower().startswith("dotnet:") }
      return $WindowsDotnetRuntimes[0]
  }
  catch
  {
      return "dotnet:6"
  }
}

function CreateCertMasterAppService ($TenantId, $SCEPmanResourceGroup, $SCEPmanAppServiceName, $CertMasterResourceGroup, $CertMasterAppServiceName, $DeploymentSlotName, $UpdateChannel = "prod") {
  if ([String]::IsNullOrWhiteSpace($CertMasterAppServiceName)) {
    $CertMasterAppServiceName = GetCertMasterAppServiceName -CertMasterResourceGroup $CertMasterResourceGroup -SCEPmanAppServiceName $SCEPmanAppServiceName
    $ShallCreateCertMasterAppService = $null -eq $CertMasterAppServiceName
  } else {
    # Check whether a cert master app service with the passed in name exists
    $CertMasterWebApps = Convert-LinesToObject -lines $(az graph query -q "Resources | where type == 'microsoft.web/sites' and resourceGroup == '$CertMasterResourceGroup' and name =~ '$CertMasterAppServiceName' | project name")
    $ShallCreateCertMasterAppService = 0 -eq $CertMasterWebApps.count
  }

  $scwebapp = Convert-LinesToObject -lines $(az graph query -q "Resources | where type == 'microsoft.web/sites' and resourceGroup == '$SCEPmanResourceGroup' and name =~ '$SCEPmanAppServiceName'")

  if($null -eq $CertMasterAppServiceName) {
    $CertMasterAppServiceName = $scwebapp.data.name
    if ($CertMasterAppServiceName.Length -gt 57) {
      $CertMasterAppServiceName = $CertMasterAppServiceName.Substring(0,57)
    }

    $CertMasterAppServiceName += "-cm"
    $potentialCertMasterAppServiceName = Read-Host "CertMaster web app not found. Please hit enter now if you want to create the app with name $CertMasterAppServiceName or enter the name of your choice, and then hit enter"

    if($potentialCertMasterAppServiceName) {
        $CertMasterAppServiceName = $potentialCertMasterAppServiceName
    }
  }

  if ($true -eq $ShallCreateCertMasterAppService) {

    Write-Information "User selected to create the app with the name $CertMasterAppServiceName"

    $runtime = SelectBestDotNetRuntime
    $null = az webapp create --resource-group $CertMasterResourceGroup --plan $scwebapp.data.properties.serverFarmId --name $CertMasterAppServiceName --assign-identity [system] --runtime $runtime
    Write-Information "CertMaster web app $CertMasterAppServiceName created"

    # Do all the configuration that the ARM template does normally
    $SCEPmanHostname = $scwebapp.data.properties.defaultHostName
    if ($null -ne $DeploymentSlotName) {
        $selectedSlot = Convert-LinesToObject -lines $(az graph query -q "Resources | where type == 'microsoft.web/sites/slots' and resourceGroup == '$SCEPmanResourceGroup' and name =~ '$SCEPmanAppServiceName/$DeploymentSlotName'")
        $SCEPmanHostname = $selectedSlot.data.properties.defaultHostName
    }
    $CertmasterAppSettingsTable = @{
      WEBSITE_RUN_FROM_PACKAGE = $Artifacts_Certmaster[$UpdateChannel];
      "AppConfig:AuthConfig:TenantId" = $TenantId;
      "AppConfig:SCEPman:URL" = "https://$SCEPmanHostname/";
    }
    $CertMasterAppSettingsJson = HashTable2AzJson -psHashTable $CertmasterAppSettingsTable

    Write-Verbose 'Configuring CertMaster web app settings'
    $null = az webapp config set --name $CertMasterAppServiceName --resource-group $CertMasterResourceGroup --use-32bit-worker-process $false --ftps-state 'Disabled' --always-on $true
    $null = az webapp update --name $CertMasterAppServiceName --resource-group $CertMasterResourceGroup --https-only $true
    $null = az webapp config appsettings set --name $CertMasterAppServiceName --resource-group $CertMasterResourceGroup --settings $CertMasterAppSettingsJson
  }

  return $CertMasterAppServiceName
}

function CreateSCEPmanAppService ( $SCEPmanResourceGroup, $SCEPmanAppServiceName, $AppServicePlanId) {
  $runtime = SelectBestDotNetRuntime
  $null = az webapp create --resource-group $SCEPmanResourceGroup --plan $AppServicePlanId --name $SCEPmanAppServiceName --assign-identity [system] --runtime $runtime
  Write-Information "SCEPman web app $SCEPmanAppServiceName created"

  Write-Verbose 'Configuring SCEPman General web app settings'
  $null = az webapp config set --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --use-32bit-worker-process $false --ftps-state 'Disabled' --always-on $true
  $null = az webapp update --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --client-affinity-enabled $false
}

function GetAppServicePlan ( $AppServicePlanName, $ResourceGroup, $SubscriptionId) {
  $asp = Convert-LinesToObject -lines $(az appservice plan list -g $ResourceGroup --query "[?name=='$AppServicePlanName']" --subscription $SubscriptionId)
  return $asp
}

function GetAppServiceHostName ($SCEPmanResourceGroup, $AppServiceName, $DeploymentSlotName = $null) {
  if ($null -eq $DeploymentSlotName) {
    return "$AppServiceName.azurewebsites.net"  #TODO: Find out Base URL for non-global tenants
  } else {
    return "$AppServiceName-$DeploymentSlotName.azurewebsites.net"  #TODO: Find out Base URL for non-global tenants
  }
}

function CreateSCEPmanDeploymentSlot ($SCEPmanResourceGroup, $SCEPmanAppServiceName, $DeploymentSlotName) {
  $existingHostnameConfiguration = az webapp config appsettings list --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --query "[?name=='AppConfig:AuthConfig:ManagedIdentityEnabledForWebsiteHostname'].value | [0]" --output tsv
  if([string]::IsNullOrEmpty($existingHostnameConfiguration)) {
    $null = az webapp config appsettings set --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --slot-settings AppConfig:AuthConfig:ManagedIdentityEnabledForWebsiteHostname=$SCEPmanSlotHostName
    Write-Information "Specified Production Slot Activation as such via AppConfig:AuthConfig:ManagedIdentityEnabledForWebsiteHostname"
  }

  $azOutput = az webapp deployment slot create --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --slot $DeploymentSlotName --configuration-source $SCEPmanAppServiceName
  $null = CheckAzOutput -azOutput $azOutput -fThrowOnError $true
  Write-Information "Created SCEPman Deployment Slot $DeploymentSlotName"

  return Convert-LinesToObject -lines $(az webapp identity assign --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --slot $DeploymentSlotName --identities [system])
}

function GetDeploymentSlots($appServiceName, $resourceGroup) {
  $deploymentSlots = ExecuteAzCommandRobustly -azCommand "az webapp deployment slot list --name $appServiceName --resource-group $resourceGroup --query '[].name'" | Convert-LinesToObject
  if ($null -eq $deploymentSlots) {
    return @()
  } else {
    return $deploymentSlots
  }
}

function MarkDeploymentSlotAsConfigured($SCEPmanResourceGroup, $SCEPmanAppServiceName, $DeploymentSlotName = $null) {
  # Add a setting to tell the Deployment slot that it has been configured
  $SCEPmanSlotHostName = GetAppServiceHostName -SCEPmanResourceGroup $SCEPmanResourceGroup -AppServiceName $SCEPmanAppServiceName -DeploymentSlotName $DeploymentSlotName

  $managedIdentityEnabledOn = ([DateTimeOffset]::UtcNow).ToUnixTimeSeconds()

  Write-Verbose "[$SCEPmanAppServiceName-$DeploymentSlotName] Marking SCEPman App Service as configured (timestamp $managedIdentityEnabledOn)"
  $azSetConfigCommand = "az webapp config appsettings set --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup"

  # The docs (2.37) say that az webapp config appsettings set takes a space separated list of KEY=VALUE.
  # For --settings, we use JSON, contrary to documentation
  # Neither works for --slot-settings in tests :-(. Thus, the individual calls
  if ($null -ne $DeploymentSlotName) {
    $azSetConfigCommand += " --slot $DeploymentSlotName"
  }
  $null = ExecuteAzCommandRobustly -azCommand "$azSetConfigCommand --slot-settings ""AppConfig:AuthConfig:ManagedIdentityEnabledOnUnixTime=$managedIdentityEnabledOn"""
  $null = ExecuteAzCommandRobustly -azCommand "$azSetConfigCommand --slot-settings ""AppConfig:AuthConfig:ManagedIdentityEnabledForWebsiteHostname=$SCEPmanSlotHostName"""
  $null = ExecuteAzCommandRobustly -azCommand "$azSetConfigCommand --slot-settings `"AppConfig:AuthConfig:ManagedIdentityPermissionLevel=2`""
}

$RegExGuid = "[({]?[a-fA-F0-9]{8}[-]?([a-fA-F0-9]{4}[-]?){3}[a-fA-F0-9]{12}[})]?"

function ConfigureSCEPmanInstance ($SCEPmanResourceGroup, $SCEPmanAppServiceName, $ScepManAppSettings, $AppRoleAssignmentsFinished, $DeploymentSlotName = $null) {
  if ($null -eq $DeploymentSlotName) {
    $deploymentSlotTargetingParamString = [string]::Empty
  } else {
    $deploymentSlotTargetingParamString = " --slot $DeploymentSlotName"
  }

  $existingApplicationId = ExecuteAzCommandRobustly -azCommand ("az webapp config appsettings list --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --query ""[?name=='AppConfig:AuthConfig:ApplicationId'].value | [0]""" + $deploymentSlotTargetingParamString)
  if(![string]::IsNullOrEmpty($existingApplicationId) -and $existingApplicationId -ne $SCEPmanAppId) {
    if ($existingApplicationId -notmatch $RegExGuid) {
      throw "SCEPman Application ID $existingApplicationId (Setting AppConfig:AuthConfig:ApplicationId) is not a GUID (Deployment Slot: $DeploymentSlotName). Aborting on unexpected setting ..."
    }
    $null = ExecuteAzCommandRobustly -azCommand ("az webapp config appsettings set --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --settings BackUp:AppConfig:AuthConfig:ApplicationId=$existingApplicationId" + $deploymentSlotTargetingParamString)
    Write-Verbose "[$SCEPmanAppServiceName-$DeploymentSlotName] Backed up ApplicationId"
  }
  $null = ExecuteAzCommandRobustly -azCommand ("az webapp config appsettings set --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --settings '$ScepManAppSettings'" + $deploymentSlotTargetingParamString)
  $existingApplicationKeySc = ExecuteAzCommandRobustly -azCommand ("az webapp config appsettings list --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --query ""[?name=='AppConfig:AuthConfig:ApplicationKey'].value | [0]""" + $deploymentSlotTargetingParamString)
  Write-Verbose "[$SCEPmanAppServiceName-$DeploymentSlotName] Wrote SCEPman application Settings"
  if(![string]::IsNullOrEmpty($existingApplicationKeySc)) {
    if ($existingApplicationKeySc.Contains("'")) {
      throw "SCEPman Application Key contains at least one single-quote character ('), which is unexpected. Aborting on unexpected setting ..."
    }
    $null = ExecuteAzCommandRobustly -azCommand ("az webapp config appsettings set --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --settings 'BackUp:AppConfig:AuthConfig:ApplicationKey=$existingApplicationKeySc'" + $deploymentSlotTargetingParamString)
    $null = ExecuteAzCommandRobustly -azCommand ("az webapp config appsettings delete --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --setting-names AppConfig:AuthConfig:ApplicationKey" + $deploymentSlotTargetingParamString)
    Write-Verbose "[$SCEPmanAppServiceName-$DeploymentSlotName] Backed up ApplicationKey"
  }

  if ($AppRoleAssignmentsFinished) {
    MarkDeploymentSlotAsConfigured -SCEPmanResourceGroup $SCEPmanResourceGroup -SCEPmanAppServiceName $SCEPmanAppServiceName -DeploymentSlotName $DeploymentSlotName
  }
}

function ConfigureAppServices($SCEPmanResourceGroup, $SCEPmanAppServiceName, $CertMasterResourceGroup, $CertMasterAppServiceName, $DeploymentSlotName, $CertMasterBaseURL, $SCEPmanAppId, $CertMasterAppId, $AppRoleAssignmentsFinished, $DeploymentSlots = @()) {
  Write-Information "Configuring SCEPman, SCEPman's deployment slots (if any), and Certificate Master web app settings"

  $managedIdentityEnabledOn = ([DateTimeOffset]::UtcNow).ToUnixTimeSeconds()

  # Add ApplicationId and some additional defaults in SCEPman web app settings

  $ScepManAppSettings = @{
    'AppConfig:AuthConfig:ApplicationId' = $SCEPmanAppID
    'AppConfig:CertMaster:URL' = $CertMasterBaseURL
    'AppConfig:IntuneValidation:DeviceDirectory' = 'AADAndIntune'
    'AppConfig:DirectCSRValidation:Enabled' = 'true'
  }

  $ScepManAppSettingsJson = HashTable2AzJson -psHashTable $ScepManAppSettings

  if ($null -eq $DeploymentSlotName) {
    ConfigureSCEPmanInstance -SCEPmanResourceGroup $SCEPmanResourceGroup -SCEPmanAppServiceName $SCEPmanAppServiceName -ScepManAppSettings $ScepManAppSettingsJson -AppRoleAssignmentsFinished $AppRoleAssignmentsFinished
  }

  ForEach($tempDeploymentSlot in $DeploymentSlots) {
    ConfigureSCEPmanInstance -SCEPmanResourceGroup $SCEPmanResourceGroup -SCEPmanAppServiceName $SCEPmanAppServiceName -ScepManAppSettings $ScepManAppSettingsJson -DeploymentSlotName $tempDeploymentSlot -AppRoleAssignmentsFinished $AppRoleAssignmentsFinished
  }

  Write-Verbose "Setting Certificate Master configuration"

  # Add ApplicationId and SCEPman API scope in certmaster web app settings
  $CertmasterAppSettings = @{
    'AppConfig:AuthConfig:ApplicationId' = $CertMasterAppId
    'AppConfig:AuthConfig:SCEPmanAPIScope' = "api://$SCEPmanAppId"
  }

  if ($AppRoleAssignmentsFinished) {
    $CertmasterAppSettings['AppConfig:AuthConfig:ManagedIdentityEnabledOnUnixTime'] = "$managedIdentityEnabledOn"
    $CertmasterAppSettings['AppConfig:AuthConfig:ManagedIdentityPermissionLevel'] = 2
  }

  $CertmasterAppSettingsJson = HashTable2AzJson -psHashTable $CertmasterAppSettings

  $null = ExecuteAzCommandRobustly -azCommand "az webapp config appsettings set --name $CertMasterAppServiceName --resource-group $CertMasterResourceGroup --settings '$CertmasterAppSettingsJson'"
}

function SwitchToConfiguredChannel($AppServiceName, $ResourceGroup, $ChannelArtifacts) {
  $intendedChannel = ExecuteAzCommandRobustly -azCommand "az webapp config appsettings list --name $AppServiceName --resource-group $ResourceGroup --query ""[?name=='Update_Channel'].value | [0]"" --output tsv"

  if (-not [string]::IsNullOrWhiteSpace($intendedChannel) -and "none" -ne $intendedChannel) {
    Write-Information "Switching app $AppServiceName to update channel $intendedChannel"
    $ArtifactsUrl = $ChannelArtifacts[$intendedChannel]
    if ([string]::IsNullOrWhiteSpace($ArtifactsUrl)) {
      Write-Warning "Could not find Artifacts URL for Channel $intendedChannel of App Service $AppServiceName. Available values: $(Join-String -Separator ',' -InputObject $ChannelArtifacts.Keys)"
    } else {
      Write-Verbose "Artifacts URL is $ArtifactsUrl"
      $null = ExecuteAzCommandRobustly -azCommand "az webapp config appsettings set --name $AppServiceName --resource-group $ResourceGroup --settings ""WEBSITE_RUN_FROM_PACKAGE=$ArtifactsUrl"""
      $null = ExecuteAzCommandRobustly -azCommand "az webapp config appsettings delete --name $AppServiceName --resource-group $ResourceGroup --setting-names ""Update_Channel"""
    }
  }
}

function SetAppSettings($AppServiceName, $ResourceGroup, $Settings) {
  foreach ($oneSetting in $Settings) {
    $null = az webapp config appsettings set --name $AppServiceName --resource-group $ResourceGroup --settings "$($oneSetting.name)=$($oneSetting.value.Replace('"','\"'))"
  }
  # The following does not work, as equal signs split this into incomprehensible gibberish:
  #$null = az webapp config appsettings set --name $AppServiceName --resource-group $ResourceGroup --settings (ConvertTo-Json($Settings) -Compress).Replace('"','\"')
}

function ReadAppSettings($AppServiceName, $ResourceGroup) {
  $slotSettings = ExecuteAzCommandRobustly -azCommand "az webapp config appsettings list --name $AppServiceName --resource-group $ResourceGroup --query `"[?slotSetting]`"" | Convert-LinesToObject
  $unboundSettings = ExecuteAzCommandRobustly -azCommand "az webapp config appsettings list --name $AppServiceName --resource-group $ResourceGroup --query `"[?!slotSetting]`"" | Convert-LinesToObject

  Write-Information "Read $($slotSettings.Count) slot settings and $($unboundSettings.Count) other settings from app $AppServiceName"

  return @{
    slotSettings = $slotSettings
    settings = $unboundSettings
  }
}