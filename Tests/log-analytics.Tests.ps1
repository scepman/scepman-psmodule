BeforeAll {
    . $PSScriptRoot/../SCEPman/Private/constants.ps1
    . $PSScriptRoot/../SCEPman/Private/az-commands.ps1
    . $PSScriptRoot/../SCEPman/Private/log-analytics.ps1

    . $PSScriptRoot/test-helpers.ps1

    function ReadAppSetting($AppServiceName, $ResourceGroup, $SettingName, $Slot = $null) { }
    function RemoveAppSettings($AppServiceName, $ResourceGroup, $SettingNames, $Slot = $null) { }
    function SetAppSettings($AppServiceName, $ResourceGroup, $Settings, $Slot = $null, $AsSlotSettings = $false) { }

    function global:Format-InvokeAzCommand($azCommand) {
        (@($azCommand) | ForEach-Object { $_.ToString() }) -join ' '
    }

    function global:New-GraphQueryResult($Data) {
        @{
            count = @($Data).Count
            data = @($Data)
            skip_token = $null
            total_records = @($Data).Count
        } | ConvertTo-Json -Depth 10 -Compress
    }
}

Describe 'Log Analytics' {
    It 'lets the operator pick the intended workspace when multiple workspaces exist in the resource group' {
        $workspaceOne = @{ name = 'law-prod'; workspaceId = '11111111-1111-1111-1111-111111111111'; location = 'westeurope'; resourceGroup = 'rg-scepman' }
        $workspaceTwo = @{ name = 'law-shared'; workspaceId = '22222222-2222-2222-2222-222222222222'; location = 'westeurope'; resourceGroup = 'rg-scepman' }

        Mock Invoke-Az {
            param($azCommand, $maxRetries)
            throw "Unexpected command: $(Format-InvokeAzCommand -azCommand $azCommand)"
        }
        Mock Invoke-Az {
            return New-GraphQueryResult @($workspaceOne, $workspaceTwo)
        } -ParameterFilter {
            $azCommand[0] -eq 'graph' -and
            $azCommand[1] -eq 'query' -and
            $azCommand[3].Contains("resourceGroup == 'rg-scepman'")
        }
        Mock Read-Host {
            return 'law-shared'
        } -ParameterFilter { ($Prompt -join '') -like '*more than one existing log analytics workspace*' }

        $workspace = GetLogAnalyticsWorkspace -ResourceGroup 'rg-scepman'

        $workspace.name | Should -Be 'law-shared'
        $workspace.workspaceId | Should -Be '22222222-2222-2222-2222-222222222222'
        Should -Invoke Invoke-Az -Exactly 1 -ParameterFilter {
            $azCommand[0] -eq 'graph' -and
            $azCommand[1] -eq 'query' -and
            $azCommand[3].Contains("resourceGroup == 'rg-scepman'")
        }
    }

    It 'migrates an existing custom table and updates the schema when required columns are missing' {
        $workspaceAccount = @{ name = 'law-prod'; resourceGroup = 'rg-scepman'; location = 'westeurope' }
        $tableDetails = @{
            schema = @{
                tableSubType = 'CustomLog'
                columns = @(
                    @{ name = 'Timestamp' },
                    @{ name = 'Level' }
                )
                standardColumns = @(
                    @{ name = 'TimeGenerated' }
                )
            }
        }

        Mock GetLogAnalyticsTable {
            return $tableDetails
        }
        Mock Invoke-Az {
            param($azCommand, $maxRetries)
            throw "Unexpected command: $(Format-InvokeAzCommand -azCommand $azCommand)"
        }
        Mock Invoke-Az {
            return $null
        } -ParameterFilter {
            $azCommand[0] -eq 'monitor' -and
            $azCommand[1] -eq 'log-analytics' -and
            $azCommand[2] -eq 'workspace' -and
            $azCommand[3] -eq 'table' -and
            $azCommand[4] -eq 'migrate' -and
            $azCommand -contains '--table-name' -and
            $azCommand -contains $LogsTableName
        }
        Mock Invoke-Az {
            $normalizedCommand = Format-InvokeAzCommand -azCommand $azCommand
            $normalizedCommand | Should -Match '--columns'
            $normalizedCommand | Should -Match 'TraceIdentifier=string'
            return $null
        } -ParameterFilter {
            $azCommand[0] -eq 'monitor' -and
            $azCommand[1] -eq 'log-analytics' -and
            $azCommand[2] -eq 'workspace' -and
            $azCommand[3] -eq 'table' -and
            $azCommand[4] -eq 'update' -and
            $azCommand -contains '--name' -and
            $azCommand -contains $LogsTableName
        }

        ValidateLogAnalyticsTable -ResourceGroup 'rg-scepman' -WorkspaceAccount $workspaceAccount -SubscriptionId 'sub-1'

        Should -Invoke GetLogAnalyticsTable -Exactly 1 -ParameterFilter { $tableName -eq $LogsTableName }
        Should -Invoke Invoke-Az -Exactly 1 -ParameterFilter {
            $azCommand[0] -eq 'monitor' -and
            $azCommand[1] -eq 'log-analytics' -and
            $azCommand[2] -eq 'workspace' -and
            $azCommand[3] -eq 'table' -and
            $azCommand[4] -eq 'migrate' -and
            $azCommand -contains '--table-name' -and
            $azCommand -contains $LogsTableName
        }
        Should -Invoke Invoke-Az -Exactly 1 -ParameterFilter {
            $azCommand[0] -eq 'monitor' -and
            $azCommand[1] -eq 'log-analytics' -and
            $azCommand[2] -eq 'workspace' -and
            $azCommand[3] -eq 'table' -and
            $azCommand[4] -eq 'update' -and
            $azCommand -contains '--name' -and
            $azCommand -contains $LogsTableName
        }
    }

    It 'updates an existing data collection rule when the ingestion mapping is incomplete' {
        $workspaceAccount = @{ name = 'law-prod'; resourceGroup = 'rg-scepman'; location = 'westeurope' }
        $workspaceResourceId = '/subscriptions/sub-1/resourceGroups/rg-scepman/providers/microsoft.operationalinsights/workspaces/law-prod'
        $existingDcr = @{
            id = '/subscriptions/sub-1/resourceGroups/rg-scepman/providers/Microsoft.Insights/dataCollectionRules/dcr-scepmanlogs'
            name = $DCRName
            immutableId = 'old-rule-id'
            endpoints = @{ logsIngestion = 'https://old.ingest' }
            destinations = @{ logAnalytics = @() }
            streamDeclarations = @{
                'Custom-SCEPmanLogs' = @{
                    columns = @(
                        @{ name = 'Timestamp' },
                        @{ name = 'Level' }
                    )
                }
            }
            dataFlows = @(
                @{
                    streams = @('Custom-SCEPmanLogs')
                    outputStream = 'Custom-OldTable_CL'
                }
            )
        }
        $updatedDcr = @{
            id = '/subscriptions/sub-1/resourceGroups/rg-scepman/providers/Microsoft.Insights/dataCollectionRules/dcr-scepmanlogs'
            immutableId = 'new-rule-id'
            endpoints = @{ logsIngestion = 'https://new.ingest' }
        }

        Mock Invoke-Az {
            param($azCommand, $maxRetries)
            throw "Unexpected command: $(Format-InvokeAzCommand -azCommand $azCommand)"
        }
        Mock Invoke-Az {
            return $existingDcr | ConvertTo-Json -Depth 10 -Compress
        } -ParameterFilter {
            $azCommand[0] -eq 'monitor' -and
            $azCommand[1] -eq 'data-collection' -and
            $azCommand[2] -eq 'rule' -and
            $azCommand[3] -eq 'show' -and
            $azCommand -contains '--name' -and
            $azCommand -contains $DCRName -and
            $maxRetries -eq 0
        }
        Mock Invoke-Az {
            $normalizedCommand = Format-InvokeAzCommand -azCommand $azCommand
            $normalizedCommand | Should -Match '--data-flows-raw'
            return $updatedDcr | ConvertTo-Json -Depth 10 -Compress
        } -ParameterFilter {
            $azCommand[0] -eq 'monitor' -and
            $azCommand[1] -eq 'data-collection' -and
            $azCommand[2] -eq 'rule' -and
            $azCommand[3] -eq 'update' -and
            $azCommand -contains '--name' -and
            $azCommand -contains $DCRName -and
            $azCommand -contains '--data-flows-raw'
        }

        $dcrDetails = ValidateDCR -ResourceGroup 'rg-scepman' -WorkspaceAccount $workspaceAccount -WorkspaceResourceId $workspaceResourceId

        $dcrDetails.immutableId | Should -Be 'new-rule-id'
        $dcrDetails.endpoints.logsIngestion | Should -Be 'https://new.ingest'
        Should -Invoke Invoke-Az -Exactly 1 -ParameterFilter {
            $azCommand[0] -eq 'monitor' -and
            $azCommand[1] -eq 'data-collection' -and
            $azCommand[2] -eq 'rule' -and
            $azCommand[3] -eq 'show' -and
            $azCommand -contains '--name' -and
            $azCommand -contains $DCRName -and
            $maxRetries -eq 0
        }
        Should -Invoke Invoke-Az -Exactly 1 -ParameterFilter {
            $azCommand[0] -eq 'monitor' -and
            $azCommand[1] -eq 'data-collection' -and
            $azCommand[2] -eq 'rule' -and
            $azCommand[3] -eq 'update' -and
            $azCommand -contains '--name' -and
            $azCommand -contains $DCRName -and
            $azCommand -contains '--data-flows-raw'
        }
    }

    It 'switches an app and its slot from workspace-id logging to the log ingestion API settings' {
        $workspaceAccount = @{ name = 'law-prod'; workspaceId = 'workspace-id'; resourceGroup = 'rg-scepman'; location = 'westeurope' }
        $dcrDetails = @{
            id = '/subscriptions/sub-1/resourceGroups/rg-scepman/providers/Microsoft.Insights/dataCollectionRules/dcr-scepmanlogs'
            immutableId = 'dcr-immutable-id'
            endpoints = @{ logsIngestion = 'https://new.ingest' }
        }
        [System.Collections.IList]$servicePrincipals = @('sp-scepman', 'sp-certmaster')

        Mock ReadAppSetting {
            throw "Unexpected setting lookup: $SettingName"
        }
        Mock ReadAppSetting {
            return 'workspace-id'
        } -ParameterFilter { $SettingName -eq 'AppConfig:LoggingConfig:WorkspaceId' }
        Mock ReadAppSetting {
            return $null
        } -ParameterFilter { $SettingName -eq 'AppConfig:LoggingConfig:RuleId' }
        Mock GetLogAnalyticsWorkspace {
            return $workspaceAccount
        } -ParameterFilter { $ResourceGroup -eq 'rg-scepman' -and $WorkspaceId -eq 'workspace-id' }
        Mock ConfigureLogIngestionAPIResources {
            return $dcrDetails
        } -ParameterFilter { $WorkspaceAccount.name -eq 'law-prod' -and $SubscriptionId -eq 'sub-1' }
        Mock RemoveAppSettings {
            $AppServiceName | Should -Be 'app-scepman'
            $ResourceGroup | Should -Be 'rg-scepman'
            $SettingNames | Should -Contain 'AppConfig:LoggingConfig:WorkspaceId'
            $SettingNames | Should -Contain 'AppConfig:LoggingConfig:SharedKey'
            if ($null -ne $Slot) {
                $Slot | Should -Be 'staging'
            }
        }
        Mock SetAppSettings {
            $AppServiceName | Should -Be 'app-scepman'
            $ResourceGroup | Should -Be 'rg-scepman'
            if ($null -ne $Slot) {
                $Slot | Should -Be 'staging'
            }

            ($Settings | Where-Object { $_.name -eq 'AppConfig:LoggingConfig:DataCollectionEndpointUri' }).value | Should -Be 'https://new.ingest'
            ($Settings | Where-Object { $_.name -eq 'AppConfig:LoggingConfig:RuleId' }).value | Should -Be 'dcr-immutable-id'
        }
        Mock AddAppRoleAssignmentsForLogIngestionAPI { }

        Set-LoggingConfigInAppSettings -SubscriptionId 'sub-1' -ResourceGroup 'rg-scepman' -AppServiceName 'app-scepman' -servicePrincipals $servicePrincipals -DeploymentSlots @('staging')

        Should -Invoke ReadAppSetting -Exactly 2
        Should -Invoke GetLogAnalyticsWorkspace -Exactly 1 -ParameterFilter { $ResourceGroup -eq 'rg-scepman' -and $WorkspaceId -eq 'workspace-id' }
        Should -Invoke ConfigureLogIngestionAPIResources -Exactly 1 -ParameterFilter { $WorkspaceAccount.name -eq 'law-prod' -and $SubscriptionId -eq 'sub-1' }
        Should -Invoke RemoveAppSettings -Exactly 2
        Should -Invoke SetAppSettings -Exactly 2
        Should -Invoke AddAppRoleAssignmentsForLogIngestionAPI -Exactly 2 -ParameterFilter { $DcrResourceId -eq $dcrDetails.id }
    }
}