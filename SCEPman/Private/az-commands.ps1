$MAX_RETRY_COUNT = 4  # for some operations, retry a couple of times
$SNAILMODE_MAX_RETRY_COUNT = 10 # For very slow tenants, retry more often

$script:Snail_Mode = $false
$Sleep_Factor = 1
$Snail_Maximum_Sleep_Factor = 90 # times ten is 15 minutes

function Convert-LinesToObject {
    param (
        [Parameter(ValueFromPipeline = $true)]
        [string[]]
        $Lines
    )

    BEGIN {
        $linesJsonBuilder = new-object System.Text.StringBuilder
    }

    PROCESS {
        if ($null -eq $Lines) {
            return
        }
        $null = $linesJsonBuilder.Append([string]::Concat($Lines))
    }

    END {
        if ($null -eq $Lines) {
            return
        }

        return ConvertFrom-Json $linesJsonBuilder.ToString()
    }
}

$PERMISSION_ALREADY_ASSIGNED = "Permission already assigned"
$PERMISSION_DOES_NOT_EXIST = "Permission does not exist"

function CheckAzOutput($azOutput, $fThrowOnError, $noSecretLeakageWarning = $false) {
    [String[]]$errorMessages = @()
    foreach ($outputElement in $azOutput) {
        if ($null -ne $outputElement) {
            if ($outputElement.GetType() -eq [System.Management.Automation.ErrorRecord]) {
                if ($outputElement.ToString().Contains("Permission being assigned already exists on the object") -or $outputElement.ToString().Contains("RoleAssignmentExists")) {
                    Write-Information "Permission is already assigned when executing $azCommand"
                    Write-Output $PERMISSION_ALREADY_ASSIGNED
                }
                elseif ($outputElement.ToString().Contains("Permission being assigned was not found on")) {
                    Write-Information "Could not assign permission, as it does not exist for this application, when executing $azCommand"
                    Write-Output $PERMISSION_DOES_NOT_EXIST
                }
                elseif ($outputElement.ToString().EndsWith("does not exist or one of its queried reference-property objects are not present.")) {
                    # This indicates we are in a tenant with especially long delays between creation of an object and when it becomes available via Graph (this happens and it seems to be tenant-specific).
                    # Let's go into snail mode and thereby grant Graph more time
                    Write-Warning "Created object is not yet available via MS Graph. Reducing executing speed to give Graph more time."
                    $script:Snail_Mode = $true
                    $Sleep_Factor = 0.8 * $Sleep_Factor + 0.2 * $Snail_Maximum_Sleep_Factor # approximate longer sleep times
                    Write-Verbose "Retrying operations now $SNAILMODE_MAX_RETRY_COUNT times, and waiting for (n * $Sleep_Factor) seconds on n-th retry"
                }
                elseif ($outputElement.ToString().Contains("Blowfish") -or $outputElement.ToString().Contains('cryptography on a 32-bit Python')) {
                    # Ignore, this is an issue of az 2.45.0 and az 2.45.0-preview
                    Write-Debug "Ignoring expected warning about Blowfish: $outputElement"
                }
                elseif ($outputElement.ToString().EndsWith('MGMT_DEPLOYMENTMANAGER') -and $outputElement.ToString().StartsWith('ERROR')) {
                    Write-Warning "Ignoring error message from az account show: $outputElement"
                }
                elseif ($outputElement.ToString().Contains("CryptographyDeprecationWarning")) {
                    # Ignore, this is an issue of az 2.64.0-preview
                    Write-Debug "Ignoring expected warning about algorithm deprecation: $outputElement"
                    $expectAlgorithmToBeIgnored = $true
                }
                elseif ($expectAlgorithmToBeIgnored -and ($outputElement.ToString().Trim(' ').StartsWith('"class": algorithms') -or $outputElement.ToString().Trim(' ').StartsWith('"cipher": algorithms'))) {
                    # Ignore, this is the next line of the previous issue
                    Write-Debug "Ignoring algorithm line for crypto warning: $outputElement"
                    $expectAlgorithmToBeIgnored = $false
                }
                elseif ($expectPackageWarning -and $outputElement.ToString().Contains('pkg_resources')) {
                    # Ignore, this is the next line of the previous issue
                    Write-Debug "Ignoring package warning line: $outputElement"
                    $expectPackageWarning = $false
                }
                elseif ($outputElement.ToString().Contains("SyntaxWarning: invalid escape sequence '\ '")) {
                    # Ignore, this is a harmless issue of az graph extension 2.10 with more recent python versions (?)
                    # See https://github.com/Azure/azure-cli-extensions/issues/8369
                    Write-Debug "Ignoring expected warning about wrong escape seqences: $outputElement"
                    $expectIntervalWarning = $true
                }
                elseif ($expectIntervalWarning -and ($outputElement.ToString().Trim(' ').StartsWith('"""'))) {
                    # Ignore, this is the next line of the previous issue
                    Write-Debug "Ignoring line for syntax warning: $outputElement"
                    $expectIntervalWarning = $false
                }
                elseif ($outputElement.ToString().StartsWith("WARNING") -or $outputElement.ToString().Contains("UserWarning: ")) {
                    if ($outputElement.ToString().StartsWith("WARNING: The underlying Active Directory Graph API will be replaced by Microsoft Graph API") `
                            -or $outputElement.ToString().StartsWith("WARNING: This command or command group has been migrated to Microsoft Graph API.")) {
                        # Ignore, we know that
                        Write-Debug "Ignoring expected warning about Graph API migration: $outputElement"
                    }
                    elseif ($outputElement.ToString().StartsWith("WARNING: App settings have been redacted.")) {
                        # Ignore, this is a new behavior of az 2.53.1 and affects the output of az webapp settings set, which we do not use anyway.
                        Write-Debug "Ignoring expected warning about redacted app settings: $outputElement"
                    }
                    elseif ($noSecretLeakageWarning -and $outputElement.ToString().StartsWith("WARNING: [Warning] This output may compromise security by showing")) {
                        Write-Debug "Ignoring expected warning about secret leakage: $outputElement"
                    }
                    elseif ($outputElement.ToString().Contains("pkg_resources is deprecated as an API.")) {
                        # Ignore, see https://developercommunity.visualstudio.com/t/Azure-DevOps-Extension-reports-pkg_resou/10919558
                        Write-Debug "Ignoring expected warning about a deprecated package because of some extension: $outputElement"
                        $expectPackageWarning = $true
                    }
                    else {
                        Write-Debug "Warning about unexpected az output"
                        Write-Warning $outputElement.ToString()
                    }
                }
                else {
                    if ($outputElement.ToString().contains("does not have authorization to perform action 'Microsoft.Authorization/roleAssignments/write'")) {
                        $errorMessages += "You have insufficient privileges to assign roles to Managed Identities. Make sure you have the Global Admin or Privileged Role Administrator role."
                    }
                    elseif ($outputElement.ToString().Contains("Forbidden")) {
                        $errorMessages += "You have insufficient privileges to complete the operation. Please ensure that you run this CMDlet with required privileges e.g. Global Administrator"
                    }

                    Write-Debug "Error about unexpected az output: $outputElement"
                    $errorMessages += $outputElement
                }
            }
            else {
                Write-Output $outputElement # add to return value of this function
            }
        }
    }
    if ($errorMessages.Count -gt 0) {
        $ErrorMessageOneLiner = [String]::Join("`r`n", $errorMessages)
        if ($fThrowOnError) {
            throw $ErrorMessageOneLiner
        }
        else {
            Write-Error $ErrorMessageOneLiner
        }
    }
}

function AzLogin {
    # Check whether az is available
    $azCommand = Get-Command az 2>&1
    if ($azCommand.GetType() -eq [System.Management.Automation.ErrorRecord]) {
        if ($azCommand.CategoryInfo.Reason -eq "CommandNotFoundException") {
            $errorMessage = "Azure CLI (az) is not installed, but required. Please use the Azure Cloud Shell or install Azure CLI as described here: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
            Write-Error $errorMessage
            throw $errorMessage
        }
        else {
            Write-Error "Unknown error checking for az"
            throw $azCommand
        }
    }

    # check whether already logged in
    $env:AZURE_HTTP_USER_AGENT = "pid-a262352f-52a9-4ed9-a9ba-6a2b2478d19b"
    try {
        $account = Invoke-Az -azCommand @("account", "show") -MaxRetries 0
    }
    catch {
        $errorMessage = $_.Exception.Message
        if (($errorMessage.Contains("az login")) -or ($errorMessage.Contains("az account set"))) {
            Write-Warning "Not logged in with az yet. Trying to log in ... if this doesn't work, please log in manually."
            $null = az login # TODO: Check whether the login worked
            return AzLogin
        }
        else {
            Write-Error "Error $errorMessage while trying to use az" # possibly az not installed?
            throw new-object System.Exception("Error when checking whether az is logged in", $_.Exception)
        }
    }
    try {
        $accountInfo = Convert-LinesToObject($account)
    }
    catch {
        $errormessage = "Error parsing output from az account show. Error message: $_"
        $errorMessage += "`r`Output from az account show: $account"
        Write-Error $errormessage
        throw $errorMessage
    }
    Write-Information "Logged in to az as $($accountInfo.user.name)"

    return $accountInfo
}

$azVersionInfo = $null

function GetAzVersion {
    if ($null -eq $azVersionInfo) {
        $azVersionInfo = Convert-LinesToObject -lines $(az version)
    }
    return $azVersionInfo
}

function AzUsesAADGraph {
    $cliVersion = [Version]::Parse((GetAzVersion).'azure-cli')
    return $cliVersion -lt '2.37'
}

# Check heuristically whether we are in Azure Cloud Shell
function IsAzureCloudShell {
    $cloudShellProves = 0   # The more proves, the more likely we are in Azure Cloud Shell. We use a 2 out of 3 vote.
    $azuredrive = get-psdrive -Name Azure -ErrorAction Ignore
    if ($null -ne $azuredrive) {
        ++$cloudShellProves
    }

    if (Test-Path -Path ~/clouddrive) {
        ++$cloudShellProves
    }

    if ($PSVersionTable.Platform -eq "Unix") {
        ++$cloudShellProves
    }

    return $cloudShellProves -ge 2
}

function Invoke-Az ($azCommand, $maxRetries = $MAX_RETRY_COUNT) {
    return ExecuteAzCommandRobustly -azCommand $azCommand -callAzNatively -maxRetries $maxRetries
}

# It is intended to use for az cli add permissions and az cli add permissions admin
# $azCommand - The command to execute.
# $noSecretLeakageWarning - Pass true if you are sure that the output contains no secrets. This will supress az warnings about leaking secrets in the output.
function ExecuteAzCommandRobustly($azCommand, $principalId = $null, $appRoleId = $null, $GraphBaseUri = $null, $maxRetries = $MAX_RETRY_COUNT, [switch]$callAzNatively, [switch]$noSecretLeakageWarning) {
    $azErrorCode = 1234 # A number not null
    $retryCount = 0
    $script:Snail_Mode = $false

    try {
        $definedPreference = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false   # See https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_preference_variables?view=powershell-7.3#psnativecommanduseerroractionpreference

        while ($azErrorCode -gt 0 -and ($retryCount -le $maxRetries -or $script:Snail_Mode -and $retryCount -le $SNAILMODE_MAX_RETRY_COUNT)) {
            $PreviousErrorActionPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"     # In Windows PowerShell, if this is set to "Stop", az will not return the error code, but instead throw an exception
            $LASTEXITCODE = 0   # Required for unit tests when mocking az
            if ($callAzNatively) {
                Write-Debug "Calling az natively: az $azCommand"
                $lastAzOutput = az $azCommand 2>&1
            }
            else {
                $lastAzOutput = Invoke-Expression "$azCommand 2>&1" # the output is often empty in case of error :-(. az just writes to the console then
            }
            $azErrorCode = $LASTEXITCODE
            $ErrorActionPreference = $PreviousErrorActionPreference
            Write-Debug "az command $azCommand returned with error code $azErrorCode"
            try {
                $lastAzOutput = CheckAzOutput -azOutput $lastAzOutput -fThrowOnError $true -noSecretLeakageWarning $noSecretLeakageWarning
                # If we were requested to check that the permission is there and there was no error, do the check now.
                # However, if the permission has been there previously already, we can skip the check
                if ($null -ne $appRoleId -and $azErrorCode -eq 0 -and $PERMISSION_ALREADY_ASSIGNED -ne $lastAzOutput) {
                    $appRoleAssignments = Convert-LinesToObject -lines $(az rest --method get --url "$GraphBaseUri/v1.0/servicePrincipals/$principalId/appRoleAssignments")
                    $grantedPermission = $appRoleAssignments.value | Where-Object { $_.appRoleId -eq $appRoleId }
                    if ($null -eq $grantedPermission) {
                        $azErrorCode = 999 # A number not 0
                    }
                }
                elseif ($null -ne $appRoleId -and $PERMISSION_ALREADY_ASSIGNED -eq $lastAzOutput) {
                    $azErrorCode = 0  # The permission was already there, so we are done. Ignore the error message that the permission was already there.
                }
                elseif ($null -ne $appRoleId -and $PERMISSION_DOES_NOT_EXIST -eq $lastAzOutput) {
                    $azErrorCode = -24  # This kind of permission doesn't even exist. We are probably not in the global cloud or something else is unusual. No need to retry.
                }
            }
            catch {
                Write-Warning $_
                $azErrorCode = 654  # a number not 0

                $message = $_.ToString()
                if ($message.Contains("Failed to connect to MSI. Please make sure MSI is configured correctly") -and $message.Contains("400")) {
                    if (IsAzureCloudShell) {
                        Write-Warning "Trying to log in again to Azure CLI, as this usually fixes the token issue in Azure Cloud Shell"
                        az login
                    }
                }
            }
            if ($azErrorCode -gt 0) {
                ++$retryCount
                Write-Verbose "Retry $retryCount for $azCommand after $($retryCount * $SLEEP_FACTOR) seconds of sleep because Error Code is $azErrorCode"
                Start-Sleep ($retryCount * $SLEEP_FACTOR) # Sleep for some seconds, as the grant sometimes only works after some time
            }
        }
    }
    finally {
        $PSNativeCommandUseErrorActionPreference = $definedPreference
    }

    if ($azErrorCode -ne 0 ) {
        if ($null -eq $lastAzOutput) {
            $errorMessage = "no error message"
            $readableAzOutput = "no az output"
        }
        else {
            # might be an object[]
            $readableAzOutput = CheckAzOutput -azOutput $lastAzOutput -fThrowOnError $false
            try {
                $null = CheckAzOutput -azOutput $lastAzOutput -fThrowOnError $true
                throw "During second evaluation of az output, the output was not an error, but it should have been. This is unexpected."
            }
            catch {
                $errorMessage = $_.ToString()
            }
        }
        throw "Error $azErrorCode when executing $azCommand : $readableAzOutput; Error message: $errorMessage"
    }
    else {
        return $lastAzOutput
    }
}

function HashTable2AzJson($psHashTable) {
    $output = ConvertTo-Json -Compress -InputObject $psHashTable -Depth 10
    if ($PSVersionTable.PSVersion.Major -lt 7 -or ($PSVersionTable.PSVersion.Major -eq 7 -and $PSVersionTable.PSVersion.Minor -lt 3) `
            -or $PSVersionTable.OS.StartsWith("Microsoft Windows")) {
        # The double quoting is now also required on PS 7.3.0 on Windows ... does it depend on the az version?
        $output = $output -replace '"', '\"' # The double quoting is required by PowerShell <7.2 (see https://github.com/PowerShell/PowerShell/issues/1995 and https://docs.microsoft.com/en-us/cli/azure/use-cli-effectively?tabs=bash%2Cbash2#use-quotation-marks-in-parameters)
        return $output.Insert(1, ' ') # Seemingly, there needs to be a space in the JSON somewhere in the beginning for PS 5 to pass consecutive spaces to az instead of having space-separated parameters
    }
    return $output
}

function AppSettingsHashTable2AzJson($psHashTable, $convertForLinux) {
    if ($convertForLinux) {
        $escapedpsHashTable = @{}
        foreach ($key in $psHashTable.Keys) {
            $escapedpsHashTable.Add($key.Replace(":", "__"), $psHashTable[$key])
        }
    }
    else {
        $escapedpsHashTable = $psHashTable
    }

    return HashTable2AzJson -psHashTable $escapedpsHashTable
}