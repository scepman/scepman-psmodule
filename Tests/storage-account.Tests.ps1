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
            throw "Unexpected command: $args"
        }
    }

    It 'Finds an existing Storage Account' {
        $staccount = GetExistingStorageAccount -dataTableEndpoint 'https://stgxyztest.table.core.windows.net/'

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
    }
}