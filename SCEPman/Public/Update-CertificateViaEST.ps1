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
    [CmdletBinding(DefaultParameterSetName='Search')]
    param (
        [Parameter(Mandatory=$true)]
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
        [Nullable[System.Int32]]$ValidityThresholdDays
    )
    BEGIN {
        if(-not $IsWindows) {
            throw "EST Renewal with this CMDlet is only supported on Windows. For Linux, use EST with another tool like this sample script: https://github.com/scepman/csr-request/blob/main/enroll-certificate/renewcertificate.sh"
        }

        if ($PSCmdlet.ParameterSetName -eq 'Search') {
            if ($User -and $Machine -or (-not $User -and -not $Machine)) {
                throw "You must specify either -User or -Machine."
            }

            # Get all certs to be renewed
            $Certificate = GetSCEPmanCerts -AppServiceUrl $AppServiceUrl -User:$User -Machine:$Machine -FilterString $FilterString -ValidityThresholdDays $ValidityThresholdDays
        }
    }

    PROCESS {
        # Renew all certs
        $Certificate | ForEach-Object {
            RenewCertificateMTLS -AppServiceUrl $AppServiceUrl -User:$User -Machine:$Machine -Certificate $_
        }
    }
}