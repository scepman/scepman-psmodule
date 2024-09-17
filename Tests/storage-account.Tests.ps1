BeforeAll {
  . $PSScriptRoot/../SCEPman/Private/constants.ps1
  . $PSScriptRoot/../SCEPman/Private/az-commands.ps1
  . $PSScriptRoot/../SCEPman/Private/storage-account.ps1
}

Describe 'Storage Account' {
  BeforeEach {
    Mock az {
      return '{
      "count": 1,
"data": [
{
  "location": "germanywestcentral",
  "name": "stgxyztest",
  "primaryEndpoints": {
    "blob": "https://stgxyztest.blob.core.windows.net/",
    "dfs": "https://stgxyztest.dfs.core.windows.net/",
    "file": "https://stgxyztest.file.core.windows.net/",
    "queue": "https://stgxyztest.queue.core.windows.net/",
    "table": "https://stgxyztest.table.core.windows.net/",
    "web": "https://stgxyztest.z1.web.core.windows.net/"
  },
  "resourceGroup": "rg-xyz-test",
  "subscriptionId": "63ee67fb-aad6-4711-82a9-ff838a489299"
}
],
"skip_token": null,
"total_records": 1
}' } -ParameterFilter { $args[0] -eq 'graph' -and $args[1] -eq "query" }
    Mock az {
      throw "Unexpected parameter for az: $args (with array values $($args[0]), $($args[1]), ... -- #$($args.Count) in total)"
    }
  }

  It 'Finds an existing Storage Account' {
    # Act
    $staccount = GetExistingStorageAccount -dataTableEndpoint 'https://stgxyztest.table.core.windows.net/'

    # Assert
    $staccount.location | Should -Be "germanywestcentral"
    $staccount.name | Should -Be "stgxyztest"
    $staccount.primaryEndpoints.blob | Should -Be "https://stgxyztest.blob.core.windows.net/"
    $staccount.primaryEndpoints.dfs | Should -Be "https://stgxyztest.dfs.core.windows.net/"
    $staccount.primaryEndpoints.file | Should -Be "https://stgxyztest.file.core.windows.net/"
    $staccount.primaryEndpoints.queue | Should -Be "https://stgxyztest.queue.core.windows.net/"
    $staccount.primaryEndpoints.table | Should -Be "https://stgxyztest.table.core.windows.net/"
    $staccount.primaryEndpoints.web | Should -Be "https://stgxyztest.z1.web.core.windows.net/"
    $staccount.resourceGroup | Should -Be "rg-xyz-test"
    $staccount.subscriptionId | Should -Be "63ee67fb-aad6-4711-82a9-ff838a489299"

    Assert-MockCalled az -Exactly 1 -Scope It
  }

  Context "When SCEPman and CertMaster have a configured Storage Account" {
    BeforeAll {
      [System.Collections.IList]$script:servicePrincipals = @('12345678-aad6-4711-82a9-0123456789ab', '98765432-aad6-4711-82a9-9876543210ab')

      . $PSScriptRoot/../SCEPman/Private/app-service.ps1

      Mock ReadAppSetting { return "https://stgxyztest.table.core.windows.net/" } -ParameterFilter { $SettingName -eq 'AppConfig:CertificateStorage:TableStorageEndpoint' }
      Mock ReadAppSetting { throw "Unexpected parameters for ReadAppSetting: $args (with array values $($args[0]), $($args[1]), ... -- #$($args.Count) in total)" }
      Mock SetAppSettings { } -ParameterFilter { $Settings.name -eq "AppConfig:CertificateStorage:TableStorageEndpoint" -and $Settings.value -eq "https://stgxyztest.table.core.windows.net/" -and $AppServiceName -eq 'app-scepman' }
      Mock SetAppSettings { throw "Unexpected parameters for SetAppSettings: $args (with array values $($args[0]), $($args[1]), ... -- #$($args.Count) in total)" }

      Mock Invoke-Az { } -ParameterFilter { ($azCommand[0] -eq 'role' -and $azCommand[1] -eq 'assignment' -and $azCommand[2] -eq 'create') }
    }

    It 'Sets Storage Account settings in SCEPman while skipping Certificate Master' {
      # Arrange
      #  Done in BeforeAll already

      # Act
      Set-TableStorageEndpointsInScAndCmAppSettings -SubscriptionId '63ee67fb-aad6-4711-82a9-ff838a489299' -SCEPmanResourceGroup 'rg-xyz-test' -SCEPmanAppServiceName 'app-scepman' -servicePrincipals $servicePrincipals -CertMasterAppServiceName $null -DeploymentSlots @($null)

      # Assert
      Assert-MockCalled ReadAppSetting -Exactly 1 -Scope It
      Assert-MockCalled SetAppSettings -Exactly 1 -Scope It

      Assert-MockCalled Invoke-Az -Exactly 2 -Scope It -ParameterFilter { ($azCommand[0] -eq 'role' -and $azCommand[1] -eq 'assignment' -and $azCommand[2] -eq 'create') }
    }

    It 'Sets Storage Account settings in SCEPman and Certificate Master' {
      # Arrange
      Mock ReadAppSetting { return "https://stgxyztest.table.core.windows.net/" } -ParameterFilter { $SettingName -eq 'AppConfig:AzureStorage:TableStorageEndpoint' }
      Mock SetAppSettings { } -ParameterFilter { $Settings.name -eq "AppConfig:AzureStorage:TableStorageEndpoint" -and $Settings.value -eq "https://stgxyztest.table.core.windows.net/" -and $AppServiceName -eq 'app-certmaster' }

      # Act
      Set-TableStorageEndpointsInScAndCmAppSettings -SubscriptionId '63ee67fb-aad6-4711-82a9-ff838a489299' -SCEPmanResourceGroup 'rg-xyz-test' -SCEPmanAppServiceName 'app-scepman' -servicePrincipals $servicePrincipals -CertMasterAppServiceName 'app-certmaster' -DeploymentSlots @($null)

      # Assert
      Assert-MockCalled ReadAppSetting -Exactly 2 -Scope It
      Assert-MockCalled SetAppSettings -Exactly 2 -Scope It

      Assert-MockCalled Invoke-Az -Exactly 2 -Scope It -ParameterFilter { ($azCommand[0] -eq 'role' -and $azCommand[1] -eq 'assignment' -and $azCommand[2] -eq 'create') }

    }
  }
}