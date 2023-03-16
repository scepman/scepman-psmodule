function AddSCEPmanPermissionsToKeyVault ($KeyVaultName, $PrincipalId) {
  $null = az keyvault set-policy --name $KeyVaultName --object-id $PrincipalId --key-permissions create unwrapKey sign
  $null = az keyvault set-policy --name $KeyVaultName --object-id $PrincipalId --secret-permissions get list set delete
  $null = az keyvault set-policy --name $KeyVaultName --object-id $PrincipalId --certificate-permissions get list create managecontacts
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
  [uri]$configuredKeyVaultURL = ExecuteAzCommandRobustly -azCommand "az webapp config appsettings list --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --query `"[?name=='AppConfig:KeyVaultConfig:KeyVaultURL'].value | [0]`" --output tsv"
  Write-Verbose "Configured Key Vault URL is $configuredKeyVaultURL"
  
  return $configuredKeyVaultURL
}

function New-IntermediateCaCsr ($vaultUrl, $certificateName, $policy) {

  $vaultDomain = $vaultUrl -replace '^https://(?<vaultname>[^.]+)\.(?<vaultdomain>[^/]+)/?$','https://${vaultdomain}'

  $caPolicyJson = HashTable2AzJson -psHashTable $policy

  # This az command seems not to work :-(
  #az keyvault certificate create --policy @C:\temp\certs\keyvault\rsa-policy.json --vault-name $vaultName --name $certificateName

    # The direct graph call instead works
  $creationResponseLines = ExecuteAzCommandRobustly -azCommand "az rest --method post --uri $($vaultUrl)certificates/$certificateName/create?api-version=7.0 --headers 'Content-Type=application/json' --resource $vaultDomain --body '$caPolicyJson'"
  $creationResponse = Convert-LinesToObject -lines $creationResponseLines

  Write-Information "Created a CSR with Request ID $($creationResponse.request_id)"

  return $creationResponse.csr
}

function Get-RsaDefaultPolicy {
  return @{
    "policy" = @{
      "key_props" = @{
        "exportable" = $false
        "kty" = "RSA"
        "key_size" = 2048
        "reuse_key" = $false
      }
      "secret_props" = @{
        "contentType" = "application/x-pkcs12"
      }
      "x509_props" = @{
        "subject" = "CN=SCEPman Intermediate CA,OU={{TenantId}}"
        "ekus" = @(
          "2.5.29.37.0",        # Any
          "1.3.6.1.5.5.7.3.2",  # Client Authentication
          "1.3.6.1.5.5.7.3.1",  # Server Authentication
          "1.3.6.1.5.5.7.3.9",  # OCSP Signing
          "1.3.6.1.4.1.311.20.2.2",  # Smart Card Logon
          "1.3.6.1.5.2.3.5"     # Kerberos Authentication
        )
        "key_usage" = @(
          "cRLSign",
          "digitalSignature",
          "keyCertSign",
          "keyEncipherment"
        )
        "validity_months" = 120
        "basic_constraints" = @{
            "ca" = $true
        }
      }
      "lifetime_actions" = @(
        @{
          "trigger" = @{
            "lifetime_percentage" = 80
          }
          "action" = @{
            "action_type" = "EmailContacts"
          }
        }
      )
      "issuer" = @{
        "name" = "Unknown"
        "cert_transparency" = $false
      }
    }
  }
}