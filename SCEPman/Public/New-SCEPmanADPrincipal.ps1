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

    .Parameter ShowKtpassOutput
        If set, the stdout and stderr output of ktpass.exe is shown in the console.

    .Parameter SCEPmanAppServiceName
        The name of the SCEPman App Service to configure the endpoint in.

    .Parameter SCEPmanResourceGroupName
        The resource group of the SCEPman App Service.

    .Parameter DeploymentSlotName
        The deployment slot name of the SCEPman App Service

    .Parameter SubscriptionId
        The subscription ID to use for the SCEPman App Service.

    .Parameter SearchAllSubscriptions
        If set, all subscriptions the user has access to are searched for the SCEPman App

    .PARAMETER Force
        If set, suppresses interactive prompts.

    .Example
        New-SCEPmanADPrincipal -Name "STEPman" -AppServiceUrl "scepman.contoso.com"

        Creates a computer account named "STEPman" in the default Computers container of the current domain,
        with a SPN based on the provided AppServiceUrl. The keytab is will be encrypted and output in base 64 format.

    .EXAMPLE
        New-SCEPmanADPrincipal -Name "STEPman" -AppServiceUrl "scepman.contoso.com" -Domain "contoso.com" -OU "OU=ServiceAccounts,DC=contoso,DC=com" -CaCertificate "C:\path\to\ca.der" -SPN "HTTP/stepman.contoso.com@CONTOSO"

        Creates a computer account named "STEPman" in the specified OU of the specified domain,
        with a SPN based on the provided AppServiceUrl. The keytab is encrypted using the provided
        CA certificate.

    .EXAMPLE
        New-SCEPmanADPrincipal -Name "STEPman" -AppServiceUrl "scepman.contoso.com" -AppServiceName "app-scepman-contoso"

        Creates a computer account named "STEPman" in the default Computers container of the current domain,
        with a SPN based on the provided AppServiceUrl. The keytab is encrypted and configured on the specified SCEPman App Service.
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
        [switch]$SearchAllSubscriptions,

        [switch]$Force

    )

    Begin {
        # State to only proceed if all prerequisites are met
        # Required as return statements will only proceed to Process block
        $PrerequisitesOk = $false

        if(-not $PSBoundParameters.ContainsKey('InformationAction')) {
            Write-Debug "Setting InformationAction to 'Continue' for this cmdlet as no user preference was set."
            $InformationPreference = 'Continue'
        }

        # Make sure we have RSAT tools
        if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
            throw "ActiveDirectory module not found. Install RSAT or run on a DC."
        }
        Import-Module ActiveDirectory -ErrorAction Stop -Verbose:$false

        # Validate tooling
        if (-not (Get-Command ktpass -ErrorAction SilentlyContinue)) {
            throw "ktpass.exe not found in PATH. Copy ktpass to PATH or run this on a DC"
        }

        if ($SCEPmanAppServiceName -and -not (Get-Command 'az')) {
            throw "App service parameter found but az CLI not found in PATH. Ensure Azure CLI is installed and accessible."
        }

        # Ensure we have loaded assembly for enveloped CMS
        try {
            Add-Type -AssemblyName System.Security
        } catch {
            throw "Could not load System.Security assembly: $_"
        }

        if (-not $Domain) {
            Write-Verbose "No domain provided, getting information for current domain."
            $domainInfo = Get-ADDomain
        } Else {
            Write-Verbose "Getting information for provided domain: $Domain"
            $domainInfo = Get-ADDomain $Domain
        }

        $domainFQDN = $domainInfo.DNSRoot
        $domainNetBIOS = $domainInfo.NetBIOSName
        Write-Information "Using domain FQDN: $domainFQDN"

        if ($null -eq $domainFQDN -or $null -eq $domainNetBIOS) {
            throw "Could not retrieve domain information for domain '$Domain'. Please check the domain name and your connectivity to the domain."
        }

        # Make sure we have a SPN
        if (-not $SPN) {
            $SPN = 'HTTP/' + ($AppServiceUrl -replace 'https?://' -replace '/+$') + '@' + $domainFQDN.ToUpper()
            Write-Information "No SPN provided. Using default: $SPN"
        }

        # Make sure we have an OU to create the principal in
        if (-not $OU -and -not $SkipObjectCreation) {
            Write-Verbose "No OU provided. Ask for confirmation to create in default Computers container."
            # Take default Computers container if no OU provided
            $OU = $domainInfo.ComputersContainer

            if ($Force) {
                Write-Information "No OU provided and -Force specified. Please specify an OU or remove -Force to confirm default Computers container."
                return
            }

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
                throw "Could not load DER certificate from file '$CaCertificate': $_"
            }
        }

        if ($null -eq $RecipientCert) {
            throw "Could not obtain recipient certificate for keytab encryption."
        }

        $PrerequisitesOk = $true
    }

    Process {
        if (-not $PrerequisitesOk) {
            Write-Verbose "Prerequisites not met. Aborting operation."
            return
        }

        # Hold state to determine if we need to clean up
        $ExecutionSuccessful = $false

        if($SkipObjectCreation) {
            Write-Verbose "Skipping AD object creation as per parameter."
        } else {
            $SCEPmanADObject = New-SCEPmanADObject -Name $Name -OU $OU
            if($null -eq $SCEPmanADObject) {
                Write-Error "Failed to create computer account '$Name' in '$OU'.`nMake sure you have the necessary permissions and the object does not already exist."
                return
            } else {
                Write-Information "Successfully created computer account '$Name' in '$OU'."
            }
        }

        try {
            $keyTabData = New-SCEPmanADKeyTab -DownlevelLogonName "$domainNetBIOS\$Name" -ServicePrincipalName $SPN -ShowKtpassOutput:$ShowKtpassOutput
            if ($null -eq $keyTabData) {
                Write-Error "Failed to create keytab for principal '$SPN'`nMake sure that you have the necessary permissions and that the SPN is unique."
                return
            }
        } catch {
            Write-Error "Error creating keytab for principal '$SPN': $_"
            return
        }


        try {
            $encryptedKeyTab = Protect-SCEPmanKeyTab -RecipientCert $RecipientCert -KeyTabData $keyTabData
            if ($null -eq $encryptedKeyTab) {
                Write-Error "Failed to encrypt keytab for recipient $($RecipientCert.Subject)"
                return
            }
        } catch {
            Write-Error "Error encrypting keytab for recipient $($RecipientCert.Subject): $_"
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

            # Check if we need to temporarily disable Web Account Broker
            $brokerSetting = az config get core.enable_broker_on_windows 2> $null | ConvertFrom-Json
            if($brokerSetting.value -eq $true) {
                Write-Verbose "Web Account Broker is enabled in Azure CLI config. Disabling for this session to avoid authentication issues."
                az config set core.enable_broker_on_windows=0
                $restoreBrokerSetting = $true
            } else {
                $restoreBrokerSetting = $false
            }

            Set-SCEPmanEndpoint @EndpointParameters

            # Restore Web Account Broker setting if we changed it
            if($restoreBrokerSetting) {
                Write-Verbose "Restoring Web Account Broker setting in Azure CLI config."
                az config set core.enable_broker_on_windows=1
            }
        } else {
            Write-Information "Keytab creation and encryption successful. Use the following Base64 encoded encrypted keytab data in your SCEPman AD endpoint configuration:"
            Write-Information "AppConfig:ActiveDirectory:KeyTab`n"
            Write-Output $encryptedKeyTab
        }

        $ExecutionSuccessful = $true
    }

    End {
        # Check if we need to clean up created object
        if ($SCEPmanADObject -and $ExecutionSuccessful -eq $false) {
            # Ask for confirmation as we are deleting an object that was just created
            if(-not $Force -and $PSCmdlet.ShouldContinue("Computer account '$($SCEPmanADObject.Name)' in '$($SCEPmanADObject.DistinguishedName)'", "An error occurred during execution. Delete created computer account?") -eq $true) {
                try {
                    Remove-ADComputer -Identity $SCEPmanADObject -Confirm:$false
                    Write-Information "Deleted computer account '$($SCEPmanADObject.Name)'."
                } catch {
                    Write-Warning "Failed to delete computer account '$($SCEPmanADObject.Name)': $_"
                }
            } else {
                Write-Information "Created computer account '$($SCEPmanADObject.Name)' retained as per user choice."
            }
        }
    }
}