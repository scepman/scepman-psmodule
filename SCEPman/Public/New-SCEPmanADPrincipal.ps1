<#
 .Synopsis
  Creates a new Active Directory principal (computer account) for SCEPman to use.

 .Parameter Name
    The name of the computer account to create.

 .Example
   New-SCEPmanADPrincipal -Name "STEPman" -AppServiceUrl "scepman.contoso.com" -SPN "HTTP/stepman.example.com" -WhatIf
#>

Function New-SCEPmanADPrincipal {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$AppServiceUrl,
        [string]$Domain,
        [string]$OU,

        [ValidateScript({
            if (Test-Path -Path $_ -PathType Leaf) {
                return $true
            } else {
                throw "File '$_' does not exist."
            }
        })]
        [string]$CaCertificate,
        [string]$SPN
    )

    Begin {
        # Make sure we have RSAT tools
        if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
            Write-Error "ActiveDirectory module not found. Install RSAT or run on a DC."
            exit 1
        }
        Import-Module ActiveDirectory -ErrorAction Stop

        # Validate tooling
        if (-not (Get-Command ktpass -ErrorAction SilentlyContinue)) {
            Write-Warning "ktpass.exe not found in PATH. Copy ktpass to PATH or run this on a DC"
            return
        }

        if (-not $Domain) {
            Write-Verbose "No domain provided, getting information for current domain."
            $domainInfo = Get-ADDomain
        } Else {
            Write-Verbose "Getting informationn for provided domain: $Domain"
            $domainInfo = Get-ADDomain $Domain
        }

        $domainFQDN = $domainInfo.DNSRoot
        $domainNetBIOS = $domainInfo.NetBIOSName

        if ($null -eq $domainFQDN -or $null -eq $domainNetBIOS) {
            Write-Error "Could not retrieve domain information for domain '$Domain'. Please check the domain name and your connectivity to the domain."
            return
        }

        # Make sure we have a SPN
        if (-not $SPN) {
            Write-Verbose "No SPN provided. Using default: $SPN"
            $SPN = $AppServiceUrl -replace 'https?://', 'HTTP/' -replace '/+$' + "@$domainFQDN"
        }

        # Make sure we have an OU to create the principal in
        if (-not $OU) {
            Write-Verbose "No OU provided. Ask for confirmation to create in default Computers container."
            # Take default Computers container if no OU provided
            $OU = $domainInfo.ComputerContainer

            if($PSCmdlet.ShouldContinue($OU, "No OU provider. Create in default Computers container?") -eq $false) {
                Write-Output "Operation cancelled by user."
                return
            }
        }

        # Ensure we have a certificate to encrypt the keytab
        if (-not $CaCertificate) {
            Write-Verbose "No CA certificate provided. Fetch from app service"
            $CaUri = $AppServiceUrl -replace '/+$'  + "/ca"
            $Response = Invoke-WebRequest -Uri $CaUri -UseBasicParsing -ErrorAction Stop
            $RecipientCert = [System.Security.Cryptography.X509Certificates.X509Certificate2]$Response.Content
        } else {
            Write-Verbose "Loading CA certificate from file $CaCertificate"
            try {
                $absolutePath = (Get-Item -Path $CaCertificate).FullName
                $RecipientCert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromCertFile($absolutePath)
            } catch {
                Write-Error "Could not load DER certificate from file '$CaCertificate': $_"
                return
            }
        }

    }

    Process {
        if ($PSCmdlet.ShouldProcess($Name, "Creating AD $Type account")) {
            New-ADComputer -Name $Name -SamAccountName $Name -Path $OU
            Write-Output "WhatIf: Computer account would be created."
            return
        }

        try {
            New-ADComputer -Name $Name -SamAccountName $Name -Path $OU -Enabled $true -AccountNotDelegated $true -KerberosEncryptionType AES256 -TrustedForDelegation $false -CannotChangePassword $true
            Write-Output "Computer account '$Name' created in '$OU'."
        } catch {
            Write-Error "An error occurred while creating account: $_"
            return
        }

        # Use for temporary keytab storage
        $tempFile = [System.IO.Path]::GetTempFileName()

        try {
            $ktpassArgs = "/princ $SPN /mapuser `"$domainNetBIOS\$Name$`" /rndPass /out `"$tempFile`" /ptype KRB5_NT_PRINCIPAL /crypto AES256-SHA1 +Answer"
            $proc = Start-Process -FilePath ktpass -ArgumentList $ktpassArgs -NoNewWindow -Wait -PassThru

            if ($proc.ExitCode -eq 0) {
                    Write-Verbose "Keytab written to $tempFile"
                    [byte[]]$keyTabData = [System.IO.File]::ReadAllBytes($tempFile)
            } else {
                Write-Warning "ktpass returned exit code $($proc.ExitCode). Check output for errors."
            }
        } catch {
            Write-Error "An error occurred while creating keytab: $_"
            return
        } finally {
            Write-Verbose "Cleaning up temporary keytab file: $tempFile"
            if (Test-Path -Path $tempFile) {
                Remove-Item -Path $tempFile -Force
            }
        }

        # Create pck7 encrypted keytab
        $encryptionContentInfo = [System.Security.Cryptography.Pkcs.ContentInfo]::new($keyTabData)
        $envelopedCms = [System.Security.Cryptography.Pkcs.EnvelopedCms]::new($encryptionContentInfo)

        $recipient = New-Object System.Security.Cryptography.Pkcs.CmsRecipient ($RecipientCert)
        $envelopedCms.Encrypt($recipient)

        $encryptedContent = $envelopedCms.Encode()

        Write-Output ([System.Convert]::ToBase64String($encryptedContent))
    }
}