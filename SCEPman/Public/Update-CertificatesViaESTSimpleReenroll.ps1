<#
 .Synopsis
  Powershell script for renewing certificate using MTLS endpoint of SCEPman.

 .Parameter Certificate
  The certificate to renew.

 .Parameter AppServiceUrl
  The URL of the SCEPman App Service

 .Parameter User
  Set this flag to renew a user certificate. 

 .Parameter Machine 
  Set this flag to renew a machine certificate. (Either User or Machine must be set)

 .Parameter FilterString
  Only renew certificates whose Subject field contains the filter string.

 .Parameter ValidityThresholdDays
  Will only renew certificates that are within this number of days of expiry (default value is 30).

 .Example
  Update-CertificatesViaESTSimpleReenroll -AppServiceUrl "https://scepman-appservice.net/" -User -ValidityThresholdDays 100 -FilterString "certificate"
#>

using namespace System.Security.Cryptography.X509Certificates
using namespace System.Security.Authentication
using namespace System.Net.Http
using namespace System.Net.Security

# This existance of this function is important for tests, so it can be mocked
Function CreateHttpClient($HttpClientHandler) {
    $client = New-Object HttpClient($HttpClientHandler)
    $client.HttpClientHandler = $HttpClientHandler
    return $client
}

Function RenewCertificateMTLS {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate]$Certificate,
        [Parameter(Mandatory=$true)]
        [string]$AppServiceUrl,
        [Parameter(Mandatory=$false)]
        [switch]$User,
        [Parameter(Mandatory=$false)]
        [switch]$Machine
    )

    if (!$User -and !$Machine -or $User -and $Machine) {
        throw "You must specify either -user or -machine."
    }

    $TempCSR = New-TemporaryFile
    $TempP7B = New-TemporaryFile
    $TempINF = New-TemporaryFile
    try {
        $url = "$AppServiceUrl/.well-known/est/simplereenroll"

        Write-Warning "Using experimental renewal CMDlet - the private key has properties you may not like"

        # In file configuration
        $Inf = 
        '[Version]
        Signature="$Windows NT$"

        [NewRequest]
        ;Change to your,country code, company name and common name
        Subject = "C=US, O=Example Co, CN=something.example.com"

        KeySpec = 1
        KeyLength = 2048
        Exportable = TRUE
        SMIME = False
        PrivateKeyArchive = FALSE
        UserProtected = FALSE
        UseExistingKeySet = FALSE
        ProviderName = "Microsoft RSA SChannel Cryptographic Provider"
        ProviderType = 12
        RequestType = PKCS10
        KeyUsage = 0xa0'
        if ($Machine) {
            $Inf += "`nMachineKeySet = True" # Command still works without, but cert doesn't appear in store.
        }

        $Inf | Out-File -FilePath $TempINF

        # Create new key and CSR
        Remove-Item $TempCSR # Remove CSR file we just have the file name and don't have to overwrite a file
        CertReq -new $TempINF $TempCSR

        # Create renewed version of certificate.
        # Invoke-WebRequest would be easiest option - but doesn't work due to nature of cmd
        # Invoke-WebRequest -Certificate certificate-test.pfx -Body $Body -ContentType "application/pkcs10" -Credential "5hEgpuJQI5afsY158Ot5A87u" -Uri "$AppServiceUrl/.well-known/est/simplereenroll" -OutFile outfile.txt
        # So use HTTPClient instead
        Write-Information "Cert Has Private Key: $($Certificate.HasPrivateKey)"

        $handler = New-Object HttpClientHandler
        $handler.ClientCertificates.Add($Certificate)   # This will make it mTLS
        $handler.ClientCertificateOptions = [System.Net.Http.ClientCertificateOption]::Manual

        $requestmessage = [System.Net.Http.HttpRequestMessage]::new()
        $body = Get-Content $TempCSR
        $requestmessage.Content = [System.Net.Http.StringContent]::new(
            $body,  
            [System.Text.Encoding]::UTF8,"application/pkcs10"
        )
        $requestmessage.Content.Headers.ContentType = "application/pkcs10"
        $requestmessage.Method = 'POST'
        $requestmessage.RequestUri = $url

        $client = CreateHttpClient -HttpClientHandler $handler
        $httpResponseMessage = $client.Send($requestmessage)
        $responseContent =  $httpResponseMessage.Content.ReadAsStringAsync().Result

        Write-Output "-----BEGIN PKCS7-----" > "$TempP7B"
        Write-Output $responseContent >> "$TempP7B"
        Write-Output "-----END PKCS7-----" >> "$TempP7B"
        # Put new certificate into certificate store 
        # (doesn't need to use certreq -submit because that's what the est endpoint is basically doing (submitting to CA))
        CertReq -accept $TempP7B
    }
    finally {
        # Clean those temporary files again if they exist
        Remove-Item $TempCSR -ErrorAction SilentlyContinue
        Remove-Item $TempP7B -ErrorAction SilentlyContinue
        Remove-Item $TempINF -ErrorAction SilentlyContinue
    }
}

Function GetSCEPmanCerts {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$AppServiceUrl,
        [Parameter(Mandatory=$false)]
        [switch]$User,
        [Parameter(Mandatory=$false)]
        [switch]$Machine,
        [Parameter(Mandatory=$false)]
        [string]$FilterString,
        [Parameter(Mandatory=$false)]
        [string]$ValidityThresholdDays
    )

    if (!$User -and !$Machine -or $User -and $Machine) {
        throw "You must specify either -user or -machine."
    }

    $rootCaUrl = "$AppServiceUrl/.well-known/est/cacerts"   # this returns a Base64-encoded PKCS#7 file
    $dlRootCertResponse = Invoke-WebRequest -Uri $rootCaUrl
    if ($dlRootCertResponse.StatusCode -eq 200) {
        Write-Information "Root certificate was downloaded"
    } else {
        Write-Error "Failed to download root certificate from $rootCaUrl"
        return $null
    }

    # Load the downloaded certificate
    [string]$b64P7 = [System.Text.Encoding]::ASCII.GetString($dlRootCertResponse.Content)
    [byte[]]$binP7 = [System.Convert]::FromBase64String($b64P7)
    $certCollection = [System.Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
    $certCollection.Import($binP7)
    if ($certCollection.Length -ne 1) {
        throw "We downloaded $($certCollection.Length) from $rootCaUrl. Currently, we support only a single Root CA without intermediate CAs."
    } else {
        $rootCert = $certCollection[0]
    }

    # Find all certificates in the 'My' stores that are issued by the downloaded certificate
    if ($Machine) {
        $certs = Get-ChildItem -Path "Cert:\LocalMachine\My" | Where-Object { $_.Issuer -eq $rootCert.Subject }
        Write-Information "Found $($certs.Count) machine certificates"
    } elseif ($User) {
        $certs = Get-ChildItem -Path "Cert:\CurrentUser\My" | Where-Object { $_.Issuer -eq $rootCert.Subject }
        Write-Information "Found $($certs.Count) user certificates"
    }

    if ($FilterString) {
        $certs = $certs | Where-Object { $_.Subject -Match $FilterString } 
    }
    if (!($ValidityThresholdDays)) {
        $ValidityThresholdDays = 30  # Default is 30 days
    }
    $ValidityThreshold = New-TimeSpan -Days $ValidityThresholdDays
    $certs = $certs | Where-Object { $ValidityThreshold -ge $_.NotAfter.Subtract([DateTime]::UtcNow) }

    $certs | ForEach-Object {
        Write-Information "Found certificate issued by your SCEPman root:"
        Write-Information "    Subject: $($_.Subject)"
        Write-Information "    Issuer: $($_.Issuer)"
        Write-Information "    Thumbprint: $($_.Thumbprint)"
    }
    return $certs
}

Function Update-CertificatesViaESTSimpleReenroll {
    [CmdletBinding(DefaultParameterSetName="User")]
    param (
        [Parameter(Mandatory=$true)]
        [string]$AppServiceUrl,
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

    if ($User -and $Machine -or (-not $User -and -not $Machine)) {
        throw "You must specify either -User or -Machine."
    }

    # Get all candidate certs
    $certs = GetSCEPmanCerts -AppServiceUrl $AppServiceUrl -User:$User -Machine:$Machine -FilterString $FilterString -ValidityThresholdDays $ValidityThresholdDays
    # Renew all certs
    $certs | ForEach-Object {
        RenewCertificateMTLS -AppServiceUrl $AppServiceUrl -User:$User -Machine:$Machine -Certificate $_
    }
}
