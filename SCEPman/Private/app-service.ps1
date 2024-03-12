function GetCertMasterAppServiceName ($CertMasterResourceGroup, $SCEPmanAppServiceName) {
  #       Criteria:
  #       - Configuration value AppConfig:SCEPman:URL must be present, then it must be a CertMaster
  #       - In a default installation, the URL must contain SCEPman's app service name. We require this.

  $strangeCertMasterFound = $false

  $rgwebapps =  Convert-LinesToObject -lines $(az graph query -q "Resources | where type == 'microsoft.web/sites' and resourceGroup == '$CertMasterResourceGroup' and name !~ '$SCEPmanAppServiceName' | project name")
  Write-Information "$($rgwebapps.count) web apps found in the resource group $CertMasterResourceGroup (excluding SCEPman). We are finding if the CertMaster app is already created"
  if($rgwebapps.count -gt 0) {
    ForEach($potentialcmwebapp in $rgwebapps.data) {
      $scepmanUrl = ReadAppSetting -AppServiceName $potentialcmwebapp.name -ResourceGroup $CertMasterResourceGroup -SettingName 'AppConfig:SCEPman:URL'
      if($null -eq $scepmanUrl) {
        Write-Verbose "Web app $($potentialcmwebapp.name) is not a Certificate Master, continuing search ..."
      } else {
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
    Write-Warning "There is at least one Certificate Master App Service in resource group $CertMasterResourceGroup, but we are not sure whether it belongs to SCEPman $SCEPmanAppServiceName."
  }

  Write-Warning "Unable to determine the Certificate Master app service name"
  return $null
}

function SelectBestDotNetRuntime ($ForLinux = $false) {
  if ($ForLinux) {
    return "DOTNETCORE:8.0" # Linux does not include auto-updating runtimes. Therefore we must select a specific one.
  }
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

    $isLinuxAppService = IsAppServiceLinux -AppServiceName $SCEPmanAppServiceName -ResourceGroup $SCEPmanResourceGroup

    $runtime = SelectBestDotNetRuntime -ForLinux $isLinuxAppService
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
    $isCertMasterLinux = IsAppServiceLinux -AppServiceName $CertMasterAppServiceName -ResourceGroup $CertMasterResourceGroup
    $CertMasterAppSettingsJson = AppSettingsHashTable2AzJson -psHashTable $CertmasterAppSettingsTable -convertForLinux $isCertMasterLinux

    Write-Verbose 'Configuring CertMaster web app settings'
    $null = az webapp config set --name $CertMasterAppServiceName --resource-group $CertMasterResourceGroup --use-32bit-worker-process $false --ftps-state 'Disabled' --always-on $true
    $null = az webapp update --name $CertMasterAppServiceName --resource-group $CertMasterResourceGroup --https-only $true
    $null = az webapp config appsettings set --name $CertMasterAppServiceName --resource-group $CertMasterResourceGroup --settings $CertMasterAppSettingsJson
  }

  return $CertMasterAppServiceName
}

function CreateSCEPmanAppService ( $SCEPmanResourceGroup, $SCEPmanAppServiceName, $AppServicePlanId) {
  # Find out which OS the App Service Plan uses
  $aspInfo = ExecuteAzCommandRobustly -azCommand "az appservice plan show --id $AppServicePlanId" | Convert-LinesToObject
  if ($null -eq $aspInfo) {
    throw "App Service Plan $AppServicePlanId not found"
  }
  $isLinuxAsp = $aspInfo.kind -eq "linux"
  $runtime = SelectBestDotNetRuntime -ForLinux $isLinuxAsp
  $null = ExecuteAzCommandRobustly -azCommand "az webapp create --resource-group $SCEPmanResourceGroup --plan $AppServicePlanId --name $SCEPmanAppServiceName --assign-identity [system] --runtime $runtime"
  Write-Information "SCEPman web app $SCEPmanAppServiceName created"

  Write-Verbose 'Configuring SCEPman General web app settings'
  $null = ExecuteAzCommandRobustly -azCommand "az webapp config set --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --use-32bit-worker-process false --ftps-state 'Disabled' --always-on true"
  $null = ExecuteAzCommandRobustly -azCommand "az webapp update --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --client-affinity-enabled false"
}

function GetAppServicePlan ( $AppServicePlanName, $ResourceGroup, $SubscriptionId) {
  $asp = ExecuteAzCommandRobustly -azCommand "az appservice plan list -g $ResourceGroup --query `"[?name=='$AppServicePlanName']`" --subscription $SubscriptionId" | Convert-LinesToObject
  return $asp
}

New-Variable -Name "DictAppServiceKinds" -Value @{} -Scope "Script" -Option ReadOnly

function IsAppServiceLinux ($AppServiceName, $ResourceGroup) {
  if ($DictAppServiceKinds.ContainsKey("$AppServiceName $ResourceGroup")) {
    $kind = $DictAppServiceKinds["$AppServiceName $ResourceGroup"]
  } else {
    $appService = ExecuteAzCommandRobustly -azCommand "az webapp show --name $AppServiceName --resource-group $ResourceGroup" | Convert-LinesToObject
    $kind = $appService.kind
    $DictAppServiceKinds["$AppServiceName $ResourceGroup"] = $kind
  }
  return $kind -eq "app,linux"
}

function GetAppServiceHostNames ($SCEPmanResourceGroup, $AppServiceName, $DeploymentSlotName = $null) {
  if ($null -eq $DeploymentSlotName) {
    return ExecuteAzCommandRobustly -azCommand "az webapp config hostname list --webapp-name $AppServiceName --resource-group $SCEPmanResourceGroup --query `"[].name`" --output tsv"
  } else {
    return ExecuteAzCommandRobustly -azCommand "az webapp config hostname list --webapp-name $AppServiceName --resource-group $SCEPmanResourceGroup --slot $DeploymentSlotName --query `"[].name`" --output tsv"
  }
}

function CreateSCEPmanDeploymentSlot ($SCEPmanResourceGroup, $SCEPmanAppServiceName, $DeploymentSlotName) {
  $existingHostnameConfiguration = ReadAppSetting -AppServiceName $SCEPmanAppServiceName -ResourceGroup $SCEPmanResourceGroup -SettingName "AppConfig:AuthConfig:ManagedIdentityEnabledForWebsiteHostname"
  
  if([string]::IsNullOrEmpty($existingHostnameConfiguration)) {
    SetAppSettings -AppServiceName $SCEPmanAppServiceName -ResourceGroup $SCEPmanResourceGroup -Settings @(@{name="AppConfig:AuthConfig:ManagedIdentityEnabledForWebsiteHostname"; value=$SCEPmanSlotHostName})
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
  $SCEPmanSlotHostNames = GetAppServiceHostNames -SCEPmanResourceGroup $SCEPmanResourceGroup -AppServiceName $SCEPmanAppServiceName -DeploymentSlotName $DeploymentSlotName
  if ($SCEPmanSlotHostNames -is [array]) {
    $SCEPmanSlotHostName = $SCEPmanSlotHostNames[0]
  } else {
    $SCEPmanSlotHostName = $SCEPmanSlotHostNames
  }

  $managedIdentityEnabledOn = ([DateTimeOffset]::UtcNow).ToUnixTimeSeconds()

  Write-Verbose "[$SCEPmanAppServiceName-$DeploymentSlotName] Marking SCEPman App Service as configured (timestamp $managedIdentityEnabledOn)"

  $MarkAsConfiguredSettings = @(
    @{name="AppConfig:AuthConfig:ManagedIdentityEnabledOnUnixTime"; value=$managedIdentityEnabledOn},
    @{name="AppConfig:AuthConfig:ManagedIdentityEnabledForWebsiteHostname"; value=$SCEPmanSlotHostName},
    @{name="AppConfig:AuthConfig:ManagedIdentityPermissionLevel"; value=2}
  )

  SetAppSettings -AppServiceName $SCEPmanAppServiceName -ResourceGroup $SCEPmanResourceGroup -Settings $MarkAsConfiguredSettings -Slot $DeploymentSlotName
}

$RegExGuid = "[({]?[a-fA-F0-9]{8}[-]?([a-fA-F0-9]{4}[-]?){3}[a-fA-F0-9]{12}[})]?"

function ConfigureSCEPmanInstance ($SCEPmanResourceGroup, $SCEPmanAppServiceName, $ScepManAppSettings, $AppRoleAssignmentsFinished, $SCEPmanAppId, $DeploymentSlotName = $null) {
  $existingApplicationId = ReadAppSetting -AppServiceName $SCEPmanAppServiceName -ResourceGroup $SCEPmanResourceGroup -SettingName "AppConfig:AuthConfig:ApplicationId" -Slot $DeploymentSlotName
  Write-Debug "Existing Application Id is set to $existingApplicationId in slot $DeploymentSlotName. The new ID shall be $SCEPmanAppId."

  if ($null -ne $existingApplicationId) {
    $existingApplicationId = $existingApplicationId.Trim('"')
  }
  Write-Debug "The new ID is different to the existing ID? $($existingApplicationId -ne $SCEPmanAppId)"
  if(![string]::IsNullOrEmpty($existingApplicationId) -and $existingApplicationId -ne $SCEPmanAppId) {
    if ($existingApplicationId -notmatch $RegExGuid) {
      Write-Debug "Existing SCEPman Application ID is not a Guid. IsNullOrEmpty? $([string]::IsNullOrEmpty($existingApplicationId)); Is it different than the new one? $($existingApplicationId -ne $SCEPmanAppId); New ID: $SCEPmanAppId; Existing ID: $existingApplicationId"
      throw "SCEPman Application ID $existingApplicationId (Setting AppConfig:AuthConfig:ApplicationId) is not a GUID (Deployment Slot: $DeploymentSlotName). Aborting on unexpected setting."
    }
    Write-Debug "Creating backup of existing ApplicationId $existingApplicationId in slot $DeploymentSlotName"
    SetAppSettings -AppServiceName $SCEPmanAppServiceName -ResourceGroup $SCEPmanResourceGroup -Settings @(@{name="BackUp:AppConfig:AuthConfig:ApplicationId"; value=$existingApplicationId}) -Slot $DeploymentSlotName
    Write-Verbose "[$SCEPmanAppServiceName-$DeploymentSlotName] Backed up ApplicationId"
  }
  SetAppSettings -AppServiceName $SCEPmanAppServiceName -ResourceGroup $SCEPmanResourceGroup -Settings $ScepManAppSettings -Slot $DeploymentSlotName

  # The following setting AppConfig:AuthConfig:ApplicationKey is a secret, but we make sure it doesn't appear in the logs. Not even through az's echoes. Therefore we can ignore the leakage warning
  $existingApplicationKeySc = ReadAppSetting -AppServiceName $SCEPmanAppServiceName -ResourceGroup $SCEPmanResourceGroup -SettingName "AppConfig:AuthConfig:ApplicationKey" -Slot $DeploymentSlotName

  Write-Verbose "[$SCEPmanAppServiceName-$DeploymentSlotName] Wrote SCEPman application settings"
  if(![string]::IsNullOrEmpty($existingApplicationKeySc)) {
    if ($existingApplicationKeySc.Contains("'")) {
      throw "SCEPman Application Key contains at least one single-quote character ('), which is unexpected. Aborting on unexpected setting"
    }
    SetAppSettings -AppServiceName $SCEPmanAppServiceName -ResourceGroup $SCEPmanResourceGroup -Settings @(@{name="BackUp:AppConfig:AuthConfig:ApplicationKey"; value=$existingApplicationKeySc}) -Slot $DeploymentSlotName
    $isScepmanLinux = IsAppServiceLinux -AppServiceName $SCEPmanAppServiceName -ResourceGroup $SCEPmanResourceGroup
    $applicationKeyKey = "AppConfig:AuthConfig:ApplicationKey"
    if ($isScepmanLinux) {
      $applicationKeyKey = $applicationKeyKey.Replace(':', '__')
    }
    $azCommand = @("webapp", "config", "appsettings", "delete", "--name", $SCEPmanAppServiceName, "--resource-group", $SCEPmanResourceGroup, "--setting-names", $applicationKeyKey)
    if ($null -eq $DeploymentSlotName) {
      $azCommand += @("--slot", $DeploymentSlotName)
    }
    $null = ExecuteAzCommandRobustly -callAzNatively -azCommand $azCommand
    Write-Verbose "[$SCEPmanAppServiceName-$DeploymentSlotName] Backed up ApplicationKey"
  }

  if ($AppRoleAssignmentsFinished) {
    MarkDeploymentSlotAsConfigured -SCEPmanResourceGroup $SCEPmanResourceGroup -SCEPmanAppServiceName $SCEPmanAppServiceName -DeploymentSlotName $DeploymentSlotName
  }
}

function ConfigureScepManAppServices($SCEPmanResourceGroup, $SCEPmanAppServiceName, $DeploymentSlotName, $CertMasterBaseURL, $SCEPmanAppId, $AppRoleAssignmentsFinished, $DeploymentSlots) {
  Write-Information "Configuring SCEPman, SCEPman's deployment slots (if any), and Certificate Master web app settings"

  # Add ApplicationId and some additional defaults in SCEPman web app settings

  $ScepManAppSettings = @(
    @{ name='AppConfig:AuthConfig:ApplicationId'; value=$SCEPmanAppID },
    @{ name='AppConfig:IntuneValidation:DeviceDirectory'; value='AADAndIntune'}
  )

  if (-not [string]::IsNullOrEmpty($CertMasterBaseURL)) {
    $ScepManAppSettings += @{ name='AppConfig:CertMaster:URL'; value=$CertMasterBaseURL }
    $ScepManAppSettings += @{ name='AppConfig:DirectCSRValidation:Enabled'; value='true' }
  }

  if ($null -eq $DeploymentSlotName) {
    ConfigureSCEPmanInstance -SCEPmanResourceGroup $SCEPmanResourceGroup -SCEPmanAppServiceName $SCEPmanAppServiceName -ScepManAppSettings $ScepManAppSettings -AppRoleAssignmentsFinished $AppRoleAssignmentsFinished -SCEPmanAppId $SCEPmanAppID
  }

  ForEach($tempDeploymentSlot in $DeploymentSlots) {
    ConfigureSCEPmanInstance -SCEPmanResourceGroup $SCEPmanResourceGroup -SCEPmanAppServiceName $SCEPmanAppServiceName -ScepManAppSettings $ScepManAppSettings -DeploymentSlotName $tempDeploymentSlot -AppRoleAssignmentsFinished $AppRoleAssignmentsFinished -SCEPmanAppId $SCEPmanAppID
  }
}

function ConfigureCertMasterAppService($CertMasterResourceGroup, $CertMasterAppServiceName, $SCEPmanAppId, $CertMasterAppId, $AppRoleAssignmentsFinished) {
  Write-Verbose "Setting Certificate Master configuration"
  $managedIdentityEnabledOn = ([DateTimeOffset]::UtcNow).ToUnixTimeSeconds()

  # Add ApplicationId and SCEPman API scope in certmaster web app settings
  $CertmasterAppSettings = @{
    'AppConfig:AuthConfig:ApplicationId' = $CertMasterAppId
    'AppConfig:AuthConfig:SCEPmanAPIScope' = "api://$SCEPmanAppId"
  }

  if ($AppRoleAssignmentsFinished) {
    $CertmasterAppSettings['AppConfig:AuthConfig:ManagedIdentityEnabledOnUnixTime'] = "$managedIdentityEnabledOn"
    $CertmasterAppSettings['AppConfig:AuthConfig:ManagedIdentityPermissionLevel'] = 2
  }

  $isCertMasterLinux = IsAppServiceLinux -AppServiceName $CertMasterAppServiceName -ResourceGroup $CertMasterResourceGroup
  $CertmasterAppSettingsJson = AppSettingsHashTable2AzJson -psHashTable $CertmasterAppSettings -convertForLinux $isCertMasterLinux

  $null = ExecuteAzCommandRobustly -azCommand "az webapp config appsettings set --name $CertMasterAppServiceName --resource-group $CertMasterResourceGroup --settings '$CertmasterAppSettingsJson'"
}

function SwitchToConfiguredChannel($AppServiceName, $ResourceGroup, $ChannelArtifacts) {
  $intendedChannel = ExecuteAzCommandRobustly -azCommand @("webapp", "config", "appsettings", "list", "--name", $AppServiceName, 
    "--resource-group", $ResourceGroup, "--query", "[?name=='Update_Channel'].value | [0]", "--output", "tsv") -callAzNatively -noSecretLeakageWarning

  if (-not [string]::IsNullOrWhiteSpace($intendedChannel) -and "none" -ne $intendedChannel) {
    Write-Information "Switching app $AppServiceName to update channel $intendedChannel"
    $ArtifactsUrl = $ChannelArtifacts[$intendedChannel]
    if ([string]::IsNullOrWhiteSpace($ArtifactsUrl)) {
      Write-Warning "Could not find Artifacts URL for Channel $intendedChannel of App Service $AppServiceName. Available values: $(Join-String -Separator ',' -InputObject $ChannelArtifacts.Keys)"
    } else {
      Write-Verbose "Artifacts URL is $ArtifactsUrl"
      $null = ExecuteAzCommandRobustly -azCommand @("webapp", "config", "appsettings", "set", "--name", $AppServiceName, "--resource-group", $ResourceGroup, "--settings", "WEBSITE_RUN_FROM_PACKAGE=$ArtifactsUrl") -callAzNatively
      $null = ExecuteAzCommandRobustly -azCommand "az webapp config appsettings delete --name $AppServiceName --resource-group $ResourceGroup --setting-names ""Update_Channel"""
    }
  }
}

function SetAppSettings($AppServiceName, $ResourceGroup, $Settings, $Slot = $null) {
  foreach ($oneSetting in $Settings) {
    $settingName = $oneSetting.name
    $settingValueEscaped = $oneSetting.value.ToString().Replace('"','\"')
    if ($settingName.Contains("=")) {
      Write-Warning "Setting name $settingName contains at least one equal sign (=), which is unsupported. Skipping this setting."
      continue
    }
    $isAppServiceLinux = IsAppServiceLinux -AppServiceName $AppServiceName -ResourceGroup $ResourceGroup
    if ($isAppServiceLinux) {
      $settingName = $settingName.Replace(":", "__")
    }
    Write-Verbose "Setting app setting $settingName of app $AppServiceName in slot [$Slot]"
    Write-Debug "Setting $settingName to $settingValueEscaped"  # there could be cases where this is a secret, so we do not use Write-Verbose
    if ($PSVersionTable.PSVersion.Major -eq 5 -or -not $PSVersionTable.OS.StartsWith("Microsoft Windows")) {
      $settingAssignment = "$settingName=$settingValueEscaped"
    } else {
      $settingAssignment = "`"$settingName`"=`"$settingValueEscaped`""
    }

    $command = @('webapp', 'config', 'appsettings', 'set', '--name', $AppServiceName, '--resource-group', $ResourceGroup, '--settings', $settingAssignment)
    if ($null -ne $Slot) {
      $command += @('--slot', $Slot)
    }

    $null = ExecuteAzCommandRobustly -callAzNatively -azCommand $command
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

function ReadAppSetting($AppServiceName, $ResourceGroup, $SettingName, $Slot = $null) {
  $isAppServiceLinux = IsAppServiceLinux -AppServiceName $AppServiceName -ResourceGroup $ResourceGroup
  if ($isAppServiceLinux) {
    $SettingName = $SettingName.Replace(":", "__")
  }

  $azCommand = @("webapp", "config", "appsettings", "list", "--name", $AppServiceName, "--resource-group", $ResourceGroup,
  "--query", "[?name=='$SettingName'].value | [0]")
  if ($null -ne $Slot) {
    $azCommand += @("--slot", $Slot)
  }
  
  return ExecuteAzCommandRobustly -callAzNatively -azCommand $azCommand -noSecretLeakageWarning
}