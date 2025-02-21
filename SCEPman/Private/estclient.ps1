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

    $issuedCertificates = $certificates | Where-Object { $_.Issuer -eq $PossibleCaCertificate.Subject }
    return $issuedCertificates.Count -gt 0
}

# Define this callback in C#, so it doesn't require a PowerShell runspace to run. This way, it can be called back in a different thread.
$csCodeSelectFirstCertificateCallback = @'
public static class CertificateCallbacks
{
    public static System.Security.Cryptography.X509Certificates.X509Certificate SelectFirstCertificate(
        object sender,
        string targetHost,
        System.Security.Cryptography.X509Certificates.X509CertificateCollection localCertificates,
        System.Security.Cryptography.X509Certificates.X509Certificate remoteCertificate,
        string[] acceptableIssuers)
    {
        return localCertificates[0];
    }

    public static System.Net.Security.LocalCertificateSelectionCallback SelectionCallback {
        get {
            return SelectFirstCertificate;
        }
    }
}
'@
Add-Type -TypeDefinition $csCodeSelectFirstCertificateCallback -Language CSharp

Function RenewCertificateMTLS {
    [CmdletBinding()]
    [OutputType([System.Security.Cryptography.X509Certificates.X509Certificate2])]
    param (
        [Parameter(Mandatory=$true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory=$false)]
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

    if ([string]::IsNullOrEmpty($AppServiceUrl)) {
        Write-Verbose "No AppServiceUrl was specified. Trying to get the AppServiceUrl from the certificate's AIA extension."
        $AiaExtension = $Certificate.Extensions | Where-Object { $_ -is [X509AuthorityInformationAccessExtension] }
        if ($null -eq $AiaExtension) {
            throw "No AppServiceUrl was specified and the certificate does not have an AIA extension to infer it from."
        }

        $CaUrls = $AiaExtension.EnumerateCAIssuersUris()
        if ($CaUrls.Count -eq 0) {
            throw "No AppServiceUrl was specified and the certificate does not have any CA Issuers URLs in the AIA extension to infer it from."
        }
        $AppServiceUrl = $CaUrls[0] # This contains some path for the CA download that we still need to cut off
        Write-Verbose "Found AIA CA URL in certificate: $AppServiceUrl"
        $AppServiceUrl = $AppServiceUrl.Substring(0, $AppServiceUrl.IndexOf('/', "https://".Length))
        Write-Information "Inferred AppServiceUrl from AIA extension: $AppServiceUrl"
    }

    $AppServiceUrl = $AppServiceUrl.TrimEnd('/')
    $url = "$AppServiceUrl/.well-known/est/simplereenroll"

    # Use the same key algorithm as the original certificate
    if ($Certificate.PublicKey.Oid.Value -eq "1.2.840.10045.2.1") {
        $publicKey = $cert.PublicKey.GetECDiffieHellmanPublicKey().PublicKey
        $curve = $publicKey.ExportParameters().Curve
        $privateKey = [System.Security.Cryptography.ECDsa]::Create($curve)
        $oCertRequest = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new($Certificate.Subject, $privateKey, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    } elseif ($Certificate.PublicKey.Oid.Value -eq "1.2.840.113549.1.1.1") {
        $privateKey = [System.Security.Cryptography.RSA]::Create($Certificate.PublicKey.Key.KeySize)
        $oCertRequest = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new($Certificate.Subject, $privateKey, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } else {
        throw "Unsupported key algorithm: $($Certificate.PublicKey.Oid.Value) ($($Certificate.PublicKey.Oid.FriendlyName))"
    }
    Write-Information "Private key created of type $($privateKey.SignatureAlgorithm) with $($privateKey.KeySize) bits"

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        $sCertRequestDER = $oCertRequest.CreateSigningRequest()
        $sCertRequestB64 = [System.Convert]::ToBase64String($sCertRequestDER)

        $sCertRequest = "-----BEGIN CERTIFICATE REQUEST-----`n"

        # Append the encoded csr in chunks of 64 characters to compyly with PEM standard
        for ($i = 0; $i -lt $sCertRequestB64.Length; $i += 64) {
            $sCertRequest += $sCertRequestB64.Substring($i, [System.Math]::Min(64, $sCertRequestB64.Length - $i)) + "`n"
        }

        # Remove trailing newline
        $sCertRequest = $sCertRequest -replace '\n$'

        $sCertRequest += "`n-----END CERTIFICATE REQUEST-----"
    } else {
        $sCertRequest = $oCertRequest.CreateSigningRequestPem()
    }

    Write-Information "Certificate request created"

    # Create renewed version of certificate.
    # Invoke-WebRequest would be easiest option - but doesn't work due -- seemingly, the certificate is not being sent. Maybe, the server must require client certificates.
    #$Response =  Invoke-WebRequest -Certificate $Certificate -Body $sCertRequest -ContentType "application/pkcs10" -Uri "$AppServiceUrl/.well-known/est/simplereenroll" -Method POST
    # So use HTTPClient instead.

    # HttpClientHandler works generally for mTLS.
    # However, it only works with certificates having the Client Authentication EKU. This is because Certificate Helper filters for this EKU: https://github.com/dotnet/runtime/blob/a0fdddab98ad95186d84d4667df4db8a4e651990/src/libraries/Common/src/System/Net/Security/CertificateHelper.cs#L12
    # And HttpClientHandler sets this method as the Callback: https://github.com/dotnet/runtime/blob/main/src/libraries/System.Net.Http/src/System/Net/Http/HttpClientHandler.cs#L271

    # Hence, we need to use SocketsHttpHandler instead. It allows more control over the SSL options.
    Write-Debug "Cert Has Private Key: $($Certificate.HasPrivateKey)"

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Verbose "Detected PowerShell 5: Using HttpClientHandler"
        $handler = New-Object HttpClientHandler
        $handler.ClientCertificates.Add($Certificate)
    } else {
        Write-Verbose "Detected PowerShell 7: Using SocketsHttpHandler"
        $handler = New-Object SocketsHttpHandler

        # SocketsHttpHandler's ClientCertificateOptions is internal. So we need to use reflection to set it. If we leave it at 'Automatic', it would require the certificate to be in the store.
        try {
            $SocketHandlerType = $handler.GetType()
            $ClientCertificateOptionsProperty = $SocketHandlerType.GetProperty("ClientCertificateOptions", [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic)
            $ClientCertificateOptionsProperty.SetValue($handler, [ClientCertificateOption]::Manual)
        }
        catch {
            Write-Warning "Couldn't set ClientCertificateOptions to Manual. This should cause an issue if the certificate is not in the MY store. This is probably due to a too recent .NET version (> 8.0)."
        }
        $handler.SslOptions.LocalCertificateSelectionCallback = [CertificateCallbacks]::SelectionCallback # This just selects the first certificate in the collection. We only provide a single certificate, so this suffices.
        $handler.SslOptions.ClientCertificates = [X509Certificate2Collection]::new()
        $null = $handler.SslOptions.ClientCertificates.Add($Certificate)
    }

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
    try {
        $httpResponseMessage = $client.SendAsync($requestmessage).GetAwaiter().GetResult()
    }
    catch {
        # dump details of the exception, including InnerException
        $ex = $_.Exception
        Write-Error "$($ex.GetType()): $($ex.Message)"
        while ($ex.InnerException) {
            $ex = $ex.InnerException
            Write-Error "$($ex.GetType()): $($ex.Message)"
        }
    }
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
        $keyStorageFlag = [X509KeyStorageFlags]::MachineKeySet
    } else {
        $collectionForNewCertificate.Import($binaryCertificateP7, $null, [X509KeyStorageFlags]::UserKeySet)
        $keyStorageFlag = [X509KeyStorageFlags]::UserKeySet
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
    Write-Verbose "New certificate with private key: $($newCertificateWithEphemeralPrivateKey.Subject)"
    $securePassword = CreateRandomSecureStringPassword
    $binNewCertPfx = $newCertificateWithEphemeralPrivateKey.Export([X509ContentType]::Pkcs12, $securePassword)
    $issuedCertificateAndPrivate = [X509Certificate2]::new($binNewCertPfx, $securePassword, $keyStorageFlag -bor [X509KeyStorageFlags]::PersistKeySet)

    Write-Information "Adding the new certificate to the store"
    if ($Machine) {
        $store = [X509Store]::new("My", [StoreLocation]::LocalMachine)
        $store.Open([OpenFlags]::ReadWrite -bor [OpenFlags]::OpenExistingOnly)
    } else {
        $store = [X509Store]::new("My", [StoreLocation]::CurrentUser)
        $store.Open([OpenFlags]::ReadWrite -bor [OpenFlags]::OpenExistingOnly)
    }

    $store.Add($issuedCertificateAndPrivate)
    $store.Close()
    Write-Information "Certificate added to the store $($store.Name). It is valid until $($issuedCertificateAndPrivate.NotAfter.ToString('u'))"
    $store.Dispose()

    return $issuedCertificateAndPrivate
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
        [Nullable[System.Int32]]$ValidityThresholdDays,
        [Parameter(Mandatory=$false)]
        [switch]$AllowInvalid
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
    $certs = $certGroups | ForEach-Object { $_.Group | Sort-Object -Property NotAfter -Descending | Select-Object -First 1 }
    Write-Verbose "Found $($certs.Count) unique subjects"

    if (!($ValidityThresholdDays)) {
        $ValidityThresholdDays = 30  # Default is 30 days
    }
    $ValidityThreshold = New-TimeSpan -Days $ValidityThresholdDays
    $certs = $certs | Where-Object { $ValidityThreshold -ge $_.NotAfter.Subtract([DateTime]::UtcNow) }
    Write-Verbose "Found $($certs.Count) certificates that are within $ValidityThresholdDays days of expiry"

    if (!$AllowInvalid) {
        $certs = $certs | Where-Object { $_.Verify() }
        Write-Verbose "Found $($certs.Count) certificates that are valid (chaining to a trusted Root CA and neither revoked nor expired)"
    }

    Write-Information "There are $($certs.Count) certificates applicable for renewal"
    $certs | Out-String | Write-Verbose
    return $certs
}