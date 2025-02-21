<#
.SYNOPSIS
  Renews certificates via EST.

.DESCRIPTION
  This function renews certificates via EST. It can renew user or machine certificates based on the specified parameters.

.PARAMETER AppServiceUrl
  The URL of the App Service.

.PARAMETER Certificate
  The certificate to renew. Either this or User/Machine must be set.

.PARAMETER User
  Set this flag to renew a user certificate.

.PARAMETER Machine
  Set this flag to renew a machine certificate. (Either User or Machine must be set)

.PARAMETER FilterString
  Only renew certificates whose Subject field contains the filter string.

.PARAMETER ValidityThresholdDays
  Will only renew certificates that are within this number of days of expiry (default value is 30).

.PARAMETER AllowInvalid
  Set this flag to allow renewal of certificates that are expired, revoked, or do not chain to a trusted Root CA.

.EXAMPLE
  Update-CertificateViaEST -AppServiceUrl "https://scepman-appservice.net/" -User -ValidityThresholdDays 100 -FilterString "certificate"

.EXAMPLE
  $cert = Get-Item -Path "Cert:\CurrentUser\My\1234567890ABCDEF1234567890ABCDEF12345678"
  Update-CertificateViaEST -AppServiceUrl "https://scepman-appservice.net/" -Certificate $cert

#>
Function Update-CertificateViaEST {
    [CmdletBinding(SupportsShouldProcess=$true, DefaultParameterSetName='Search')]
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

        if([System.Environment]::OSVersion.Platform -ne 'Win32NT') {
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
        $renewedCertificates = @()

        # Renew all certs
        foreach ($cert in $Certificate) {
            if ($PSCmdlet.ShouldProcess("Certificate with subject $($cert.Subject)", "Renew certificate")) {
                $renewedCertificates += RenewCertificateMTLS -AppServiceUrl $AppServiceUrl -User:$User -Machine:$Machine -Certificate $cert
            }
        }

        return $renewedCertificates
    }
}