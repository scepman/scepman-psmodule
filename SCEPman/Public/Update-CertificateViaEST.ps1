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

 .Example
  Update-CertificateViaEST -AppServiceUrl "https://scepman-appservice.net/" -User -ValidityThresholdDays 100 -FilterString "certificate"
#>
Function Update-CertificateViaEST {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$AppServiceUrl,
        [Parameter(Mandatory=$false)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory=$false)]
        [switch]$User,
        [Parameter(Mandatory=$false)]
        [switch]$Machine,
        [Parameter(Mandatory=$false)]
        [string]$FilterString,
        [Parameter(Mandatory=$false)]
        [string]$ValidityThresholdDays
    )

    if(-not $IsWindows) {
        throw "EST Renewal with this CMDlet is only supported on Windows. For Linux, use EST with another tool like this sample script: https://github.com/scepman/csr-request/blob/main/enroll-certificate/renewcertificate.sh"
    }

    if ($null -ne $Certificate -and ($null -ne $FilterString -or $null -ne $ValidityThresholdDays)) {
        throw "You must not specify -Certificate with -FilterString or -ValidityThresholdDays. Use -Certificate to renew a single certificate. Use -FilterString and -ValidityThresholdDays to seach for certificates to renew."
    }
    if ($null -ne $Certificate) {
        return RenewCertificateMTLS -AppServiceUrl $AppServiceUrl -User:$User -Machine:$Machine -Certificate $Certificate
    }

    # -Certificate is null, so we find the certificates to be renewed

    if ($User -and $Machine -or (-not $User -and -not $Machine)) {
        throw "You must specify either -User or -Machine."
    }

    # Get all certs to be renewed
    $certs = GetSCEPmanCerts -AppServiceUrl $AppServiceUrl -User:$User -Machine:$Machine -FilterString $FilterString -ValidityThresholdDays $ValidityThresholdDays
    # Renew all certs
    $certs | ForEach-Object {
        RenewCertificateMTLS -AppServiceUrl $AppServiceUrl -User:$User -Machine:$Machine -Certificate $_
    }
}
