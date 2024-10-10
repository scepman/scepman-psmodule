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

Function IsCertificateCaOfACertificateInTheCollection {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$PossibleCaCertificate,
        [Parameter(Mandatory=$true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2Collection]$Certificates
    )

    $issuedCertificates = $certificates | Where-Object { $_.Issuer -eq $RootCertificate.Subject }
    return $issuedCertificates.Count -gt 0
}

Function RenewCertificateMTLS {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
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

    $url = "$AppServiceUrl/.well-known/est/simplereenroll"

    $privateKey = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
    $oCertRequest = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new($Certificate.Subject, $privateKey, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $sCertRequest = $oCertRequest.CreateSigningRequestPem()

    # Create renewed version of certificate.
    # Invoke-WebRequest would be easiest option - but doesn't work due to nature of cmd
    # Invoke-WebRequest -Certificate certificate-test.pfx -Body $Body -ContentType "application/pkcs10" -Credential "5hEgpuJQI5afsY158Ot5A87u" -Uri "$AppServiceUrl/.well-known/est/simplereenroll" -OutFile outfile.txt
    # So use HTTPClient instead
    Write-Information "Cert Has Private Key: $($Certificate.HasPrivateKey)"

    $handler = New-Object HttpClientHandler
    $handler.ClientCertificates.Add($Certificate)   # This will make it mTLS
    $handler.ClientCertificateOptions = [System.Net.Http.ClientCertificateOption]::Manual

    $requestmessage = [System.Net.Http.HttpRequestMessage]::new()
    $requestmessage.Content = [System.Net.Http.StringContent]::new(
        $sCertRequest,  
        [System.Text.Encoding]::UTF8,"application/pkcs10"
    )
    $requestmessage.Content.Headers.ContentType = "application/pkcs10"
    $requestmessage.Method = 'POST'
    $requestmessage.RequestUri = $url

    $client = CreateHttpClient -HttpClientHandler $handler
    $httpResponseMessage = $client.Send($requestmessage)
    $responseContent =  $httpResponseMessage.Content.ReadAsStringAsync().Result
    $binaryCertificateP7 = [System.Convert]::FromBase64String($responseContent)

    [X509Certificate2Collection]$collectionForNewCertificate = [X509Certificate2Collection]::new()
    if ($Machine) {
        $collectionForNewCertificate.Import($binaryCertificateP7, $null, [X509KeyStorageFlags]::MachineKeySet -bor [X509KeyStorageFlags]::PersistKeySet)
    } else {
        $collectionForNewCertificate.Import($binaryCertificateP7, $null, [X509KeyStorageFlags]::UserKeySet -bor [X509KeyStorageFlags]::PersistKeySet)
    }

    if ($collectionForNewCertificate.Count -eq 0) {
        throw "No certificates were imported from $url"
    }

    $leafCertificate = $collectionForNewCertificate | Where-Object { -not (IsCertificateCaOfACertificateInTheCollection -PossibleCaCertificate $_ -Certificates $collectionForNewCertificate) }
    if ($leafCertificate.Count -ne 1) {
        throw "We received $($collectionForNewCertificate.Count) certificates from $url. Among them, we identified $($leafCertificate.Count) leaf certificates. We support only a single leaf certificate."
    }
    $newCertificate = $leafCertificate

    # Merge new certificate with private key
    $newCertificateWithPrivateKey = [ECDsaCertificateExtensions]::CopyWithPrivateKey($newCertificate, $privateKey)

    if ($Machine) {
        $store = [X509Store]::new("My", [StoreLocation]::LocalMachine)
    } else {
        $store = [X509Store]::new("My", [StoreLocation]::CurrentUser)
    }
    $store.Open([OpenFlags]::ReadWrite)
    $store.Add($newCertificateWithPrivateKey)
    $store.Close()
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
