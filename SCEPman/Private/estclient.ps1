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

    if (!$User -and !$Machine) {
        if ($Certificate.PSParentPath.StartsWith('Microsoft.PowerShell.Security\Certificate::CurrentUser\My')) {
            $User = $true
        } elseif ($Certificate.PSParentPath.StartsWith('Microsoft.PowerShell.Security\Certificate::LocalMachine\My')) {
            $Machine = $true
        } else {
            throw "You must specify either -user or -machine."
        }
    } elseif ($User -and $Machine) {
        throw "You must not specific both -user or -machine."
    }

    $AppServiceUrl = $AppServiceUrl.TrimEnd('/')
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

    Write-Information "Certificate request created"

    # Create renewed version of certificate.
    # Invoke-WebRequest would be easiest option - but doesn't work due to nature of cmd
    # Invoke-WebRequest -Certificate certificate-test.pfx -Body $Body -ContentType "application/pkcs10" -Credential "5hEgpuJQI5afsY158Ot5A87u" -Uri "$AppServiceUrl/.well-known/est/simplereenroll" -OutFile outfile.txt
    # So use HTTPClient instead
    Write-Debug "Cert Has Private Key: $($Certificate.HasPrivateKey)"

    $handler = New-Object HttpClientHandler
    $null = $handler.ClientCertificates.Add($Certificate)   # This will make it mTLS
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
    Write-Information "Sending renewal request to $url ..."
    $httpResponseMessage = $client.Send($requestmessage)
    if ($httpResponseMessage.StatusCode -ne [System.Net.HttpStatusCode]::OK) {
        throw "Failed to renew certificate. Status code: $($httpResponseMessage.StatusCode)"
    }
    $responseContent =  $httpResponseMessage.Content.ReadAsStringAsync().Result
    $client.Dispose()
    $handler.Dispose()
    Write-Information "Received a successful response from $url"

    $binaryCertificateP7 = [System.Convert]::FromBase64String($responseContent)

    [X509Certificate2Collection]$collectionForNewCertificate = [X509Certificate2Collection]::new()
    if ($Machine) {
        $collectionForNewCertificate.Import($binaryCertificateP7, $null, [X509KeyStorageFlags]::MachineKeySet)
    } else {
        $collectionForNewCertificate.Import($binaryCertificateP7, $null, [X509KeyStorageFlags]::UserKeySet)
    }

    if ($collectionForNewCertificate.Count -eq 0) {
        throw "No certificates were imported from $url"
    } else {
        Write-Verbose "Received $($collectionForNewCertificate.Count) certificates from $url"
    }

    $leafCertificate = $collectionForNewCertificate | Where-Object { -not (IsCertificateCaOfACertificateInTheCollection -PossibleCaCertificate $_ -Certificates $collectionForNewCertificate) }
    if ($leafCertificate.Count -ne 1) {
        throw "We received $($collectionForNewCertificate.Count) certificates from $url. Among them, we identified $($leafCertificate.Count) leaf certificates. We support only a single leaf certificate."
    }
    $newCertificate = $leafCertificate

    Write-Information "Merging new certificate with private key"
    if ($newCertificate.PublicKey.Oid.Value -eq "1.2.840.10045.2.1") {
        $newCertificateWithEphemeralPrivateKey = [ECDsaCertificateExtensions]::CopyWithPrivateKey($newCertificate, $privateKey)
    } elseif ($newCertificate.PublicKey.Oid.Value -eq "1.2.840.113549.1.1.1") {
        $newCertificateWithEphemeralPrivateKey = [RSACertificateExtensions]::CopyWithPrivateKey($newCertificate, $privateKey)
    } else {
        throw "Unsupported key algorithm: $($Certificate.PublicKey.Oid.Value) ($($Certificate.PublicKey.Oid.FriendlyName))"
    }
    Write-Verbose "New certificate $($newCertificateWithEphemeralPrivateKey.HasPrivateKey?"with":"without") private key: $($newCertificateWithEphemeralPrivateKey.Subject)"
    $securePassword = CreateRandomSecureStringPassword
    $binNewCertPfx = $newCertificateWithEphemeralPrivateKey.Export([X509ContentType]::Pkcs12, $securePassword)
    $issuedCertificateAndPrivate = [X509Certificate2]::new($binNewCertPfx, $securePassword, [X509KeyStorageFlags]::UserKeySet -bor [X509KeyStorageFlags]::PersistKeySet)

    Write-Information "Adding the new certificate to the store"
    if ($Machine) {
        $store = [X509Store]::new("My", [StoreLocation]::LocalMachine, [OpenFlags]::ReadWrite -bor [OpenFlags]::OpenExistingOnly)
    } else {
        $store = [X509Store]::new("My", [StoreLocation]::CurrentUser, [OpenFlags]::ReadWrite -bor [OpenFlags]::OpenExistingOnly)
    }

    $store.Add($issuedCertificateAndPrivate)
    $store.Close()
    Write-Information "Certificate added to the store $($store.Name). It is valid until $($issuedCertificateAndPrivate.NotAfter.ToString('u'))"
    $store.Dispose()
}

Function CreateRandomSecureStringPassword {
    $securePassword = [System.Security.SecureString]::new()
    $random = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = [byte[]]::new(16)
    $random.GetBytes($bytes)
    $bytes | ForEach-Object {
        $securePassword.AppendChar([char]$_)
    }
    return $securePassword
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
        [AllowNull()]
        [Nullable[System.Int32]]$ValidityThresholdDays
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
        Write-Verbose "Found $($certs.Count) machine certificates"
    } elseif ($User) {
        $certs = Get-ChildItem -Path "Cert:\CurrentUser\My"
        Write-Verbose "Found $($certs.Count) user certificates"
    }

    $certs = $certs | Where-Object { $_.Issuer -eq $rootCert.Subject }
    Write-Verbose "Found $($certs.Count) certificates issued by the root certificate $($rootCert.Subject)"

    $certs = $certs | Where-Object { $_.HasPrivateKey }  # We can only renew certificates with private keys
    Write-Verbose "Found $($certs.Count) certificates with private keys"

    if ($FilterString) {
        $certs = $certs | Where-Object { $_.Subject -Match $FilterString } 
    }
    Write-Verbose "Found $($certs.Count) certificates with filter string '$FilterString'"

    # Assume certificates with the same subject are the same. For each subject, we continue only with one having the longest remaining validity
    $certGroups = $certs | Group-Object -Property Subject
    Write-Verbose "Found $($certGroups.Count) unique subjects"
    $certs = $certGroups | ForEach-Object { $_.Group | Sort-Object -Property NotAfter -Descending | Select-Object -First 1 }

    if (!($ValidityThresholdDays)) {
        $ValidityThresholdDays = 30  # Default is 30 days
    }
    $ValidityThreshold = New-TimeSpan -Days $ValidityThresholdDays
    $certs = $certs | Where-Object { $ValidityThreshold -ge $_.NotAfter.Subtract([DateTime]::UtcNow) }
    Write-Verbose "Found $($certs.Count) certificates that are within $ValidityThresholdDays days of expiry"

    Write-Information "There are $($certs.Count) certificates applicable for renewal"
    $certs | Out-String | Write-Verbose
    return $certs
}