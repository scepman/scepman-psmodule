function GetCertMasterAppServiceName ($CertMasterResourceGroup, $SCEPmanAppServiceName) {
  #       Criteria:
  #       - Configuration value AppConfig:SCEPman:URL must be present, then it must be a CertMaster
  #       - In a default installation, the URL must contain SCEPman's app service name. We require this.

  $strangeCertMasterFound = $false

  $rgwebapps = Invoke-Az -azCommand @("graph", "query", "-q", "Resources | where type == 'microsoft.web/sites' and resourceGroup == '$CertMasterResourceGroup' and name !~ '$SCEPmanAppServiceName' | project name") | Convert-LinesToObject
  Write-Information "$($rgwebapps.count) web apps found in the resource group $CertMasterResourceGroup (excluding SCEPman). We are finding if the CertMaster app is already created"
  if($rgwebapps.count -gt 0) {
    ForEach($potentialcmwebapp in $rgwebapps.data) {
      $scepmanUrl = ReadAppSetting -AppServiceName $potentialcmwebapp.name -ResourceGroup $CertMasterResourceGroup -SettingName 'AppConfig:SCEPman:URL'
      if($null -eq $scepmanUrl) {
        $isCmCandidateLinux = IsAppServiceLinux -AppServiceName $potentialcmwebapp.name -ResourceGroup $CertMasterResourceGroup
        if ($isCmCandidateLinux) {
          $candidateOs = "Linux"
        } else {
          $candidateOs = "Windows"
        }
        Write-Verbose "Web app $($potentialcmwebapp.name) running on $candidateOs is not a Certificate Master, continuing search ..."
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
    return "DOTNETCORE:8.0" # Linux does not include auto-updating inbuilt runtimes. Therefore this should be a self-contained package, but we must still select some dotnet runtime.
  }
  try
  {
      $runtimes = Invoke-Az @("webapp", "list-runtimes", "--os", "windows")
      [String []]$WindowsDotnetRuntimes = $runtimes | Where-Object { $_.ToLower().startswith("dotnet:") }
      return $WindowsDotnetRuntimes[0]
  }
  catch
  {
      return "dotnet:8"
  }
}

function New-CertMasterAppService {
  [CmdletBinding(SupportsShouldProcess=$true)]
  [OutputType([String])]
  param (
    [Parameter(Mandatory=$true)]    [string]$TenantId,
    [Parameter(Mandatory=$true)]    [string]$SCEPmanResourceGroup,
    [Parameter(Mandatory=$true)]    [string]$SCEPmanAppServiceName,
    [Parameter(Mandatory=$true)]    [string]$CertMasterResourceGroup,
    [Parameter(Mandatory=$false)][AllowEmptyString()]    [string]$CertMasterAppServiceName,
    [Parameter(Mandatory=$false)]    [string]$DeploymentSlotName,
    [Parameter(Mandatory=$false)]    [string]$UpdateChannel = "prod"
  )

  if ([String]::IsNullOrWhiteSpace($CertMasterAppServiceName)) {
    $CertMasterAppServiceName = GetCertMasterAppServiceName -CertMasterResourceGroup $CertMasterResourceGroup -SCEPmanAppServiceName $SCEPmanAppServiceName
    $ShallCreateCertMasterAppService = [String]::IsNullOrWhiteSpace($CertMasterAppServiceName)
  } else {
    # Check whether a cert master app service with the passed in name exists
    $CertMasterWebApps = Invoke-Az -azCommand @("graph", "query", "-q", "Resources | where type == 'microsoft.web/sites' and resourceGroup == '$CertMasterResourceGroup' and name =~ '$CertMasterAppServiceName' | project name") | Convert-LinesToObject
    $ShallCreateCertMasterAppService = 0 -eq $CertMasterWebApps.count
  }

  $scwebapp = Invoke-Az -azCommand @("graph", "query", "-q", "Resources | where type == 'microsoft.web/sites' and resourceGroup == '$SCEPmanResourceGroup' and name =~ '$SCEPmanAppServiceName'") | Convert-LinesToObject

  if([String]::IsNullOrWhiteSpace($CertMasterAppServiceName)) {
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
    if ($PSCmdlet.ShouldProcess($CertMasterAppServiceName, ("Creating Certificate Master App Service with .NET Runtime {0}" -f $runtime))) {
      $null = Invoke-Az @("webapp", "create", "--resource-group", $CertMasterResourceGroup, "--plan", $scwebapp.data.properties.serverFarmId, "--name", $CertMasterAppServiceName, "--assign-identity", "[system]", "--https-only", 'true', "--runtime", $runtime)
      Write-Information "CertMaster web app $CertMasterAppServiceName created"

      # Do all the configuration that the ARM template does normally
      $SCEPmanHostname = $scwebapp.data.properties.defaultHostName
      if (-not [String]::IsNullOrWhiteSpace($DeploymentSlotName)) {
        $selectedSlot = Invoke-Az -azCommand @("graph", "query", "-q", "Resources | where type == 'microsoft.web/sites/slots' and resourceGroup == '$SCEPmanResourceGroup' and name =~ '$SCEPmanAppServiceName/$DeploymentSlotName'") | Convert-LinesToObject
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
      $null = Invoke-Az -azCommand @( "webapp", "config", "appsettings", "set", "--name", $CertMasterAppServiceName, "--resource-group", $CertMasterResourceGroup, "--settings", $CertMasterAppSettingsJson)
      $null = Invoke-Az -azCommand @( "webapp", "config", "set", "--name", $CertMasterAppServiceName, "--resource-group", $CertMasterResourceGroup, "--use-32bit-worker-process", "false", "--ftps-state", "Disabled", "--always-on", "true")
    }
    else {
      return "Skipped"
    }
  }

  return $CertMasterAppServiceName
}

function CreateSCEPmanAppService ( $SCEPmanResourceGroup, $SCEPmanAppServiceName, $AppServicePlanId) {
  # Find out which OS the App Service Plan uses
  $isLinuxAsp = IsAppServicePlanLinux -AppServicePlanId $AppServicePlanId
  $runtime = SelectBestDotNetRuntime -ForLinux $isLinuxAsp
  $null = Invoke-Az @("webapp", "create", "--resource-group", $SCEPmanResourceGroup, "--plan", $AppServicePlanId, "--name", $SCEPmanAppServiceName, "--assign-identity", "[system]", "--runtime", $runtime)
  Write-Information "SCEPman web app $SCEPmanAppServiceName created"

  Write-Verbose 'Configuring SCEPman General web app settings'
  $null = Invoke-Az @("webapp", "config", "set", "--name", $SCEPmanAppServiceName, "--resource-group", $SCEPmanResourceGroup, "--use-32bit-worker-process", "false", "--ftps-state", "Disabled", "--always-on", "true")
  $null = Invoke-Az @("webapp", "update", "--name", $SCEPmanAppServiceName, "--resource-group", $SCEPmanResourceGroup, "--client-affinity-enabled", "false")
}

function GetAppServicePlan ( $AppServicePlanName, $ResourceGroup, $SubscriptionId) {
  $asp = ExecuteAzCommandRobustly -azCommand "az appservice plan list -g $ResourceGroup --query `"[?name=='$AppServicePlanName']`" --subscription $SubscriptionId" | Convert-LinesToObject
  return $asp
}

New-Variable -Name "CacheAppServiceKinds" -Value @{} -Scope "Script" -Option ReadOnly

function IsAppServiceLinux ($AppServiceName, $ResourceGroup) {
  if ($CacheAppServiceKinds.ContainsKey("$AppServiceName $ResourceGroup")) {
    $kind = $CacheAppServiceKinds["$AppServiceName $ResourceGroup"]
  } else {
    $kind = Invoke-Az @("webapp", "show", "--name", $AppServiceName, "--resource-group", $ResourceGroup, "--query", 'kind', "--output", "tsv")
    $CacheAppServiceKinds["$AppServiceName $ResourceGroup"] = $kind
  }
  return $kind -eq "app,linux"
}

function IsAppServicePlanLinux ($AppServicePlanId) {
  $kind = Invoke-Az @("appservice", "plan", "show", "--id", $AppServicePlanId, "--query", 'kind', "--output", "tsv")

  return $kind -eq "linux"
}

function GetAppServiceHostNames ($SCEPmanResourceGroup, $AppServiceName, $DeploymentSlotName = $null) {
  if ($null -eq $DeploymentSlotName) {
    return ExecuteAzCommandRobustly -azCommand "az webapp config hostname list --webapp-name $AppServiceName --resource-group $SCEPmanResourceGroup --query `"[].name`" --output tsv"
  } else {
    return ExecuteAzCommandRobustly -azCommand "az webapp config hostname list --webapp-name $AppServiceName --resource-group $SCEPmanResourceGroup --slot $DeploymentSlotName --query `"[].name`" --output tsv"
  }
}

function GetPrimaryAppServiceHostName ($SCEPmanResourceGroup, $AppServiceName, $DeploymentSlotName = $null) {
  $SCEPmanHostNames = GetAppServiceHostNames -SCEPmanResourceGroup $SCEPmanResourceGroup -AppServiceName $SCEPmanAppServiceName -DeploymentSlotName $DeploymentSlotName
  if ($SCEPmanHostNames -is [array]) {
    return $SCEPmanHostNames[0]
  } else {
    return $SCEPmanHostNames
  }
}

function GetAppServiceVnetId ($AppServiceName, $ResourceGroup) {
  $vnetId = ExecuteAzCommandRobustly -callAzNatively -azCommand @("webapp", "show", "--name", $AppServiceName, "--resource-group", $ResourceGroup, "--query", 'virtualNetworkSubnetId', "--output", "tsv")
  return $vnetId
}

function SetAppServiceVnetId ($AppServiceName, $ResourceGroup, $vnetId, $DeploymentSlotName) {
  $command = @("webapp", "update", "--name", $AppServiceName, "-g", $ResourceGroup, "--set", "virtualNetworkSubnetId=$vnetId")
  if ($null -ne $DeploymentSlotName) {
    $command += @("--slot", $DeploymentSlotName)
  }
  $null = ExecuteAzCommandRobustly -callAzNatively -azCommand $command
}

function CreateSCEPmanDeploymentSlot ($SCEPmanResourceGroup, $SCEPmanAppServiceName, $DeploymentSlotName) {
  $existingHostnameConfiguration = ReadAppSetting -AppServiceName $SCEPmanAppServiceName -ResourceGroup $SCEPmanResourceGroup -SettingName "AppConfig:AuthConfig:ManagedIdentityEnabledForWebsiteHostname"

  if([string]::IsNullOrEmpty($existingHostnameConfiguration)) {
    $SCEPmanSlotHostName = GetPrimaryAppServiceHostName -SCEPmanResourceGroup $SCEPmanResourceGroup -AppServiceName $SCEPmanAppServiceName
    SetAppSettings -AppServiceName $SCEPmanAppServiceName -ResourceGroup $SCEPmanResourceGroup -Settings @(@{name="AppConfig:AuthConfig:ManagedIdentityEnabledForWebsiteHostname"; value=$SCEPmanSlotHostName}) -AsSlotSettings $true -Slot $DeploymentSlotName
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
    return [array]$deploymentSlots
  }
}

function MarkDeploymentSlotAsConfigured($SCEPmanResourceGroup, $SCEPmanAppServiceName, $PermissionLevel, $DeploymentSlotName = $null) {
  # Add a setting to tell the Deployment slot that it has been configured
  $SCEPmanSlotHostName = GetPrimaryAppServiceHostName -SCEPmanResourceGroup $SCEPmanResourceGroup -AppServiceName $SCEPmanAppServiceName -DeploymentSlotName $DeploymentSlotName

  $managedIdentityEnabledOn = ([DateTimeOffset]::UtcNow).ToUnixTimeSeconds()

  Write-Verbose "[$SCEPmanAppServiceName-$DeploymentSlotName] Marking SCEPman App Service as configured (timestamp $managedIdentityEnabledOn)"

  $MarkAsConfiguredSettings = @(
    @{name="AppConfig:AuthConfig:ManagedIdentityEnabledOnUnixTime"; value=$managedIdentityEnabledOn},
    @{name="AppConfig:AuthConfig:ManagedIdentityEnabledForWebsiteHostname"; value=$SCEPmanSlotHostName},
    @{name="AppConfig:AuthConfig:ManagedIdentityPermissionLevel"; value=$PermissionLevel}
  )

  SetAppSettings -AppServiceName $SCEPmanAppServiceName -ResourceGroup $SCEPmanResourceGroup -Settings $MarkAsConfiguredSettings -Slot $DeploymentSlotName -AsSlotSettings $true
}

$RegExGuid = "[({]?[a-fA-F0-9]{8}[-]?([a-fA-F0-9]{4}[-]?){3}[a-fA-F0-9]{12}[})]?"

function ConfigureSCEPmanInstance ($SCEPmanResourceGroup, $SCEPmanAppServiceName, $ScepManAppSettings, $PermissionLevel, $SCEPmanAppId, $DeploymentSlotName = $null) {
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
    if ($null -ne $DeploymentSlotName) {
      $azCommand += @("--slot", $DeploymentSlotName)
    }
    $null = ExecuteAzCommandRobustly -callAzNatively -azCommand $azCommand
    Write-Verbose "[$SCEPmanAppServiceName-$DeploymentSlotName] Backed up ApplicationKey"
  }

  MarkDeploymentSlotAsConfigured -SCEPmanResourceGroup $SCEPmanResourceGroup -SCEPmanAppServiceName $SCEPmanAppServiceName -DeploymentSlotName $DeploymentSlotName -PermissionLevel $PermissionLevel
}

function ConfigureScepManAppService($SCEPmanResourceGroup, $SCEPmanAppServiceName, $DeploymentSlotName, $CertMasterBaseURL, $SCEPmanAppId, $PermissionLevel) {
  Write-Verbose "Configuring SCEPman web app settings for Deployment Slot [$DeploymentSlotName]"

  # Add ApplicationId and some additional defaults in SCEPman web app settings

  $ScepManAppSettings = @(
    @{ name='AppConfig:AuthConfig:ApplicationId'; value=$SCEPmanAppID }
  )

  if (-not [string]::IsNullOrEmpty($CertMasterBaseURL)) {
    $ScepManAppSettings += @{ name='AppConfig:CertMaster:URL'; value=$CertMasterBaseURL }
    $ScepManAppSettings += @{ name='AppConfig:DirectCSRValidation:Enabled'; value='true' }
  }

  ConfigureSCEPmanInstance -SCEPmanResourceGroup $SCEPmanResourceGroup -SCEPmanAppServiceName $SCEPmanAppServiceName -ScepManAppSettings $ScepManAppSettings -PermissionLevel $PermissionLevel -SCEPmanAppId $SCEPmanAppID -DeploymentSlotName $DeploymentSlotName
}

function ConfigureCertMasterAppService($CertMasterResourceGroup, $CertMasterAppServiceName, $SCEPmanAppId, $CertMasterAppId, $PermissionLevel) {
  Write-Information "Setting Certificate Master configuration"
  $managedIdentityEnabledOn = ([DateTimeOffset]::UtcNow).ToUnixTimeSeconds()

  # Add ApplicationId and SCEPman API scope in certmaster web app settings
  $CertmasterAppSettings = @{
    'AppConfig:AuthConfig:ApplicationId' = $CertMasterAppId
    'AppConfig:AuthConfig:SCEPmanAPIScope' = "api://$SCEPmanAppId"
  }

  if ($PermissionLevel -ge 0) {
    $CertmasterAppSettings['AppConfig:AuthConfig:ManagedIdentityEnabledOnUnixTime'] = "$managedIdentityEnabledOn"
    $CertmasterAppSettings['AppConfig:AuthConfig:ManagedIdentityPermissionLevel'] = $PermissionLevel
  }

  $isCertMasterLinux = IsAppServiceLinux -AppServiceName $CertMasterAppServiceName -ResourceGroup $CertMasterResourceGroup
  $CertmasterAppSettingsJson = AppSettingsHashTable2AzJson -psHashTable $CertmasterAppSettings -convertForLinux $isCertMasterLinux

  $null = ExecuteAzCommandRobustly -azCommand "az webapp config appsettings set --name $CertMasterAppServiceName --resource-group $CertMasterResourceGroup --settings '$CertmasterAppSettingsJson'"
}

function Update-ToConfiguredChannel {
  [CmdletBinding(SupportsShouldProcess=$true)]
  param (
    [Parameter(Mandatory=$true)]    [string]$AppServiceName,
    [Parameter(Mandatory=$true)]    [string]$ResourceGroup,
    [Parameter(Mandatory=$true)]    [hashtable]$ChannelArtifacts
  )

  $intendedChannel = ExecuteAzCommandRobustly -azCommand @("webapp", "config", "appsettings", "list", "--name", $AppServiceName,
    "--resource-group", $ResourceGroup, "--query", "[?name=='Update_Channel'].value | [0]", "--output", "tsv") -callAzNatively -noSecretLeakageWarning

  if (-not [string]::IsNullOrWhiteSpace($intendedChannel) -and "none" -ne $intendedChannel) {
    Write-Information "Switching app $AppServiceName to update channel $intendedChannel"
    $ArtifactsUrl = $ChannelArtifacts[$intendedChannel]
    if ([string]::IsNullOrWhiteSpace($ArtifactsUrl)) {
      Write-Warning "Could not find Artifacts URL for Channel $intendedChannel of App Service $AppServiceName. Available values: $(Join-String -Separator ',' -InputObject $ChannelArtifacts.Keys)"
    } else {
      Write-Verbose "Artifacts URL is $ArtifactsUrl"
      if ($PSCmdlet.ShouldProcess($AppServiceName, ("Switching App Service to channel {0}" -f $intendedChannel))) {
        $null = ExecuteAzCommandRobustly -azCommand @("webapp", "config", "appsettings", "set", "--name", $AppServiceName, "--resource-group", $ResourceGroup, "--settings", "WEBSITE_RUN_FROM_PACKAGE=$ArtifactsUrl") -callAzNatively
        $null = ExecuteAzCommandRobustly -azCommand "az webapp config appsettings delete --name $AppServiceName --resource-group $ResourceGroup --setting-names ""Update_Channel"""
      }
    }
  }
}

function SetAppSettings($AppServiceName, $ResourceGroup, $Settings, $Slot = $null, $AsSlotSettings = $false) {
  $totalSettingsCount = $Settings.Count
  $processedSettingsCount = 0
  foreach ($oneSetting in $Settings) {
    $settingName = $oneSetting.name
    $settingValueEscaped = $oneSetting.value.ToString().Replace('"','\"')
    if ($settingName.Contains("=")) {
      Write-Warning "Setting name $settingName contains at least one equal sign (=), which is unsupported. Skipping this setting."
      continue
    }
    $isAppServiceLinux = IsAppServiceLinux -AppServiceName $AppServiceName -ResourceGroup $ResourceGroup
    if ($isAppServiceLinux) {
      if ($settingName.Contains("-")) {
        Write-Warning "Setting name $settingName contains at least one dash (-), which is unsupported on Linux. Skipping this setting."
        continue
      }
      $settingName = $settingName.Replace(":", "__")
    }
    Write-Verbose "Setting app setting $settingName of app $AppServiceName in slot [$Slot]"
    Write-Debug "Setting $settingName to $settingValueEscaped"  # there could be cases where this is a secret, so we do not use Write-Verbose
    if ($PSVersionTable.PSVersion.Major -eq 5 -or -not $PSVersionTable.OS.StartsWith("Microsoft Windows")) {
      $settingAssignment = "$settingName=$settingValueEscaped"
    } else {
      $settingAssignment = "`"$settingName`"=`"$settingValueEscaped`""
    }

    $command = @('webapp', 'config', 'appsettings', 'set', '--name', $AppServiceName, '--resource-group', $ResourceGroup)
    if ($AsSlotSettings) {
      $command += @('--slot-settings', $settingAssignment)
    } else {
      $command += @('--settings', $settingAssignment)
    }
    if (-not [String]::IsNullOrEmpty($Slot)) {
      $command += @('--slot', $Slot)
    }

    $null = ExecuteAzCommandRobustly -callAzNatively -azCommand $command
    $processedSettingsCount++
    Write-Progress -Activity "Setting app settings" -Status "Processed $processedSettingsCount of $totalSettingsCount settings" -PercentComplete (($processedSettingsCount / $totalSettingsCount) * 100)
  }
  Write-Progress -Activity "Setting app settings" -Completed -Status "Processed $processedSettingsCount of $totalSettingsCount settings" -PercentComplete 100
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

  $settingValue = ExecuteAzCommandRobustly -callAzNatively -azCommand $azCommand -noSecretLeakageWarning

  if(![string]::IsNullOrEmpty($settingValue)) {
    return $settingValue.Trim('"')
  } else {
    return $settingValue
  }
}