<#
 .Synopsis
  Powershell script for renewing certificate using MTLS endpoint of SCEPman.

 .Parameter AppServiceUrl
  The URL of the SCEPman App Service

 .Parameter Certificate
  The certificate to renew. Either this or User/Machine must be set.

 .Parameter User
  Set this flag to renew a user certificate.

 .Parameter Machine
  Set this flag to renew a machine certificate. (Either User or Machine must be set)

 .Parameter FilterString
  Only renew certificates whose Subject field contains the filter string.

 .Parameter ValidityThresholdDays
  Will only renew certificates that are within this number of days of expiry (default value is 30).

 .Parameter AllowInvalid
  Set this flag to allow renewal of certificates that are expired, revoked, or do not chain to a trusted Root CA.

 .Example
  Update-CertificateViaEST -AppServiceUrl "https://scepman-appservice.net/" -User -ValidityThresholdDays 100 -FilterString "certificate"

 .EXAMPLE
 $cert = Get-Item -Path "Cert:\CurrentUser\My\1234567890ABCDEF1234567890ABCDEF12345678"
 Update-CertificateViaEST -AppServiceUrl "https://scepman-appservice.net/" -Certificate $cert
#>
Function Update-CertificateViaEST {
    [CmdletBinding(DefaultParameterSetName='Search')]
    [OutputType([System.Security.Cryptography.X509Certificates.X509Certificate2[]])]
    param (
        [Parameter(Mandatory, ParameterSetName='Search')]
        [Parameter(Mandatory=$false, ParameterSetName='Direct')]
        [string]$AppServiceUrl,
        [Parameter(Mandatory=$true, ValueFromPipeline = $true, ParameterSetName='Direct')]
        [System.Security.Cryptography.X509Certificates.X509Certificate2[]]$Certificate,
        [Parameter(Mandatory=$false)]
        [switch]$User,
        [Parameter(Mandatory=$false)]
        [switch]$Machine,
        [Parameter(Mandatory=$false, ParameterSetName='Search')]
        [string]$FilterString,
        [Parameter(Mandatory=$false, ParameterSetName='Search')]
        [AllowNull()]
        [Nullable[System.Int32]]$ValidityThresholdDays,
        [Parameter(Mandatory=$false, ParameterSetName='Search')]
        [switch]$AllowInvalid
    )
    BEGIN {
        if ($PSVersionTable.PSVersion.Major -lt 7) {
            throw "This script requires PowerShell 7 or higher."
        }

        if(-not $IsWindows) {
            throw "EST Renewal with this CMDlet is only supported on Windows. For Linux, use EST with another tool like this sample script: https://github.com/scepman/csr-request/blob/main/enroll-certificate/renewcertificate.sh"
        }

        if ($PSCmdlet.ParameterSetName -eq 'Search') {
            if ($User -and $Machine -or (-not $User -and -not $Machine)) {
                throw "You must specify either -User or -Machine."
            }

            # Get all certs to be renewed
            $Certificate = GetSCEPmanCerts -AppServiceUrl $AppServiceUrl -User:$User -Machine:$Machine -FilterString $FilterString -ValidityThresholdDays $ValidityThresholdDays -AllowInvalid:$AllowInvalid
        }
    }

    PROCESS {
        # Renew all certs
        foreach ($cert in $Certificate) {
            RenewCertificateMTLS -AppServiceUrl $AppServiceUrl -User:$User -Machine:$Machine -Certificate $cert
        }
    }
}