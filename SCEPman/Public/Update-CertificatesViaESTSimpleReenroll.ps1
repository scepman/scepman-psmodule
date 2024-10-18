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
Function CreateHttpClient($HttpMessageHandler) {
    $client = New-Object HttpClient($HttpMessageHandler)
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

    # Use the same key algorithm as the original certificate
    if ($Certificate.PublicKey.Oid.Value -eq "1.2.840.10045.2.1") {
        $curve = $Certificate.PublicKey.Key.ExportParameters($true).Curve
        $privateKey = [System.Security.Cryptography.ECDsa]::Create($curve)
        $oCertRequest = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new($Certificate.Subject, $privateKey, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    } elseif ($Certificate.PublicKey.Oid.Value -eq "1.2.840.113549.1.1.1") {
        $privateKey = [System.Security.Cryptography.RSA]::Create($Certificate.PublicKey.Key.KeySize)
        $oCertRequest = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new($Certificate.Subject, $privateKey, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } else {
        throw "Unsupported key algorithm: $($Certificate.PublicKey.Oid.Value) ($($Certificate.PublicKey.Oid.FriendlyName))"
    }
    Write-Information "Private key created of type $($privateKey.SignatureAlgorithm) with $($privateKey.KeySize) bits"

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

    $client = CreateHttpClient -HttpMessageHandler $handler
    $httpResponseMessage = $client.Send($requestmessage)
    if ($httpResponseMessage.StatusCode -ne [System.Net.HttpStatusCode]::OK) {
        throw "Failed to renew certificate. Status code: $($httpResponseMessage.StatusCode)"
    }
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
    if ($newCertificate.PublicKey.Oid.Value -eq "1.2.840.10045.2.1") {
        $newCertificateWithPrivateKey = [ECDsaCertificateExtensions]::CopyWithPrivateKey($newCertificate, $privateKey)
    } elseif ($newCertificate.PublicKey.Oid.Value -eq "1.2.840.113549.1.1.1") {
        $newCertificateWithPrivateKey = [RSACertificateExtensions]::CopyWithPrivateKey($newCertificate, $privateKey)
    } else {
        throw "Unsupported key algorithm: $($Certificate.PublicKey.Oid.Value) ($($Certificate.PublicKey.Oid.FriendlyName))"
    }
    Write-Verbose "New certificate $($newCertificateWithPrivateKey.HasPrivateKey?"with":"without") private key: $($newCertificateWithPrivateKey.Subject)"

    if ($Machine) {
        $store = [X509Store]::new("My", [StoreLocation]::LocalMachine)
    } else {
        $store = [X509Store]::new("My", [StoreLocation]::CurrentUser)
    }

    Read-Host "Press Enter to add the new certificate to the store"

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
        $certs = Get-ChildItem -Path "Cert:\LocalMachine\My"
        Write-Information "Found $($certs.Count) machine certificates"
    } elseif ($User) {
        $certs = Get-ChildItem -Path "Cert:\CurrentUser\My"
        Write-Information "Found $($certs.Count) user certificates"
    }

    $certs = $certs | Where-Object { $_.Issuer -eq $rootCert.Subject }
    Write-Information "Found $($certs.Count) certificates issued by the root certificate $($rootCert.Subject)"

    $certs = $certs | Where-Object { $_.HasPrivateKey }  # We can only renew certificates with private keys
    Write-Information "Found $($certs.Count) certificates with private keys"

    if ($FilterString) {
        $certs = $certs | Where-Object { $_.Subject -Match $FilterString } 
    }
    Write-Information "Found $($certs.Count) certificates with filter string '$FilterString'"

    if (!($ValidityThresholdDays)) {
        $ValidityThresholdDays = 30  # Default is 30 days
    }
    $ValidityThreshold = New-TimeSpan -Days $ValidityThresholdDays
    $certs = $certs | Where-Object { $ValidityThreshold -ge $_.NotAfter.Subtract([DateTime]::UtcNow) }
    Write-Information "Found $($certs.Count) certificates that are within $ValidityThresholdDays days of expiry"

    $certs | ForEach-Object {
        Write-Information "These certificates are applicable for renewal:"
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
