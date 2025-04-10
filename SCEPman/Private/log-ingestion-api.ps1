Function Get-LogAnalyticsWorkspace {
    Param(
        [String]$ResourceGroup
    )

    $Workspace = az monitor log-analytics workspace list --resource-group $ResourceGroup | ConvertFrom-Json

    Return $Workspace
}

Function Get-LAWTable {
    Param(
        [String]$WorkspaceName,
        [String]$ResourceGroup,
        [String]$Name = "SCEPman_CL"
    )

    $Table = az monitor log-analytics workspace table show --workspace-name $WorkspaceName --resource-group $ResourceGroup --name $Name | ConvertFrom-Json

    Return $Table
}
Function Get-DataCollectionRule {
    Param(
        [String]$ResourceGroup,
        [String]$DCRName
    )

    $DCR = az monitor data-collection rule show --resource-group $ResourceGroup --name $DCRName --output json | ConvertFrom-Json

    Return $DCR
}

Function Set-DCRAssociation {
    Param(
        [String]$SubscriptionId,
        [String]$ResourceGroup,
        [String]$DCRName,
        [String]$DCRAssociationName,
        [String]$WorkspaceResourceId
    )

    $RuleId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Insights/dataCollectionRules/$DCRName"
    az monitor data-collection rule association create --name $dcrAssociationName --rule-id $RuleId --resource $WorkspaceResourceId
}

Function New-LogIngestionAPIConnection {
    Param(
        [String]$SCEPmanAppServiceName,
        [String]$DeploymentSlotName,
        [String]$WorkspaceName,
        [Parameter(Mandatory)]
        [String]$ResourceGroup,
        [String]$SubscriptionId,
        [String]$TableName = "SCEPman_CL",
        [String]$NewTableName = "SCEPmanNew_CL",
        [String]$DCRName = "dcr-scepmanlogs",
        [String]$DCRAssociationName = "dcr-association-scepmanlogs"
    )

    $Workspace = Get-LogAnalyticsWorkspace -ResourceGroup $ResourceGroup
    $Table = Get-LAWTable -WorkspaceName $Workspace.Name -ResourceGroup $Workspace.resourceGroup -Name $TableName

    If( $Workspace.Count -gt 1 ) {
        Write-Host "Multiple workspaces found. Please specify the workspace name."
        return
    } elseif ($Workspace.Count -eq 0) {
        Write-Host "No workspaces found. Please create a workspace."
        return
    }

    # Create the new table based on whether the old table exists
    # TODO: Catch output and redirect to not clutter the console
    if ($Table) {
        az monitor log-analytics workspace table create `
        --resource-group $resourceGroup `
        --workspace-name $Workspace.Name `
        --name $newTableName `
        --retention-time $Table.retentionInDays `
        --total-retention-time $Table.totalRetentionInDays `
        --plan $Table.plan `
        --columns `
                TimeGenerated=datetime `
                Timestamp=string `
                Level=string `
                Message=string `
                Exception=string `
                TenantIdentifier=string `
                RequestUrl=string `
                UserAgent=string `
                LogCategory=string `
                EventId=string `
                Hostname=string `
                WebsiteHostname=string `
                WebsiteSiteName=string `
                WebsiteSlotName=string `
                BaseUrl=string `
                TraceIdentifier=string
    } else {
        az monitor log-analytics workspace table create `
        --resource-group $resourceGroup `
        --workspace-name $Workspace.Name `
        --name $newTableName `
        --columns `
                TimeGenerated=datetime `
                Timestamp=string `
                Level=string `
                Message=string `
                Exception=string `
                TenantIdentifier=string `
                RequestUrl=string `
                UserAgent=string `
                LogCategory=string `
                EventId=string `
                Hostname=string `
                WebsiteHostname=string `
                WebsiteSiteName=string `
                WebsiteSlotName=string `
                BaseUrl=string `
                TraceIdentifier=string
    }

    $StreamDeclarations =  @{
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

    # Define the destinations JSON in a variable
    $Destinations = @{
        "logAnalytics" = @(
            @{
                "workspaceResourceId" = $Workspace.Id;
                "name" = "SCEPmanLogAnalyticsDestination"
            }
        )
    }

    $DataFlows = @(
        @{
            "streams" = @("Custom-SCEPmanLogs");
            "destinations" = @("SCEPmanLogAnalyticsDestination");
            "outputStream" = "Custom-$NewTableName"
        }
    )

    $destinationsJson = HashTable2AzJson -psHashTable $Destinations
    $streamDeclarationsJson = HashTable2AzJson -psHashTable $streamDeclarations
    $dataFlowsJson = HashTable2AzJson -psHashTable $DataFlows

    #Add required extension
    az extension add --name monitor-control-service

    # Create DCR
    # Kind should be set to Direct to create ingestion endpoints https://github.com/Azure/azure-powershell/issues/25727#issuecomment-2265860351
    $DcrJson = az monitor data-collection rule create --resource-group $ResourceGroup --name $dcrName --location $WorkSpace.location --description "Data Collection Rule for SCEPman logs" --stream-declarations $streamDeclarationsJson --destinations $destinationsJson --data-flows $dataFlowsJson --kind "Direct"
    $DcrProperties = $DcrJson | ConvertFrom-Json

    # Associate the DCR with the Log Analytics table
    # TODO: Check for issues if we rerun this dcr creation
    az monitor data-collection rule association create --name $DCRAssociationName --rule-id $DcrProperties.Id --resource $Workspace.Id

    $ScepManAppSettings = @(
        @{ name='AppConfig:LoggingConfig:DataCollectionEndpointUri'; value=$DcrProperties.endpoints.logsIngestion },
        @{ name='AppConfig:LoggingConfig:RuleId '; value=$DcrProperties.Id }
    )

    SetAppSettings -AppServiceName $SCEPmanAppServiceName -ResourceGroup $ResourceGroup -Settings $ScepManAppSettings -Slot $DeploymentSlotName
}