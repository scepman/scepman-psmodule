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
    } catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
        # Nothing to do here, account does not exist and we can continue
    }

    try {
        if ($PSCmdlet.ShouldProcess("Computer account '$Name' in '$OU'")) {
            New-ADComputer -Name $Name -SamAccountName $Name -Path $OU -Enabled $true -AccountNotDelegated $true -KerberosEncryptionType AES256 -TrustedForDelegation $false -CannotChangePassword $true
        } else {
            # Shorter version for WhatIf
            New-ADComputer -Name $Name -SamAccountName $Name -Path $OU
            return
        }

    } catch {
        Write-Error "$($MyInvocation.MyCommand): An error occurred while creating account: $_"
        return
    }
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
        [string]$Algorithm = 'AES256-SHA1'
    )

    # Use for temporary keytab storage
    $tempFile = [System.IO.Path]::GetTempFileName()

    try {
        $ktpassArgs = "/princ $ServicePrincipalName /mapuser `"$DownlevelLogonName`" /rndPass /out `"$tempFile`" /ptype $PrincipalType /crypto $Algorithm +Answer"
        Write-Verbose "$($MyInvocation.MyCommand): Running ktpass with arguments: $ktpassArgs"

        Write-Output "Creating keytab for principal '$ServicePrincipalName' `n"
        $proc = Start-Process -FilePath ktpass -ArgumentList $ktpassArgs -NoNewWindow -Wait -PassThru

        if ($proc.ExitCode -eq 0) {
                Write-Verbose "$($MyInvocation.MyCommand): Keytab written to $tempFile"
                [byte[]]$keyTabData = [System.IO.File]::ReadAllBytes($tempFile)
        } else {
            Write-Warning "$($MyInvocation.MyCommand): ktpass returned exit code $($proc.ExitCode). Check output for errors."
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
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$RecipientCert,
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