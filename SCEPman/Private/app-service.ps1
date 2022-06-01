function GetCertMasterAppServiceName ($SCEPmanResourceGroup, $SCEPmanAppServiceName) {
  #       Criteria:
  #       - Only two App Services in SCEPman's resource group. One is SCEPman, the other the CertMaster candidate
  #       - Configuration value AppConfig:SCEPman:URL must be present, then it must be a CertMaster
  #       - In a default installation, the URL must contain SCEPman's app service name. We require this.

  $strangeCertMasterFound = $false

  $rgwebapps =  ConvertLinesToObject -lines $(az graph query -q "Resources | where type == 'microsoft.web/sites' and resourceGroup == '$SCEPmanResourceGroup' and name !~ '$SCEPmanAppServiceName' | project name")
  Write-Information "$($rgwebapps.count + 1) web apps found in the resource group $SCEPmanResourceGroup. We are finding if the CertMaster app is already created"
  if($rgwebapps.count -gt 0) {
    ForEach($potentialcmwebapp in $rgwebapps.data) {
        $scepmanurlsettingcount = az webapp config appsettings list --name $potentialcmwebapp.name --resource-group $SCEPmanResourceGroup --query "[?name=='AppConfig:SCEPman:URL'].value | length(@)"
        if($scepmanurlsettingcount -eq 1) {
            $scepmanUrl = az webapp config appsettings list --name $potentialcmwebapp.name --resource-group $SCEPmanResourceGroup --query "[?name=='AppConfig:SCEPman:URL'].value | [0]"
            $hascorrectscepmanurl = $scepmanUrl.ToUpperInvariant().Contains($SCEPmanAppServiceName.ToUpperInvariant())  # this works for deployment slots, too
            if($hascorrectscepmanurl -eq $true) {
              Write-Information "Certificate Master web app $($potentialcmwebapp.name) found."
              return $potentialcmwebapp.name
            } else {
                Write-Information "Certificate Master web app $($potentialcmwebapp.name) found, but its setting AppConfig:SCEPman:URL is $scepmanURL, which we could not identify with the SCEPman app service. It may or may not be the correct Certificate Master and we ignore it."
                $strangeCertMasterFound = $true
            }
        }
    }
  }
  if ($strangeCertMasterFound) {
    Write-Warning "There is at least one Certificate Master App Service in resource group $SCEPmanResourceGroup, but we are not sure whether it belongs to SCEPman $SCEPmanAppServiceName."
  }

  Write-Warning "Unable to determine the Certificate Master app service name"
  return $null
}

function SelectBestDotNetRuntime {
  try
  {
      $runtimes = ConvertLinesToObject -lines $(az webapp list-runtimes --os windows)
      [String []]$WindowsDotnetRuntimes = $runtimes | Where-Object { $_.ToLower().startswith("dotnet:") }
      return $WindowsDotnetRuntimes[0]
  }
  catch
  {
      return "dotnet:6"
  }
}

function CreateCertMasterAppService ($TenantId, $SCEPmanResourceGroup, $SCEPmanAppServiceName, $CertMasterAppServiceName, $DeploymentSlotName) {
  if ([String]::IsNullOrWhiteSpace($CertMasterAppServiceName)) {
    $CertMasterAppServiceName = GetCertMasterAppServiceName -SCEPmanResourceGroup $SCEPmanResourceGroup -SCEPmanAppServiceName $SCEPmanAppServiceName
    $ShallCreateCertMasterAppService = $null -eq $CertMasterAppServiceName
  } else {
    # Check whether a cert master app service with the passed in name exists
    $CertMasterWebApps = ConvertLinesToObject -lines $(az graph query -q "Resources | where type == 'microsoft.web/sites' and resourceGroup == '$SCEPmanResourceGroup' and name =~ '$CertMasterAppServiceName' | project name")
    $ShallCreateCertMasterAppService = 0 -eq $CertMasterWebApps.count
  }

  $scwebapp = ConvertLinesToObject -lines $(az graph query -q "Resources | where type == 'microsoft.web/sites' and resourceGroup == '$SCEPmanResourceGroup' and name =~ '$SCEPmanAppServiceName'")

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
    $null = az webapp create --resource-group $SCEPmanResourceGroup --plan $scwebapp.data.properties.serverFarmId --name $CertMasterAppServiceName --assign-identity [system] --runtime $runtime
    Write-Information "CertMaster web app $CertMasterAppServiceName created"

    # Do all the configuration that the ARM template does normally
    $SCEPmanHostname = $scwebapp.data.properties.defaultHostName
    if ($null -ne $DeploymentSlotName) {
        $selectedSlot = ConvertLinesToObject -lines $(az graph query -q "Resources | where type == 'microsoft.web/sites/slots' and resourceGroup == '$SCEPmanResourceGroup' and name =~ '$SCEPmanAppServiceName/$DeploymentSlotName'")
        $SCEPmanHostname = $selectedSlot.data.properties.defaultHostName
    }
    $CertmasterAppSettings = @{
      WEBSITE_RUN_FROM_PACKAGE = "https://raw.githubusercontent.com/scepman/install/master/dist-certmaster/CertMaster-Artifacts.zip";
      "AppConfig:AuthConfig:TenantId" = $TenantId;
      "AppConfig:SCEPman:URL" = "https://$SCEPmanHostname/";
    } | ConvertTo-Json -Compress
    $CertMasterAppSettings = $CertmasterAppSettings.Replace('"', '\"')

    Write-Verbose 'Configuring CertMaster web app settings'
    $null = az webapp config set --name $CertMasterAppServiceName --resource-group $SCEPmanResourceGroup --use-32bit-worker-process $false --ftps-state 'Disabled' --always-on $true
    $null = az webapp update --name $CertMasterAppServiceName --resource-group $SCEPmanResourceGroup --https-only $true
    $null = az webapp config appsettings set --name $CertMasterAppServiceName --resource-group $SCEPmanResourceGroup --settings $CertMasterAppSettings
  }

  return $CertMasterAppServiceName
}

function GetAppServiceHostName ($SCEPmanResourceGroup, $AppServiceName, $DeploymentSlotName = $null) {
  if ($null -eq $DeploymentSlotName) {
    return "$AppServiceName.azurewebsites.net"  #TODO: Find out Base URL for non-global tenants
  } else {
    return "$AppServiceName-$DeploymentSlotName.azurewebsites.net"  #TODO: Find out Base URL for non-global tenants
  }
}

function CreateSCEPmanDeploymentSlot ($SCEPmanResourceGroup, $SCEPmanAppServiceName, $DeploymentSlotName) {
  $existingHostnameConfiguration = az webapp config appsettings list --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --query "[?name=='AppConfig:AuthConfig:ManagedIdentityEnabledForWebsiteHostname'].value | [0]"
  if([string]::IsNullOrEmpty($existingHostnameConfiguration)) {
    $SCEPmanHostName = GetAppServiceHostName -SCEPmanResourceGroup $SCEPmanResourceGroup -SCEPmanAppServiceName $SCEPmanAppServiceName
    $null = az webapp config appsettings set --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --slot-settings AppConfig:AuthConfig:ManagedIdentityEnabledForWebsiteHostname=$SCEPmanHostName
  }

  $null = CheckAzOutput(az webapp deployment slot create --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --slot $DeploymentSlotName --configuration-source $SCEPmanAppServiceName)
  Write-Information "Created SCEPman Deployment Slot $DeploymentSlotName"

  return ConvertLinesToObject -lines $(az webapp identity assign --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --slot $DeploymentSlotName --identities [system])
}

function GetDeploymentSlots($appServiceName, $resourceGroup) {
  $deploymentSlots = ConvertLinesToObject -lines $(az webapp deployment slot list --name $appServiceName --resource-group $resourceGroup --query '[].name')
  if ($null -eq $deploymentSlots) {
    return @()
  } else {
    return $deploymentSlots
  }
}

$RegExGuid = "[({]?[a-fA-F0-9]{8}[-]?([a-fA-F0-9]{4}[-]?){3}[a-fA-F0-9]{12}[})]?"

function ConfigureSCEPmanInstance ($SCEPmanResourceGroup, $SCEPmanAppServiceName, $ScepManAppSettings, $DeploymentSlotName = $null) {
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
}

function ConfigureAppServices($SCEPmanResourceGroup, $SCEPmanAppServiceName, $CertMasterAppServiceName, $DeploymentSlotName, $CertMasterBaseURL, $SCEPmanAppId, $CertMasterAppId, $DeploymentSlots = @()) {
  Write-Information "Configuring SCEPman, SCEPman's deployment slots (if any), and CertMaster web app settings"

  $managedIdentityEnabledOn = ([DateTimeOffset]::UtcNow).ToUnixTimeSeconds()

  # Add ApplicationId and some additional defaults in SCEPman web app settings

  $ScepManAppSettings = "{\`"AppConfig:AuthConfig:ApplicationId\`":\`"$SCEPmanAppID\`",\`"AppConfig:CertMaster:URL\`":\`"$CertMasterBaseURL\`",\`"AppConfig:IntuneValidation:DeviceDirectory\`":\`"AADAndIntune\`",\`"AppConfig:DirectCSRValidation:Enabled\`":\`"true\`",\`"AppConfig:AuthConfig:ManagedIdentityEnabledOnUnixTime\`":\`"$managedIdentityEnabledOn\`"}".Replace("`r", [String]::Empty).Replace("`n", [String]::Empty)

  if ($null -eq $DeploymentSlotName) {
    ConfigureSCEPmanInstance -SCEPmanResourceGroup $SCEPmanResourceGroup -SCEPmanAppServiceName $SCEPmanAppServiceName -ScepManAppSettings $ScepManAppSettings
  }

  ForEach($tempDeploymentSlot in $DeploymentSlots) {
    ConfigureSCEPmanInstance -SCEPmanResourceGroup $SCEPmanResourceGroup -SCEPmanAppServiceName $SCEPmanAppServiceName -ScepManAppSettings $ScepManAppSettings -DeploymentSlotName $tempDeploymentSlot
  }

  # Add ApplicationId and SCEPman API scope in certmaster web app settings
  $CertmasterAppSettings = "{\`"AppConfig:AuthConfig:ApplicationId\`":\`"$CertMasterAppId\`",\`"AppConfig:AuthConfig:SCEPmanAPIScope\`":\`"api://$SCEPmanAppId\`",\`"AppConfig:AuthConfig:ManagedIdentityEnabledOnUnixTime\`":\`"$managedIdentityEnabledOn\`"}".Replace("`r", [String]::Empty).Replace("`n", [String]::Empty)
  $null = az webapp config appsettings set --name $CertMasterAppServiceName --resource-group $SCEPmanResourceGroup --settings $CertmasterAppSettings
}