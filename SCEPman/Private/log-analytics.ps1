function GetLogAnalyticsWorkspace ($ResourceGroup, $WorkspaceId) {
    if($null -eq $WorkspaceId) {
        $workspaces = Invoke-Az @("graph", "query", "-q", "Resources | where type == 'microsoft.operationalinsights/workspaces' and resourceGroup == '$ResourceGroup' | project name, workspaceId = properties.customerId, location") | Convert-LinesToObject
    } else {
        $workspaces = Invoke-Az @("graph", "query", "-q", "Resources | where type == 'microsoft.operationalinsights/workspaces' and properties.customerId == '$WorkspaceId' | project name, workspaceId = properties.customerId, location") | Convert-LinesToObject
    }

    if($workspaces.count -eq 1) {
        Write-Information "Found log analytics workspace $($workspaces.data[0].name)"
        return $workspaces.data[0]
    } elseif($workspaces.count -gt 1) {
        Write-Information "Found log analytics workspaces:"
        $workspaces.data | ForEach-Object { Write-Information $_.name }
        $potentialWorkspaceName = Read-Host "We have found more than one existing log analytics workspace in the resource group $ResourceGroup. Please hit enter now if you still want to create a workspace or enter the workspace you would like to use, and then hit enter"
        if(!$potentialWorkspaceName) {
            Write-Information "User selected to create a log analytics workspace"
            return $null
        } else {
            $potentialWorkspace = $workspaces.data | Where-Object { $_.name -eq $potentialWorkspaceName }
            if($null -eq $potentialWorkspace) {
                Write-Error "We couldn't find a log analytics workspace with name $potentialWorkspaceName in resource group $ResourceGroup. Please try to re-run the script"
                throw "We couldn't find a log analytics workspace with name $potentialWorkspaceName in resource group $ResourceGroup. Please try to re-run the script"
            } else {
                return $potentialWorkspace
            }
        }
    }
    else {
        Write-Warning "Unable to determine the log analytics workspace"
        return $null
    }
}

function RemoveDataCollectorAPISettings ($ResourceGroup, $AppServiceName) {
    # Keep AzureOfferingDomain because it is used by the Log Ingestion API target as well
    $isAppServiceLinux = IsAppServiceLinux -AppServiceName $AppServiceName -ResourceGroup $ResourceGroup
    if($isAppServiceLinux) {
        $WorkspaceIdVariable = "AppConfig__LoggingConfig__WorkspaceId"
        $SharedKeyVariable = "AppConfig__LoggingConfig__SharedKey"
    } else {
        $WorkspaceIdVariable = "AppConfig:LoggingConfig:WorkspaceID"
        $SharedKeyVariable = "AppConfig:LoggingConfig:SharedKey"
    }
    $null = Invoke-Az @("webapp", "config", "appsettings", "delete", "--name", $AppServiceName, "--resource-group", $ResourceGroup, "--setting-names", $WorkspaceIdVariable, $SharedKeyVariable)
}

function CreateLogAnalyticsWorkspace($ResourceGroup, $WorkspaceId) {
    $workspaceAccount = GetLogAnalyticsWorkspace -ResourceGroup $ResourceGroup -WorkspaceId $WorkspaceId
        if($null -eq $workspaceAccount) {
            #Create a new workspace
            Write-Information 'Log analytics workspace not found. We will create one now'
            $workspaceName = $ResourceGroup.ToLower() -replace '[^a-z0-9]',''

            # Length between 4-63, Alphanumerics and hyphens, Start and end with alphanumeric.
            if($workspaceName.Length -gt 56) {
                $workspaceName = $workspaceName.Substring(0,56)
            }
            $workspaceName = "log-$($workspaceName)-sc"
            $potentialWorkspaceName = Read-Host "Please hit enter now if you want to create the log analytics workspace with name $workspaceName or enter the name of your choice, and then hit enter"
            if($potentialWorkspaceName) {
                $workspaceName = $potentialWorkspaceName
            }
            $workspaceAccount = Invoke-Az @("monitor", "log-analytics", "workspace", "create", "--resource-group", $ResourceGroup, "--name", $workspaceName, "--only-show-errors") | Convert-LinesToObject
            if($null -eq $workspaceAccount) {
                Write-Error 'Log analytics workspace not found and we are unable to create one. Please check logs for more details before re-running the script'
                throw 'Log analytics workspace not found and we are unable to create one. Please check logs for more details before re-running the script'
            }
            Write-Information "Log analytics workspace $workspaceName created"
        }
    return $workspaceAccount
}

function GetLogAnalyticsTable($ResourceGroup, $WorkspaceAccount, $SubscriptionId, $tableName) {
    #Don't use Invoke-Az here to avoid unnecessary retries
    $table = az monitor log-analytics workspace table show --resource-group $ResourceGroup --workspace-name $($WorkspaceAccount.name) --name $tableName | Convert-LinesToObject
    return $table
}

function CreateLogAnalyticsTable($ResourceGroup, $WorkspaceAccount, $SubscriptionId) {
    $oldTableExists = $false

    # Try to get the new table details
    $newTableDetails = GetLogAnalyticsTable -ResourceGroup $ResourceGroup -WorkspaceAccount $WorkspaceAccount -SubscriptionId $SubscriptionId -tableName $LogsTableName_New
    if ($null -ne $newTableDetails) {
        Write-Information "Table $LogsTableName_New already exists in the workspace $($WorkspaceAccount.name). Skipping the creation of the table"
        return
    }

    # Try to get the old table details to retain the retention time and plan
    $oldTableDetails = GetLogAnalyticsTable -ResourceGroup $ResourceGroup -WorkspaceAccount $WorkspaceAccount -SubscriptionId $SubscriptionId -tableName $LogsTableName_Old
    if ($null -ne $oldTableDetails) {
        $oldTableExists = $true
    }

    # Create the new table based on whether the old table exists
    $columns = @(
        "TimeGenerated=datetime",
        "Timestamp=string",
        "Level=string",
        "Message=string",
        "Exception=string",
        "TenantIdentifier=string",
        "RequestUrl=string",
        "UserAgent=string",
        "LogCategory=string",
        "EventId=string",
        "Hostname=string",
        "WebsiteHostname=string",
        "WebsiteSiteName=string",
        "WebsiteSlotName=string",
        "BaseUrl=string",
        "TraceIdentifier=string"
    ) -split " "

    $azCommandToCreateWorkspaceTable = @("monitor", "log-analytics", "workspace", "table", "create", "--resource-group", $ResourceGroup, "--workspace-name", $($WorkspaceAccount.name), "--name", $LogsTableName_New)

    if ($oldTableExists) {
        $azCommandToCreateWorkspaceTable += @("--total-retention-time", $oldTableDetails.totalRetentionInDays, "--plan", $oldTableDetails.plan)
        if (-not $oldTableDetails.retentionInDaysAsDefault) {
            $azCommandToCreateWorkspaceTable += @("--retention-time", $oldTableDetails.retentionInDays)
        }
    }

    $azCommandToCreateWorkspaceTable += "--columns"
    $azCommandToCreateWorkspaceTable += $columns
    $null = Invoke-Az $azCommandToCreateWorkspaceTable
    Write-Information "Table $LogsTableName_New successfully created in the workspace $($WorkspaceAccount.name)"
}

function AssociateDCR($RuleIdName, $WorkspaceResourceId) {
    $dcrAssociationDetails = az monitor data-collection rule association show --name $DCRAssociationName --resource $WorkspaceResourceId | Convert-LinesToObject
    if ($null -ne $dcrAssociationDetails) {
        Write-Information "Data Collection Rule association $DCRAssociationName already exists. Skipping the association of the DCR"
        return
    }
    $null = Invoke-Az @("monitor", "data-collection", "rule", "association", "create", "--name", $DCRAssociationName, "--rule-id", $RuleIdName, "--resource", $WorkspaceResourceId, "--only-show-errors")
    Write-Information "Data Collection Rule association $DCRAssociationName successfully created"
}

function CreateDCR($ResourceGroup, $WorkspaceAccount, $WorkspaceResourceId) {

    $existingDcrDetails = az monitor data-collection rule show --resource-group $ResourceGroup --name $DCRName | Convert-LinesToObject
    if ($null -ne $existingDcrDetails) {
        Write-Information "Data Collection Rule $DCRName already exists. Skipping the creation of the DCR"
        return $existingDcrDetails
    }

    # Define the destinations JSON in a variable
    $destinations = @{
        "logAnalytics" = @(
            @{
                "WorkspaceResourceId" = "$WorkspaceResourceId";
                "name" = "$LogsDestinationName"
            }
        )
    }

    # Define the streamDeclarations JSON in a variable
    $streamDeclarations = @{
        "Custom-SCEPmanLogs" = @{
            "columns" = @(
                @{ "name" = "Timestamp"; "type" = "string" },
                @{ "name" = "Level"; "type" = "string" },
                @{ "name" = "Message"; "type" = "string" },
                @{ "name" = "Exception"; "type" = "string" },
                @{ "name" = "TenantIdentifier"; "type" = "string" },
                @{ "name" = "RequestUrl"; "type" = "string" },
                @{ "name" = "UserAgent"; "type" = "string" },
                @{ "name" = "LogCategory"; "type" = "string" },
                @{ "name" = "EventId"; "type" = "string" },
                @{ "name" = "Hostname"; "type" = "string" },
                @{ "name" = "WebsiteHostname"; "type" = "string" },
                @{ "name" = "WebsiteSiteName"; "type" = "string" },
                @{ "name" = "WebsiteSlotName"; "type" = "string" },
                @{ "name" = "BaseUrl"; "type" = "string" },
                @{ "name" = "TraceIdentifier"; "type" = "string" },
                @{ "name" = "TimeGenerated"; "type" = "Datetime" }
            )
        }
    }

    # Define the dataFlows JSON in a variable
    $dataFlows = @(
        @{
            "streams" = @("Custom-SCEPmanLogs");
            "destinations" = @("$LogsDestinationName");
            "outputStream" = "Custom-$LogsTableName_New"
        }
    )

    $destinationsJson = HashTable2AzJson -psHashTable $destinations
    $streamDeclarationsJson = HashTable2AzJson -psHashTable $streamDeclarations
    $dataFlowsJson = HashTable2AzJson -psHashTable $dataFlows

    # Create DCR
    $newDcrDetails = Invoke-Az @("monitor", "data-collection", "rule", "create", "--resource-group", $ResourceGroup, "--name", $DCRName, "--description", "Data Collection Rule for SCEPman logs", "--stream-declarations", $streamDeclarationsJson, "--destinations", $destinationsJson, "--data-flows", $dataFlowsJson, "--kind", "Direct", "--location", $($WorkspaceAccount.location), "--only-show-errors") | Convert-LinesToObject
    Write-Information "Data Collection Rule $DCRName successfully created"
    return $newDcrDetails
}


function GetRuleIdName($SubscriptionId, $ResourceGroup) {
    $ruleIdName = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Insights/dataCollectionRules/$DCRName"
    return $ruleIdName
}

function ConfigureLogIngestionAPIResources($ResourceGroup, $WorkspaceAccount, $SubscriptionId) {
    Write-Information "Installing az monitor control service extension"
    az extension add --name monitor-control-service --only-show-errors

    # Create the new table
    CreateLogAnalyticsTable -ResourceGroup $ResourceGroup -WorkspaceAccount $WorkspaceAccount -SubscriptionId $SubscriptionId

     # Create and associate the DCR
    $workspaceResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/microsoft.operationalinsights/workspaces/$($WorkspaceAccount.name)"
    $dcrDetails = CreateDCR -ResourceGroup $ResourceGroup -WorkspaceAccount $WorkspaceAccount -WorkspaceResourceId $workspaceResourceId

    $ruleIdName = GetRuleIdName -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup
    AssociateDCR -RuleIdName $ruleIdName -WorkspaceResourceId $workspaceResourceId

    return $dcrDetails
}

function ShouldConfigureLogIngestionAPIInAppService($ExistingConfig, $ResourceGroup, $AppServiceName) {

    if(!$ResourceGroup -or !$AppServiceName) {
        return $false
    }

    if($null -eq $ExistingConfig -or $null -eq $ExistingConfig.settings) {
        throw "No existing configuration found in the App Service $AppServiceName. Skipping the configuration of Log ingestion API settings"
    }

    #Check if the Log ingestion API settings(DataCollectionEndpointUri, RuleId) exist; If they do, delete the data collector API settings else configure the Log ingestion API settings and then delete the data collector API settings
    $dataCollectionEndpointUri = $ExistingConfig.settings | Where-Object { $_.name -eq "AppConfig:LoggingConfig:DataCollectionEndpointUri" }
    $ruleId = $ExistingConfig.settings | Where-Object { $_.name -eq "AppConfig:LoggingConfig:RuleId" }

    if($null -ne $dataCollectionEndpointUri -and $null -ne $ruleId) {
        Write-Information "Log ingestion API settings already configured in the App Service $AppServiceName. Deleting the data collector API settings, if present"
        RemoveDataCollectorAPISettings -ResourceGroup $ResourceGroup -AppServiceName $AppServiceName
        return $false;
    }
    return $true;
}

function GetExistingWorkspaceId($ExistingConfigSc, $ExistingConfigCm, $SCEPmanAppServiceName, $CertMasterAppServiceName, $SCEPmanResourceGroup,  $SubscriptionId) {
    $workspaceIdSc = $null;
    $workspaceIdCm = $null;

    $workspaceId = $ExistingConfigSc.settings | Where-Object { $_.name -eq "AppConfig:LoggingConfig:WorkspaceId" }

    if($null -ne $workspaceId) {
        Write-Information "Found workspace ID $workspaceId in the App Service $SCEPmanAppServiceName"
        $workspaceIdSc = $workspaceId.value
    }

    if($null -ne $ExistingConfigCm -and $null -ne $ExistingConfigCm.settings) {
        $workspaceId = $ExistingConfigCm.settings | Where-Object { $_.name -eq "AppConfig:LoggingConfig:WorkspaceId" }

        if($null -ne $workspaceId) {
            Write-Information "Found workspace ID $workspaceId in the App Service $CertMasterAppServiceName"
            $workspaceIdCm = $workspaceId.value
        }
    }

    if($null -ne $workspaceIdCm -and $null -ne $workspaceIdSc -and $workspaceIdSc -ne $workspaceIdCm) {
        throw "Inconsistency: SCEPman($SCEPmanAppServiceName) and CertMaster($CertMasterAppServiceName) have different log analytics workspaces configured"
    }

    # If workspace id is still null; Check if DataCollectionEndpointUri and RuleId are present in the SCEPman app service settings. If they are, fetch the workspace ID from the DCR
    if($null -eq $workspaceIdSc -and $null -eq $workspaceIdCm) {
        $dataCollectionEndpointUri = $ExistingConfigSc.settings | Where-Object { $_.name -eq "AppConfig:LoggingConfig:DataCollectionEndpointUri" }
        $ruleId = $ExistingConfigSc.settings | Where-Object { $_.name -eq "AppConfig:LoggingConfig:RuleId" }

        if($null -ne $dataCollectionEndpointUri -and $null -ne $ruleId -and $dataCollectionEndpointUri.value -and $ruleId.value) {
            $ruleIdName = GetRuleIdName -SubscriptionId $SubscriptionId -ResourceGroup $SCEPmanResourceGroup
            $configuredDCRDetails = Invoke-Az @("monitor", "data-collection", "rule", "show", "--ids", $ruleIdName) | Convert-LinesToObject
            if($null -ne $configuredDCRDetails) {
                [array]$logAnalyticsDestinations = $configuredDCRDetails.destinations.logAnalytics
                if($logAnalyticsDestinations.count -gt 0) {
                    $potentialWorkspaceId = $logAnalyticsDestinations | Where-Object { $_.name -eq "$LogsDestinationName" } | Select-Object -ExpandProperty workspaceId
                    if($null -ne $potentialWorkspaceId) {
                        Write-Information "Fetched workspace ID $potentialWorkspaceId from the Data Collection Rule in the App Service $SCEPmanAppServiceName"
                        $workspaceIdSc = $potentialWorkspaceId
                    }
                }
            }
        }
    }

    if ($null -ne $workspaceIdSc) {
        return $workspaceIdSc
    } elseif ($null -ne $workspaceIdCm) {
        return $workspaceIdCm
    } else {
        return $null
    }
}

function AddLogIngestionAPISettings($ResourceGroup, $AppServiceName, $DcrDetails) {
    $settings = @(
        @{ name='AppConfig:LoggingConfig:DataCollectionEndpointUri'; value=$($DcrDetails.endpoints.logsIngestion) },
        @{ name='AppConfig:LoggingConfig:RuleId'; value=$($DcrDetails.immutableId) }
    )
    SetAppSettings -AppServiceName $AppServiceName -ResourceGroup $ResourceGroup -Settings $settings
    Write-Information "Log ingestion API settings configured in the App Service $AppServiceName"
}

function AddAppRoleAssignmentsForLogIngestionAPI($ResourceGroup, $AppServiceName, $DcrDetails, $SkipAppRoleAssignments = $false) {
    $servicePrincipal = GetServicePrincipal -appServiceNameParam $AppServiceName -resourceGroupParam $ResourceGroup
    if($null -ne $servicePrincipal.principalId) {
        $azCommandToAssignRole = "az role assignment create --role 'Monitoring Metrics Publisher' --assignee-object-id $($servicePrincipal.principalId) --assignee-principal-type ServicePrincipal --scope $($DcrDetails.id)"
        if($SkipAppRoleAssignments) {
            Write-Warning "Skipping app role assignment (please execute manually): $azCommandToAssignRole"
            return
        }
        $null = ExecuteAzCommandRobustly -azCommand $azCommandToAssignRole
        Write-Information "Role 'Monitoring Metrics Publisher' assigned to the App Service $AppServiceName service principal"
    } else {
        Write-Information "$AppServiceName does not have a System-assigned Managed Identity turned on"
    }
}


function Set-LoggingConfigInScAndCmAppSettings {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param (
        [Parameter(Mandatory=$true)]        [string]$SubscriptionId,
        [Parameter(Mandatory=$true)]        [string]$SCEPmanResourceGroup,
        [Parameter(Mandatory=$true)]        [string]$SCEPmanAppServiceName,
        [Parameter(Mandatory=$false)]        [string]$CertMasterResourceGroup,
        [Parameter(Mandatory=$false)]        [string]$CertMasterAppServiceName,
        [Parameter(Mandatory=$false)]        [string]$DeploymentSlotName,
        [Parameter(Mandatory=$false)]        [System.Collections.IList]$DeploymentSlots,
        [switch]$SkipAppRoleAssignments
    )

    $existingConfigSc = ReadAppSettings -ResourceGroup $SCEPmanResourceGroup -AppServiceName $SCEPmanAppServiceName
    $existingConfigCm = $null

    if($CertMasterResourceGroup -and $CertMasterAppServiceName) {
        $existingConfigCm = ReadAppSettings -ResourceGroup $CertMasterResourceGroup -AppServiceName $CertMasterAppServiceName
    }

    $shouldConfigureLoggingInSc = ShouldConfigureLogIngestionAPIInAppService -ExistingConfig $existingConfigSc -ResourceGroup $SCEPmanResourceGroup -AppServiceName $SCEPmanAppServiceName
    $shouldConfigureLoggingConfigInCm = ShouldConfigureLogIngestionAPIInAppService -ExistingConfig $existingConfigCm -ResourceGroup $CertMasterResourceGroup -AppServiceName $CertMasterAppServiceName

    if($shouldConfigureLoggingInSc -or $shouldConfigureLoggingConfigInCm) {
        $existingWorkspaceId = GetExistingWorkspaceId -ExistingConfigSc $existingConfigSc -ExistingConfigCm $existingConfigCm -SCEPmanAppServiceName $SCEPmanAppServiceName -CertMasterAppServiceName $CertMasterAppServiceName -SCEPmanResourceGroup $SCEPmanResourceGroup -SubscriptionId $SubscriptionId
        $workspaceAccount = CreateLogAnalyticsWorkspace -ResourceGroup $SCEPmanResourceGroup -WorkspaceId $existingWorkspaceId
        $dcrDetails = ConfigureLogIngestionAPIResources -ResourceGroup $SCEPmanResourceGroup -WorkspaceAccount $workspaceAccount -SubscriptionId $SubscriptionId

        if($shouldConfigureLoggingInSc) {
            AddAppRoleAssignmentsForLogIngestionAPI -ResourceGroup $SCEPmanResourceGroup -AppServiceName $SCEPmanAppServiceName -DcrDetails $dcrDetails -SkipAppRoleAssignments $SkipAppRoleAssignments
            AddLogIngestionAPISettings -ResourceGroup $SCEPmanResourceGroup -AppServiceName $SCEPmanAppServiceName -DcrDetails $dcrDetails
            RemoveDataCollectorAPISettings -ResourceGroup $SCEPmanResourceGroup -AppServiceName $SCEPmanAppServiceName
        }
        if($shouldConfigureLoggingConfigInCm) {
            AddAppRoleAssignmentsForLogIngestionAPI -ResourceGroup $CertMasterResourceGroup -AppServiceName $CertMasterAppServiceName -DcrDetails $dcrDetails -SkipAppRoleAssignments $SkipAppRoleAssignments
            AddLogIngestionAPISettings -ResourceGroup $CertMasterResourceGroup -AppServiceName $CertMasterAppServiceName -DcrDetails $dcrDetails
            RemoveDataCollectorAPISettings -ResourceGroup $CertMasterResourceGroup -AppServiceName $CertMasterAppServiceName
        }
    }

}