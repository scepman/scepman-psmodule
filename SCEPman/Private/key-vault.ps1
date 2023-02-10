function AddSCEPmanPermissionsToKeyVault ($KeyVaultName, $PrincipalId) {
  $null = az keyvault set-policy --name $KeyVaultName --object-id $PrincipalId --key-permissions update create import delete recover backup decrypt encrypt unwrapKey wrapKey verify sign
  $null = az keyvault set-policy --name $KeyVaultName --object-id $PrincipalId --secret-permissions get list set delete recover backup restore
  $null = az keyvault set-policy --name $KeyVaultName --object-id $PrincipalId --certificate-permissions backup create delete deleteissuers get getissuers import list listissuers managecontacts manageissuers recover restore setissuers update
}

function FindConfiguredKeyVault ($SCEPmanResourceGroup, $SCEPmanAppServiceName) {
  [uri]$configuredKeyVaultURL = FindConfiguredKeyVaultUrl -SCEPmanResourceGroup $SCEPmanResourceGroup -SCEPmanAppServiceName $SCEPmanAppServiceName

  # The URL format is https://<KeyVaultName>.vault.azure.net/
  $keyVaultName = $configuredKeyVaultURL.Host.Split('.')[0]
  if ([String]::IsNullOrWhiteSpace($keyVaultName)) {
    throw "Retrieved Key Vault URL '$configuredKeyVaultURL' and couldn't parse Key Vault Name from this"
  }
  return $keyVaultName
}

function FindConfiguredKeyVaultUrl ($SCEPmanResourceGroup, $SCEPmanAppServiceName) {
  [uri]$configuredKeyVaultURL = az webapp config appsettings list --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --query "[?name=='AppConfig:KeyVaultConfig:KeyVaultURL'].value | [0]" --output tsv
  Write-Verbose "Configured Key Vault URL is $configuredKeyVaultURL"
  
  return $configuredKeyVaultURL
}

function New-IntermediateCaCsr ($vaultUrl, $certificateName) {

  $vaultDomain = $vaultUrl -replace '^https://(?<vaultname>[^.]+)\.(?<vaultdomain>[^/]+)/?$','https://${vaultdomain}'

  $caPolicyJson = HashTable2AzJson -psHashTable $global:subCaPolicy

  # This az command seems not to work :-(
  #az keyvault certificate create --policy @C:\temp\certs\keyvault\rsa-policy.json --vault-name $vaultName --name $certificateName

    # The direct graph call instead works
  $creationResponseLines = ExecuteAzCommandRobustly -azCommand "az rest --method post --uri $($vaultUrl)certificates/$certificateName/create?api-version=7.0 --headers 'Content-Type=application/json' --resource $vaultDomain --body '$caPolicyJson'"
  $creationResponse = ConvertLinesToObject -lines $creationResponseLines

  Write-Information "Created a CSR with Request ID $($creationResponse.request_id)"

  return $creationResponse.csr
}

$global:subCaPolicy = $RSAPolicyTemplate