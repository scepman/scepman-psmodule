$MAX_RETRY_COUNT = 4  # for some operations, retry a couple of times
$SNAILMODE_MAX_RETRY_COUNT = 10 # For very slow tenants, retry more often

$script:Snail_Mode = $false
$Sleep_Factor = 1
$Snail_Maximum_Sleep_Factor = 90 # times ten is 15 minutes

function ConvertLinesToObject($lines) {
    if($null -eq $lines) {
        return $null
    }
    $linesJson = [System.String]::Concat($lines)
    return ConvertFrom-Json $linesJson
}

$PERMISSION_ALREADY_ASSIGNED = "Permission already assigned"

function CheckAzOutput($azOutput, $fThrowOnError) {
    [String[]]$errorMessages = @()
    foreach ($outputElement in $azOutput) {
        if ($null -ne $outputElement) {
            if ($outputElement.GetType() -eq [System.Management.Automation.ErrorRecord]) {
                if ($outputElement.ToString().Contains("Permission being assigned already exists on the object")) {  # TODO: Does this work in non-English environments?
                    Write-Information "Permission is already assigned when executing $azCommand"
                    Write-Output $PERMISSION_ALREADY_ASSIGNED
                } elseif ($outputElement.ToString().EndsWith("does not exist or one of its queried reference-property objects are not present.")) {
                    # This indicates we are in a tenant with especially long delays between creation of an object and when it becomes available via Graph (this happens and it seems to be tenant-specific).
                    # Let's go into snail mode and thereby grant Graph more time
                    Write-Warning "Created object is not yet available via MS Graph. Reducing executing speed to give Graph more time."
                    $script:Snail_Mode = $true
                    $Sleep_Factor = 0.8 * $Sleep_Factor + 0.2 * $Snail_Maximum_Sleep_Factor # approximate longer sleep times
                    Write-Verbose "Retrying operations now $SNAILMODE_MAX_RETRY_COUNT times, and waiting for (n * $Sleep_Factor) seconds on n-th retry"
                } elseif ($outputElement.ToString().StartsWith("WARNING")) {
                    if ($outputElement.ToString().StartsWith("WARNING: The underlying Active Directory Graph API will be replaced by Microsoft Graph API") `
                    -or $outputElement.ToString().StartsWith("WARNING: This command or command group has been migrated to Microsoft Graph API.")) {
                        # Ignore, we know that
                    } else
                    {
                        Write-Warning $outputElement.ToString()
                    }
                } else {
                    if ($outputElement.ToString().contains("does not have authorization to perform action 'Microsoft.Authorization/roleAssignments/write'")) {
                        $errorMessages += "You have insufficient privileges to assign roles to Managed Identities. Make sure you have the Global Admin or Privileged Role Administrator role."
                    } elseif($outputElement.ToString().Contains("Forbidden")) {
                        $errorMessages += "You have insufficient privileges to complete the operation. Please ensure that you run this CMDlet with required privileges e.g. Global Administrator"
                    }

                    $errorMessages += $outputElement
                }
            } else {
                Write-Output $outputElement # add to return value of this function
            }
        }
    }
    if ($errorMessages.Count -gt 0) {
        $ErrorMessageOneLiner = [String]::Join("`r`n", $errorMessages)
        if ($fThrowOnError) {
            throw $ErrorMessageOneLiner
        } else {
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
    $account = az account show 2>&1
    if ($account.GetType() -eq [System.Management.Automation.ErrorRecord]) {
        if (($account.ToString().Contains("az login")) -or ($account.ToString().Contains("az account set"))) {
            Write-Host "Not logged in to az yet. Please log in."
            $null = az login # TODO: Check whether the login worked
            AzLogin
        }
        else {
            Write-Error "Error $account while trying to use az" # possibly az not installed?
            throw $account
        }
    } else {
        $accountInfo = ConvertLinesToObject($account)
        Write-Information "Logged in to az as $($accountInfo.user.name)"
    }
    return $accountInfo
}

$azVersionInfo = $null

function GetAzVersion {
    if ($null -eq $azVersionInfo) {
        $azVersionInfo = ConvertLinesToObject -lines $(az version)
    }
    return $azVersionInfo
}

function AzUsesAADGraph {
    $cliVersion = [Version]::Parse((GetAzVersion).'azure-cli')
    return $cliVersion -lt '2.37'
}

# It is intended to use for az cli add permissions and az cli add permissions admin
# $azCommand - The command to execute.
#
function ExecuteAzCommandRobustly($azCommand, $principalId = $null, $appRoleId = $null, $GraphBaseUri = $null) {
    $azErrorCode = 1234 # A number not null
    $retryCount = 0
    $script:Snail_Mode = $false
    while ($azErrorCode -ne 0 -and ($retryCount -le $MAX_RETRY_COUNT -or $script:Snail_Mode -and $retryCount -le $SNAILMODE_MAX_RETRY_COUNT)) {
      $lastAzOutput = Invoke-Expression "$azCommand 2>&1" # the output is often empty in case of error :-(. az just writes to the console then
      $azErrorCode = $LastExitCode
      try {
        $lastAzOutput = CheckAzOutput -azOutput $lastAzOutput -fThrowOnError $true
            # If we were request to check that the permission is there and there was no error, do the check now.
            # However, if the permission has been there previously already, we can skip the check
        if($null -ne $appRoleId -and $azErrorCode -eq 0 -and $PERMISSION_ALREADY_ASSIGNED -ne $lastAzOutput) {
            $appRoleAssignments = ConvertLinesToObject -lines $(az rest --method get --url "$GraphBaseUri/v1.0/servicePrincipals/$principalId/appRoleAssignments")
            $grantedPermission = $appRoleAssignments.value | Where-Object { $_.appRoleId -eq $appRoleId }
            if ($null -eq $grantedPermission) {
                $azErrorCode = 999 # A number not 0
            }
        }
      }
      catch {
          Write-Warning $_
          $azErrorCode = 654  # a number not 0
      }
      if ($azErrorCode -ne 0) {
        ++$retryCount
        Write-Verbose "Retry $retryCount for $azCommand after $($retryCount * $SLEEP_FACTOR) seconds of sleep because Error Code is $azErrorCode"
        Start-Sleep ($retryCount * $SLEEP_FACTOR) # Sleep for some seconds, as the grant sometimes only works after some time
      }
    }
    if ($azErrorCode -ne 0 ) {
      if ($null -eq $lastAzOutput) {
        $readableAzOutput = "no az output"
      } else {
            # might be an object[]
        $readableAzOutput = CheckAzOutput -azOutput $lastAzOutput -fThrowOnError $false
      }
      Write-Error "Error $azErrorCode when executing $azCommand : $readableAzOutput"
      throw "Error $azErrorCode when executing $azCommand : $readableAzOutput"
    }
    else {
      return $lastAzOutput
    }
}

function HashTable2AzJson($psHashTable) {
    $output = ($psHashTable | ConvertTo-Json -Compress)
    if ($PSVersionTable.PSVersion.Major -lt 7 -or ($PSVersionTable.PSVersion.Major -eq 7 -and $PSVersionTable.PSVersion.Minor -lt 3) `
      -or $PSVersionTable.OS.StartsWith("Microsoft Windows")) { # The double quoting is now also required on PS 7.3.0 on Windows ... does it depend on the az version?
      return $output -replace '"', '\"' # The double quoting is required by PowerShell <7.2 (see https://github.com/PowerShell/PowerShell/issues/1995 and https://docs.microsoft.com/en-us/cli/azure/use-cli-effectively?tabs=bash%2Cbash2#use-quotation-marks-in-parameters)
    }
      return $output
}