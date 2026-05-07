function GetLogAnalyticsWorkspace ($ResourceGroup, $WorkspaceId) {
    # Try to find by workspace id
    if($null -ne $WorkspaceId) {
        $workspaces = Invoke-Az @("graph", "query", "-q", "Resources | where type == 'microsoft.operationalinsights/workspaces' and properties.customerId == '$WorkspaceId' | project name, workspaceId = properties.customerId, location, resourceGroup") | Convert-LinesToObject
    }

    # Try to find by resource group
    if($null -eq $workspaces -or $workspaces.count -eq 0) {
        $workspaces = Invoke-Az @("graph", "query", "-q", "Resources | where type == 'microsoft.operationalinsights/workspaces' and resourceGroup == '$ResourceGroup' | project name, workspaceId = properties.customerId, location, resourceGroup") | Convert-LinesToObject
    }

    if($workspaces.count -eq 1) {
        Write-Information "Found log analytics workspace $($workspaces.data[0].name)"
        return $workspaces.data[0]
    } elseif($workspaces.count -gt 1) {
        Write-Information "Found log analytics workspaces:"
        $workspaces.data | ForEach-Object { Write-Information $_.name }
        $potentialWorkspaceName = Read-Host "We have found more than one existing log analytics workspace in the resource group $ResourceGroup. Please enter the name of the workspace you want to use"

        $potentialWorkspace = $workspaces.data | Where-Object { $_.name -eq $potentialWorkspaceName }
        if($null -eq $potentialWorkspace) {
            Write-Error "We couldn't find a log analytics workspace with name $potentialWorkspaceName in resource group $ResourceGroup. Please try to re-run the script"
            throw "We couldn't find a log analytics workspace with name $potentialWorkspaceName in resource group $ResourceGroup. Please try to re-run the script"
        } else {
            return $potentialWorkspace
        }
    }
    else {
        Write-Warning "Unable to determine the log analytics workspace"
        return $null
    }
}

function GetDataCollectionRule {
    param(
        [Parameter(Mandatory, ParameterSetName = "ByResourceGroup")]
        [string]$ResourceGroup,
        [Parameter(Mandatory, ParameterSetName = "ByDcrId")]
        [string]$DcrId
    )

    if($PSCmdlet.ParameterSetName -eq 'ByDcrId') {
        Write-Verbose "Looking for data collection rule with id $DcrId"
        $dataCollectionRule = Invoke-Az @("graph", "query", "-q", "Resources | where type == 'microsoft.insights/datacollectionrules' and properties.immutableId == '$DcrId' | project id, name, location, resourceGroup, endpoints = properties.endpoints, immutableId = properties.immutableId") | Convert-LinesToObject
    }

    if($PSCmdlet.ParameterSetName -eq 'ByResourceGroup') {
        Write-Verbose "Looking for data collection rules in the resource group $ResourceGroup"
        $dataCollectionRule = Invoke-Az @("graph", "query", "-q", "Resources | where type == 'microsoft.insights/datacollectionrules' and resourceGroup == '$ResourceGroup' | project id, name, location, resourceGroup, endpoints = properties.endpoints, immutableId = properties.immutableId") | Convert-LinesToObject

        if($dataCollectionRule.count -gt 1) {
            Write-Information "Found data collection rules:"
            $dataCollectionRule.data | ForEach-Object { Write-Information $_.name }
            $potentialDcrName = Read-Host "We have found more than one existing data collection rule in the resource group $ResourceGroup. Please enter the data collection rule you would like to use"

            # Check if the selected DCR is in our results
            $potentialDcr = $dataCollectionRule.data | Where-Object { $_.name -eq $potentialDcrName }
            if($null -eq $potentialDcr) {
                Write-Error "We couldn't find a data collection rule with name $potentialDcrName in resource group $ResourceGroup. Please try to re-run the script"
                throw "We couldn't find a data collection rule with name $potentialDcrName in resource group $ResourceGroup. Please try to re-run the script"
            } else {
                return $potentialDcr
            }
        }
    }

    if($dataCollectionRule.count -eq 1) {
        Write-Information "Found data collection rule $($dataCollectionRule.data[0].name)"
        return $dataCollectionRule.data[0]
    } else {
        Write-Warning "Unable to determine the data collection rule"
        return $null
    }
}

function GetLogAnalyticsTable($ResourceGroup, $WorkspaceAccount, $SubscriptionId, $tableName) {
    $table = Invoke-Az -MaxRetries 0 -azCommand @("monitor", "log-analytics", "workspace", "table", "show", "--resource-group", $ResourceGroup, "--workspace-name", $($WorkspaceAccount.name), "--name", $tableName) | Convert-LinesToObject
    return $table
}

function ValidateLogAnalyticsTable($ResourceGroup, $WorkspaceAccount, $SubscriptionId) {
    $LogsTableColumnDefinitions = @(
        @{ name="TimeGenerated"; type="datetime" },
        @{ name="Timestamp"; type="string" },
        @{ name="Level"; type="string" },
        @{ name="Message"; type="string" },
        @{ name="Exception"; type="string" },
        @{ name="TenantIdentifier"; type="string" },
        @{ name="RequestUrl"; type="string" },
        @{ name="UserAgent"; type="string" },
        @{ name="LogCategory"; type="string" },
        @{ name="EventId"; type="string" },
        @{ name="Hostname"; type="string" },
        @{ name="WebsiteHostname"; type="string" },
        @{ name="WebsiteSiteName"; type="string" },
        @{ name="WebsiteSlotName"; type="string" },
        @{ name="BaseUrl"; type="string" },
        @{ name="TraceIdentifier"; type="string" }
    )
    # Generate column definition strings for the az command
    $LogsTableColumns = $LogsTableColumnDefinitions | ForEach-Object { "$($_.name)=$($_.type)" }

    # Try to find table
    $tableDetails = GetLogAnalyticsTable -ResourceGroup $ResourceGroup -WorkspaceAccount $WorkspaceAccount -SubscriptionId $SubscriptionId -tableName $LogsTableName
    if ($null -eq $tableDetails) {
        Write-Verbose "Table $LogsTableName does not exist in the workspace $($WorkspaceAccount.name). Creating it now."

        $azCommandToCreateWorkspaceTable = @("monitor", "log-analytics", "workspace", "table", "create", "--resource-group", $ResourceGroup, "--workspace-name", $($WorkspaceAccount.name), "--name", $LogsTableName)
        # We add the columns separately as they would end up as a single string in the command otherwise which would fail
        $azCommandToCreateWorkspaceTable += "--columns"
        $azCommandToCreateWorkspaceTable += $LogsTableColumns
        $null = Invoke-Az $azCommandToCreateWorkspaceTable

        Write-Information "Table $LogsTableName successfully created in the workspace $($WorkspaceAccount.name)"
    } else {
        # We have a table already, check if it is of the correct type
        if ($tableDetails.schema.tableSubType -ne 'DataCollectionRuleBased') {
            Write-Information "Table $LogsTableName exists but is not of type DataCollectionRuleBased. Found subType: $($tableDetails.schema.tableSubType)"
            Write-Information "Migrating to DataCollectionRuleBased table."

            $azCommandToMigrateWorkspaceTable = @("monitor", "log-analytics", "workspace", "table", "migrate", "--resource-group", $ResourceGroup, "--workspace-name", $($WorkspaceAccount.name), "--table-name", $LogsTableName)
            $null = Invoke-Az $azCommandToMigrateWorkspaceTable
        } else {
            Write-Verbose "Table $LogsTableName already exists in the workspace $($WorkspaceAccount.name) with the correct subtype"
        }

        # We have a table of the correct type, check if all columns are present
        $existingColumnNames = ($tableDetails.schema.columns | ForEach-Object { $_.name }) + ($tableDetails.schema.standardColumns | ForEach-Object { $_.name })
        $missingColumns = @()
        foreach ($columnDefinition in $LogsTableColumnDefinitions) {
            if (-not ($existingColumnNames -contains $columnDefinition.name)) {
                $missingColumns += $columnDefinition
            }
        }

        if ($missingColumns.Count -gt 0) {
            Write-Verbose "Could not find $($missingColumns.Count) columns in table $LogsTableName"
            Write-Verbose "Missing columns: $($missingColumns | ForEach-Object { $_.name } | Join-String -Separator ', ')"
            Write-Information "Updating table schema."
            $azCommandToUpdateWorkspaceTableSchema = @("monitor", "log-analytics", "workspace", "table", "update", "--resource-group", $ResourceGroup, "--workspace-name", $($WorkspaceAccount.name), "--name", $LogsTableName)
            # We add the columns separately as they would end up as a single string in the command otherwise which would fail
            $azCommandToUpdateWorkspaceTableSchema += "--columns"
            $azCommandToUpdateWorkspaceTableSchema += $LogsTableColumns
            $null = Invoke-Az $azCommandToUpdateWorkspaceTableSchema
        }
    }
}

function ValidateDCR($ResourceGroup, $WorkspaceAccount, $WorkspaceResourceId) {
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
            "outputStream" = "Custom-$LogsTableName"
        }
    )

    $destinationsJson = HashTable2AzJson -psHashTable $destinations
    $streamDeclarationsJson = HashTable2AzJson -psHashTable $streamDeclarations
    $dataFlowsJson = HashTable2AzJson -psHashTable $dataFlows

    $existingDcrDetails = Invoke-Az -MaxRetries 0 -azCommand @("monitor", "data-collection", "rule", "show", "--resource-group", $ResourceGroup, "--name", $DCRName) | Convert-LinesToObject

    # Check if we need to create the DCR
    if($null -eq $existingDcrDetails) {
        Write-Verbose "Data Collection Rule $DCRName does not exist in the resource group $ResourceGroup. Creating it now."

        # Create DCR
        $newDcrDetails = Invoke-Az @("monitor", "data-collection", "rule", "create", "--resource-group", $ResourceGroup, "--name", $DCRName, "--description", "Data Collection Rule for SCEPman logs", "--stream-declarations", $streamDeclarationsJson, "--destinations", $destinationsJson, "--data-flows", $dataFlowsJson, "--kind", "Direct", "--location", $($WorkspaceAccount.location), "--only-show-errors") | Convert-LinesToObject
        Write-Information "Data Collection Rule $DCRName successfully created"
        return $newDcrDetails
    }

    # Verify existing DCR configuration
    $DCRNeedsUpdate = $false

    # Verify destinations
    if($existingDcrDetails.destinations.logAnalytics.count -eq 0 -or $existingDcrDetails.destinations.logAnalytics[0].name -ne $LogsDestinationName -or $existingDcrDetails.destinations.logAnalytics[0].workspaceResourceId -ne $WorkspaceResourceId) {
        Write-Information "Data Collection Rule $DCRName exists but does not have the correct Log Analytics destination configured. Updating it now."
        $DCRNeedsUpdate = $true
    }

    # Verify streamDeclaration
    if($null -eq $existingDcrDetails.streamDeclarations.'Custom-SCEPmanLogs') {
        Write-Information "Data Collection Rule $DCRName exists but does not have the correct stream declarations configured. Updating it now."
        $DCRNeedsUpdate = $true
    }

    # Verify streamDeclarations columns
    if($null -ne $existingDcrDetails.streamDeclarations.'Custom-SCEPmanLogs') {
        $missingColumns = 0
        $streamDeclarations.'Custom-SCEPmanLogs'.columns | ForEach-Object {
            $columnName = $_.name
            $existingColumn = $existingDcrDetails.streamDeclarations.'Custom-SCEPmanLogs'.columns | Where-Object { $_.name -eq $columnName }
            if($null -eq $existingColumn) {
                $missingColumns++
            }
        }

        if($missingColumns -gt 0) {
            Write-Verbose "Data Collection Rule $DCRName is missing $missingColumns columns in the stream declaration Custom-SCEPmanLogs. Updating it now."
            $DCRNeedsUpdate = $true
        }
    }

    # Verify dataFlows
    if($existingDcrDetails.dataFlows.count -eq 0 -or $existingDcrDetails.dataFlows[0].outputStream -ne $dataFlows[0].outputStream) {
        Write-Verbose "Data Collection Rule $DCRName exists but does not have the correct data flows configured. Updating it now."
        $DCRNeedsUpdate = $true
    }

    if($existingDcrDetails.dataFlows[0].streams -ne $dataFlows[0].streams) {
        Write-Verbose "Data Collection Rule $DCRName exists but does not have the correct data flows streams configured. Updating it now."
        $DCRNeedsUpdate = $true
    }

    if($DCRNeedsUpdate) {
        # Update DCR
        $updatedDcrDetails = Invoke-Az @("monitor", "data-collection", "rule", "update", "--resource-group", $ResourceGroup, "--name", $DCRName, "--description", "Data Collection Rule for SCEPman logs", "--stream-declarations", $streamDeclarationsJson, "--destinations", $destinationsJson, "--data-flows-raw", $dataFlowsJson, "--kind", "Direct", "--only-show-errors") | Convert-LinesToObject
        Write-Information "Data Collection Rule $DCRName successfully updated"
        return $updatedDcrDetails
    } else {
        Write-Information "Data Collection Rule $DCRName already exists with the correct configuration. Skipping the creation/update of the DCR"
        return $existingDcrDetails
    }
}


function GetRuleIdName($SubscriptionId, $ResourceGroup) {
    $ruleIdName = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Insights/dataCollectionRules/$DCRName"
    return $ruleIdName
}

function ConfigureLogIngestionAPIResources() {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param (
        [Parameter(Mandatory=$true)]        [PSCustomObject]$WorkspaceAccount,
        [Parameter(Mandatory=$true)]        [string]$SubscriptionId
    )
    Write-Information "Installing az monitor control service extension"
    Invoke-Az @("extension", "add", "--name", "monitor-control-service", "--only-show-errors")

    # Create the new table
    if ($PSCmdlet.ShouldProcess("$WorkspaceAccount", "Validating log analytics workspace table and creating if it does not exist")) {
        ValidateLogAnalyticsTable -ResourceGroup $WorkspaceAccount.resourceGroup -WorkspaceAccount $WorkspaceAccount -SubscriptionId $SubscriptionId
    }

     # Create the DCR
    $workspaceResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$($WorkspaceAccount.resourceGroup)/providers/microsoft.operationalinsights/workspaces/$($WorkspaceAccount.name)"
    if ($PSCmdlet.ShouldProcess("$WorkspaceAccount", "Validating Data Collection Rule and creating/updating if it does not exist or is misconfigured")) {
         $dcrDetails = ValidateDCR -ResourceGroup $WorkspaceAccount.resourceGroup -WorkspaceAccount $WorkspaceAccount -WorkspaceResourceId $workspaceResourceId
    }

    return $dcrDetails
}

function AddAppRoleAssignmentsForLogIngestionAPI($DcrResourceId, $ServicePrincipal, $SkipAppRoleAssignments = $false) {
    $azCommandToAssignRole = "az role assignment create --role 'Monitoring Metrics Publisher' --assignee-object-id $($ServicePrincipal) --assignee-principal-type ServicePrincipal --scope $DcrResourceId"
    if($SkipAppRoleAssignments) {
        Write-Warning "Skipping app role assignment (please execute manually): $azCommandToAssignRole"
        return
    }
    $null = ExecuteAzCommandRobustly -azCommand $azCommandToAssignRole
    Write-Verbose "Role 'Monitoring Metrics Publisher' assigned to service principal $ServicePrincipal for the scope of the Data Collection Rule with resource id $DcrResourceId"
}


function Set-LoggingConfigInAppSettings {
    [CmdletBinding(SupportsShouldProcess=$true)]
    # No settings are passed but a group of defined settings is applied/removed, so plural noun is appropriate here
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseSingularNouns", "")]
    param (
        [Parameter(Mandatory=$true)]        [string]$SubscriptionId,
        [Parameter(Mandatory=$true)]        [string]$ResourceGroup,
        [Parameter(Mandatory=$true)]        [string]$AppServiceName,
        [Parameter(Mandatory=$false)]        [System.Collections.IList]$servicePrincipals,
        [Parameter(Mandatory=$false)]        [string]$DeploymentSlotName,
        [Parameter(Mandatory=$false)]        [System.Collections.IList]$DeploymentSlots,
        [switch]$SkipAppRoleAssignments
    )
    # Check if we have an existing logging configuration
    $existingWorkspaceId = ReadAppSetting -ResourceGroup $ResourceGroup -AppServiceName $AppServiceName -SettingName "AppConfig:LoggingConfig:WorkspaceId" -Slot $DeploymentSlotName
    $existingDcrRuleId = ReadAppSetting -ResourceGroup $ResourceGroup -AppServiceName $AppServiceName -SettingName "AppConfig:LoggingConfig:RuleId" -Slot $DeploymentSlotName

    # Decide whether we create a DCR or not based on existing logging configuration
    if (-not [string]::IsNullOrEmpty($existingWorkspaceId) -and [string]::IsNullOrEmpty($existingDcrRuleId)) {
        Write-Information "Missing Log Ingestion API configuration detected while using existing log analytics workspace. Proceeding to configure Log Ingestion API resources."
        # Get LAW resource details
        $workspaceAccount = GetLogAnalyticsWorkspace -ResourceGroup $ResourceGroup -WorkspaceId $existingWorkspaceId

        if ($null -eq $workspaceAccount) {
            Write-Warning "Could not find the log analytics workspace with id $existingWorkspaceId. Please check if the workspace still exists or if the app setting is configured correctly. Skipping Log Ingestion API configuration."
            return
        }

        # Validate the log table and create or validate the DCR in the workspace resource group
        $dcrDetails = ConfigureLogIngestionAPIResources -WorkspaceAccount $workspaceAccount -SubscriptionId $SubscriptionId
    } elseif (-not [string]::IsNullOrEmpty($existingDcrRuleId)) {
        Write-Information "Existing Log Ingestion API configuration detected. Validate permissions"
        # Get DCR details
        $dcrDetails = GetDataCollectionRule -DcrId $existingDcrRuleId

        if ($null -eq $dcrDetails) {
            Write-Warning "Unable to find existing Data Collection Rule with id $existingDcrRuleId"
            return
        }
    } else {
        Write-Information "Neither existing log analytics workspace nor existing Log Ingestion API configuration detected. Check if we have a log analytics workspace in the resource group."

        # Try to find LAW in our resource group
        $workspaceAccount = GetLogAnalyticsWorkspace -ResourceGroup $ResourceGroup

        if ($null -eq $workspaceAccount) {
            Write-Information "No existing log analytics workspace found. Skipping logging configuration."
            return
        }

        # Validate the log table and create or validate the DCR in the workspace resource group
        $dcrDetails = ConfigureLogIngestionAPIResources -WorkspaceAccount $workspaceAccount -SubscriptionId $SubscriptionId
    }

    $SettingsToRemove = @("AppConfig:LoggingConfig:WorkspaceId", "AppConfig:LoggingConfig:SharedKey")
    $SettingsToAdd = @(
        @{ name='AppConfig:LoggingConfig:DataCollectionEndpointUri'; value=$($DcrDetails.endpoints.logsIngestion) },
        @{ name='AppConfig:LoggingConfig:RuleId'; value=$($DcrDetails.immutableId) }
    )

    if([String]::IsNullOrEmpty($DeploymentSlotName)) {
        # In case we do not have a deployment slot, we just update the app settings of the app service
        # If we got a deployment slot, it will be handled in the slots loop below
        Write-Information "Configuring Log Ingestion API settings in App Service $AppServiceName"
        if ($PSCmdlet.ShouldProcess($AppServiceName, "Setting Log Ingestion API app settings in the App Service")) {
            RemoveAppSettings -AppServiceName $AppServiceName -ResourceGroup $ResourceGroup -SettingNames $SettingsToRemove
            SetAppSettings -AppServiceName $AppServiceName -ResourceGroup $ResourceGroup -Settings $SettingsToAdd
        }
    }

    ForEach($tempDeploymentSlot in $DeploymentSlots) {
        Write-Information "Configuring Log Ingestion API settings in App Service $AppServiceName in slot $tempDeploymentSlot"
        if ($PSCmdlet.ShouldProcess("$AppServiceName/$tempDeploymentSlot", "Setting Log Ingestion API app settings in the App Service Slot")) {
            RemoveAppSettings -AppServiceName $AppServiceName -ResourceGroup $ResourceGroup -SettingNames $SettingsToRemove -Slot $tempDeploymentSlot
            SetAppSettings -AppServiceName $AppServiceName -ResourceGroup $ResourceGroup -Settings $SettingsToAdd -Slot $tempDeploymentSlot
        }
    }

    # If we receive principals, we also assign the correct RBAC roles
    # This will only happen during the SCEPman call which will then also include the principal of CM
    if($servicePrincipals) {
        Foreach($principal in $servicePrincipals) {
            if ($PSCmdlet.ShouldProcess($principal, "Adding app role assignment for Monitoring Metrics Publisher role")) {
                AddAppRoleAssignmentsForLogIngestionAPI -DcrResourceId $dcrDetails.id -ServicePrincipal $principal -SkipAppRoleAssignments $SkipAppRoleAssignments
            }
        }
    }
}