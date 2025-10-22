Function New-SCEPmanADObject {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$OU
    )

    try {
        Get-AdComputer $Name | Out-Null
        Write-Error "$($MyInvocation.MyCommand): A computer account with the name '$Name' already exists. Please choose a different name."
        return
    } catch {
        if ($_.Exception.GetType().FullName -match 'ADIdentityNotFoundException') {
            # Expected exception when the computer does not exist; proceed with creation
        } else {
            Write-Error "$($MyInvocation.MyCommand): An error occurred while checking for existing account: $_"
            return
        }
    }

    try {
        if ($PSCmdlet.ShouldProcess("Computer account '$Name' in '$OU'")) {
            New-ADComputer -Name $Name -SamAccountName $Name -Path $OU -Enabled $true -AccountNotDelegated $true -KerberosEncryptionType AES256 -TrustedForDelegation $false -CannotChangePassword $true
        } else {
            # Shorter version for WhatIf
            New-ADComputer -Name $Name -SamAccountName $Name -Path $OU
        }

    } catch {
        Write-Error "$($MyInvocation.MyCommand): An error occurred while creating account: $_"
        return
    }

    # Validate creation
    try {
        $ADComputer = Get-AdComputer $Name
        if ($null -eq $ADComputer) {
            # Condition should not be hit, but might be implemented in a future version of Get-ADComputer
            Write-Error "$($MyInvocation.MyCommand): Computer account '$Name' could not be found after creation."
            return
        }

        return $ADComputer
    }
    catch {
        Write-Error "$($MyInvocation.MyCommand): An error occurred while validating account: $_"
        return
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
    if (-not (Test-Path -Path $ktpassPath)) {
        Write-Error "$($MyInvocation.MyCommand): ktpass executable not found at path '$ktpassPath'. Please ensure ktpass is installed and the path is correct."
        return
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
            Write-Error "$($MyInvocation.MyCommand): ServicePrincipalName could not be set successfully`nstderr: `n $stderr"
            return
        }

        if ($stderr.Contains('Failed to set property ''userPrincipalName''')) {
            Write-Error "$($MyInvocation.MyCommand): UserPrincipalName could not be set successfully`nstderr: `n $stderr"
            return
        }

        if ($Process.ExitCode -eq 0) {
                Write-Verbose "$($MyInvocation.MyCommand): Keytab written to $tempFile"
                [byte[]]$keyTabData = Read-FileBytes -Path $tempFile

                if ($ShowKtpassOutput) {
                    Write-Information "ktpass stdout:`n$stdout"
                    Write-Information "ktpass stderr:`n$stderr"
                }
        } else {
            Write-Warning "$($MyInvocation.MyCommand): ktpass returned exit code $($Process.ExitCode)"
            Write-Warning "$($MyInvocation.MyCommand): ktpass stdout: `n $stdout"
            Write-Warning "$($MyInvocation.MyCommand): ktpass stderr: `n $stderr"
            return
        }
    } catch {
        Write-Error "$($MyInvocation.MyCommand): An error occurred while creating keytab: $_"
        return
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