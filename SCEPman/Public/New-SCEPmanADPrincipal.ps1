<#
    .Synopsis
    Creates a new Active Directory principal (computer account) for SCEPman to use.

    .Parameter Name
        The name of the computer account to create.

    .Parameter AppServiceUrl
        The URL of the SCEPman App Service

    .Parameter Domain
        The Active Directory domain to create the account in. If not provided, the current domain is used.

    .Parameter OU
        The OU to create the account in. If not provided, the default Computers container is used.

    .Parameter CaCertificate
        A DER encoded certificate file to encrypt the keytab for. If not provided, the certificate is fetched from the SCEPman App Service.

    .Parameter SPN
        The Service Principal Name to assign to the account. If not provided, a default SPN is generated based on the AppServiceUrl.

    .Parameter SkipObjectCreation
        If set, the AD object creation is skipped. Useful if the object already exists.

    .Example
        New-SCEPmanADPrincipal -Name "STEPman" -AppServiceUrl "scepman.contoso.com"

        Creates a computer account named "STEPman" in the default Computers container of the current domain,
        with a SPN based on the provided AppServiceUrl. The keytab is encrypted using
    .EXAMPLE
        New-SCEPmanADPrincipal -Name "STEPman" -AppServiceUrl "scepman.contoso.com" -Domain "contoso.com" -OU "OU=ServiceAccounts,DC=contoso,DC=com" -CaCertificate "C:\path\to\ca.der" -SPN "HTTP/stepman.contoso.com@CONTOSO"

        Creates a computer account named "STEPman" in the specified OU of the specified domain,
        with a SPN based on the provided AppServiceUrl. The keytab is encrypted using the provided
        CA certificate.
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
        [string]$CaEndpoint = "/ca",
        [string]$SPN,
        [switch]$SkipObjectCreation,
        [switch]$ShowKtpassOutput,

        # App service parameters for Set-SCEPmanEndpoint
        [string]$SCEPmanAppServiceName,
        [string]$SCEPmanResourceGroupName,
        [string]$DeploymentSlotName,
        [string]$SubscriptionId,
        [switch]$SearchAllSubscriptions

    )

    Begin {
        if(-not $PSBoundParameters.ContainsKey('InformationAction')) {
            Write-Debug "Setting InformationAction to 'Continue' for this cmdlet as no user preference was set."
            $InformationPreference = 'Continue'
        }

        # Make sure we have RSAT tools
        if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
            Write-Error "ActiveDirectory module not found. Install RSAT or run on a DC."
            exit 1
        }
        Import-Module ActiveDirectory -ErrorAction Stop -Verbose:$false

        # Validate tooling
        if (-not (Get-Command ktpass -ErrorAction SilentlyContinue)) {
            Write-Warning "ktpass.exe not found in PATH. Copy ktpass to PATH or run this on a DC"
            return
        }

        if ($SCEPmanAppServiceName -and -not (Get-Command 'az')) {
            Write-Warning "App service parameter found but az CLI not found in PATH. Ensure Azure CLI is installed and accessible."
            return
        }

        # Ensure we have loaded assembly for enveloped CMS
        try {
            Add-Type -AssemblyName System.Security
        } catch {
            Write-Error "Could not load System.Security assembly: $_"
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
            $SPN = 'HTTP/' + ($AppServiceUrl -replace 'https?://' -replace '/+$') + "@$domainFQDN"
        }

        # Make sure we have an OU to create the principal in
        if (-not $OU -and -not $SkipObjectCreation) {
            Write-Verbose "No OU provided. Ask for confirmation to create in default Computers container."
            # Take default Computers container if no OU provided
            $OU = $domainInfo.ComputersContainer

            if($PSCmdlet.ShouldContinue($OU, "No OU provided. Create in default Computers container?") -eq $false) {
                Write-Information "Operation cancelled by user."
                return
            }
        }

        # Ensure we have a certificate to encrypt the keytab
        if (-not $CaCertificate) {
            Write-Verbose "No CA certificate provided. Fetch from app service"
            $CaUri = ($AppServiceUrl -replace '/+$') + $CaEndpoint
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

        if ($null -eq $RecipientCert) {
            Write-Error "Could not obtain recipient certificate for keytab encryption."
            return
        }

    }

    Process {

        if($SkipObjectCreation) {
            Write-Verbose "Skipping AD object creation as per parameter."
        } else {
            $SCEPmanADObject = New-SCEPmanADObject -Name $Name -OU $OU
            if($null -eq $SCEPmanADObject) {
                Write-Error "Failed to create computer account '$Name' in '$OU'."
                Write-Error "Make sure you have the necessary permissions."
                return
            } else {
                Write-Information "Successfully created computer account '$Name' in '$OU'."
            }
        }

        $keyTabData = New-SCEPmanADKeyTab -DownlevelLogonName "$domainNetBIOS\$Name" -ServicePrincipalName $SPN
        if ($null -eq $keyTabData) {
            Write-Error "Failed to create keytab for principal '$SPN'"
            return
        }

        $encryptedKeyTab = Protect-SCEPmanKeyTab -RecipientCert $RecipientCert -KeyTabData $keyTabData
        if ($null -eq $encryptedKeyTab) {
            Write-Error "Failed to encrypt keytab for recipient $($RecipientCert.Subject)"
            return
        }

        if ($SCEPmanAppServiceName) {
            Write-Verbose "App service parameters provided, configuring SCEPman endpoint."
            $EndpointParameters = @{
                Endpoint                 = "ActiveDirectory"
                EncryptedKeyTab          = $encryptedKeyTab
                EnableComputer           = $true
                EnableUser               = $true
                EnableDC                 = $true
                SCEPmanAppServiceName    = $SCEPmanAppServiceName
            }

            if ($SCEPmanResourceGroupName) { $EndpointParameters.SCEPmanResourceGroupName = $SCEPmanResourceGroupName }
            if ($DeploymentSlotName) { $EndpointParameters.DeploymentSlotName = $DeploymentSlotName }
            if ($SubscriptionId) { $EndpointParameters.SubscriptionId = $SubscriptionId }
            if ($SearchAllSubscriptions) { $EndpointParameters.SearchAllSubscriptions = $true }

            Set-SCEPmanEndpoint @EndpointParameters
        } else {
            Write-Information "Keytab creation and encryption successful. Use the following Base64 encoded encrypted keytab data in your SCEPman AD endpoint configuration:"
            Write-Information "AppConfig:ActiveDirectory:KeyTab`n"
            Write-Information $encryptedKeyTab
        }
    }
}