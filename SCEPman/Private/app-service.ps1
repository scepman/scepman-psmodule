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
                $CertMasterAppServiceName = $potentialcmwebapp.name
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
      $runtimes = ConvertLinesToObject -lines $(az webapp list-runtimes)
      [String []]$WindowsDotnetRuntimes = $runtimes.windows | Where-Object { $_.ToLower().startswith("dotnet:") }
      return $WindowsDotnetRuntimes[0]
  }
  catch
  {
      return "dotnet:6"
  }
}

function CreateCertMasterAppService ($SCEPmanResourceGroup, $SCEPmanAppServiceName, $CertMasterAppServiceName, $DeploymentSlotName) {
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
      "AppConfig:AuthConfig:TenantId" = $subscription.tenantId;
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

function GetDeploymentSlots($appServiceName, $resourceGroup) {
  $deploymentSlots = ConvertLinesToObject -lines $(az webapp deployment slot list --name $appServiceName --resource-group $resourceGroup --query '[].name')
  return $deploymentSlots
}

