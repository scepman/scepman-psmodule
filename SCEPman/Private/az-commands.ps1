$MAX_RETRY_COUNT = 4  # for some operations, retry a couple of times

function ConvertLinesToObject($lines) {
    if($null -eq $lines) {
        return $null
    }
    $linesJson = [System.String]::Concat($lines)
    return ConvertFrom-Json $linesJson
}

$PERMISSION_ALREADY_ASSIGNED = "Permission already assigned"

function CheckAzOutput($azOutput) {
    foreach ($outputElement in $azOutput) {
        if ($null -ne $outputElement) {
            if ($outputElement.GetType() -eq [System.Management.Automation.ErrorRecord]) {
                if ($outputElement.ToString().Contains("Permission being assigned already exists on the object")) {  # TODO: Does this work in non-English environments?
                    Write-Information "Permission is already assigned when executing $azCommand"
                    Write-Output $PERMISSION_ALREADY_ASSIGNED
                } elseif ($outputElement.ToString().StartsWith("WARNING")) {
                    if ($outputElement.ToString().StartsWith("WARNING: The underlying Active Directory Graph API will be replaced by Microsoft Graph API") `
                    -or $outputElement.ToString().StartsWith("WARNING: This command or command group has been migrated to Microsoft Graph API.")) {
                        # Ignore, we know that
                    } else
                    {
                        Write-Warning $outputElement.ToString()
                    }
                } else {
                    if($outputElement.ToString().Contains("Forbidden")) {
                        Write-Error "You have insufficient privileges to complete the operation. Please ensure that you run this CMDlet with required privileges e.g. Global Administrator"
                    }
                    #Write-Error $outputElement
                    throw $outputElement
                }
            } else {
                Write-Output $outputElement # add to return value of this function
            }
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
        if ($account.ToString().Contains("az login")) {
            Write-Host "Not logged in to az yet. Please log in."
            $null = az login # TODO: Check whether the login worked
        }
        else {
            Write-Error "Error $account while trying to use az" # possibly az not installed?
            throw $account
        }
    } else {
        $accountInfo = ConvertLinesToObject($account)
        Write-Information "Logged in to az as $($accountInfo.user.name)"
    }
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
function ExecuteAzCommandRobustly($azCommand, $principalId = $null, $appRoleId = $null) {
    $azErrorCode = 1234 # A number not null
    $retryCount = 0
    while ($azErrorCode -ne 0 -and $retryCount -le $MAX_RETRY_COUNT) {
      $lastAzOutput = Invoke-Expression "$azCommand 2>&1" # the output is often empty in case of error :-(. az just writes to the console then
      $azErrorCode = $LastExitCode
      try {
        $lastAzOutput = CheckAzOutput($lastAzOutput)
            # If we were request to check that the permission is there and there was no error, do the check now.
            # However, if the permission has been there previously already, we can skip the check
        if($null -ne $appRoleId -and $azErrorCode -eq 0 -and $PERMISSION_ALREADY_ASSIGNED -ne $lastAzOutput) {
            $appRoleAssignments = ConvertLinesToObject -lines $(az rest --method get --url "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments")
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
        Write-Verbose "Retry $retryCount for $azCommand"
        Start-Sleep $retryCount # Sleep for some seconds, as the grant sometimes only works after some time
      }
    }
    if ($azErrorCode -ne 0 ) {
      Write-Error "Error $azErrorCode when executing $azCommand : $($lastAzOutput.ToString())"
      throw "Error $azErrorCode when executing $azCommand : $($lastAzOutput.ToString())"
    }
    else {
      return $lastAzOutput
    }
  }
  