Function New-SCEPmanADObject {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$OU,
        [string]$Description = ""
    )

    try {
        Get-AdComputer $Name | Out-Null
        throw "$($MyInvocation.MyCommand): A computer account with the name '$Name' already exists. Please choose a different name."
    } catch {
        if ($_.Exception.GetType().FullName -match 'ADIdentityNotFoundException') {
            # Expected exception when the computer does not exist; proceed with creation
        } else {
            throw "$($MyInvocation.MyCommand): An error occurred while checking for existing account: $_"
        }
    }

    try {
        if ($PSCmdlet.ShouldProcess("Computer account '$Name' in '$OU'")) {
            New-ADComputer -Name $Name -SamAccountName $Name -Path $OU -Enabled $true -AccountNotDelegated $true -KerberosEncryptionType AES256 -TrustedForDelegation $false -CannotChangePassword $true -Description $Description
        } else {
            # Shorter version for WhatIf
            New-ADComputer -Name $Name -SamAccountName $Name -Path $OU
        }

    } catch {
        throw "$($MyInvocation.MyCommand): An error occurred while creating account: $_"
    }

    # Validate creation
    try {
        $ADComputer = Get-AdComputer $Name
        if ($null -eq $ADComputer) {
            # Condition should not be hit, but might be implemented in a future version of Get-ADComputer
            throw "$($MyInvocation.MyCommand): Computer account '$Name' could not be found after creation."
        }

        return $ADComputer
    }
    catch {
        throw "$($MyInvocation.MyCommand): An error occurred while validating account: $_"
    }
}

Function Read-FileBytes {
    param(
        [string]$Path
    )
    return [System.IO.File]::ReadAllBytes($Path)
}

Function Get-TempFilePath {
    return [System.IO.Path]::GetTempFileName()
}

Function New-SCEPmanADKeyTab {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DownlevelLogonName,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ServicePrincipalName,

        [string]$PrincipalType = 'KRB5_NT_PRINCIPAL',
        [string]$Algorithm = 'AES256-SHA1',

        [string]$ktpassPath = "ktpass.exe",
        [switch]$ShowKtpassOutput
    )

    # Use for temporary keytab storage
    $tempFile = Get-TempFilePath

    # Check if ktpass exists
    if ($ktpassPath -ne 'ktpass.exe' -and -not (Test-Path -Path $ktpassPath)) {
        throw "$($MyInvocation.MyCommand): ktpass executable not found at path '$ktpassPath'. Please ensure ktpass is installed and the path is correct."
    }

    try {
        $ktpassArgs = "/princ $ServicePrincipalName /mapuser `"$DownlevelLogonName`" /rndPass /out `"$tempFile`" /ptype $PrincipalType /crypto $Algorithm +Answer"
        Write-Verbose "$($MyInvocation.MyCommand): Running $ktpassPath with arguments: $ktpassArgs"

        Write-Information "Creating keytab for principal '$ServicePrincipalName' `n"
        $ProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
        $ProcessInfo.FileName = $ktpassPath
        $ProcessInfo.RedirectStandardError = $true
        $ProcessInfo.RedirectStandardOutput = $true
        $ProcessInfo.UseShellExecute = $false
        $ProcessInfo.Arguments = $ktpassArgs
        $Process = New-Object System.Diagnostics.Process
        $Process.StartInfo = $ProcessInfo
        $Process.Start() | Out-Null
        $Process.WaitForExit()

        $stdout = $Process.StandardOutput.ReadToEnd()
        $stderr = $Process.StandardError.ReadToEnd()

        if ($stderr.Contains('Failed to set property ''servicePrincipalName''')) {
            throw "$($MyInvocation.MyCommand): ServicePrincipalName could not be set successfully`nstderr: `n $stderr"
        }

        if ($stderr.Contains('Failed to set property ''userPrincipalName''')) {
            throw "$($MyInvocation.MyCommand): UserPrincipalName could not be set successfully`nstderr: `n $stderr"
        }

        if ($Process.ExitCode -eq 0) {
                Write-Verbose "$($MyInvocation.MyCommand): Keytab written to $tempFile"
                [byte[]]$keyTabData = Read-FileBytes -Path $tempFile

                if ($ShowKtpassOutput) {
                    Write-Information "ktpass stdout:`n$stdout"
                    Write-Information "ktpass stderr:`n$stderr"
                }
        } else {
            throw "$($MyInvocation.MyCommand): ktpass failed with exit code $($Process.ExitCode)`nstdout: `n $stdout`nstderr: `n $stderr"
        }
    } catch {
        throw "$($MyInvocation.MyCommand): An error occurred while creating keytab: $_"
    } finally {
        Write-Verbose "$($MyInvocation.MyCommand): Cleaning up temporary keytab file: $tempFile"
        if (Test-Path -Path $tempFile) {
            Remove-Item -Path $tempFile -Force
        }
    }

    return $keyTabData
}

Function Protect-SCEPmanKeyTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$RecipientCert,
        [Parameter(Mandatory)]
        [byte[]]$KeyTabData
    )

    Write-Verbose "$($MyInvocation.MyCommand): Encrypting keytab ($($KeyTabData.Length) bytes) for recipient $($RecipientCert.Subject)"
    $encryptionContentInfo = [System.Security.Cryptography.Pkcs.ContentInfo]::new($KeyTabData)
    $envelopedCms = [System.Security.Cryptography.Pkcs.EnvelopedCms]::new($encryptionContentInfo)

    $recipient = New-Object System.Security.Cryptography.Pkcs.CmsRecipient ($RecipientCert)
    $envelopedCms.Encrypt($recipient)

    $EncodedContent = [System.Convert]::ToBase64String($envelopedCms.Encode())

    return $EncodedContent
}