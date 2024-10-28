BeforeAll {
    . $PSScriptRoot/../SCEPman/Private/estclient.ps1
    . $PSScriptRoot/../SCEPman/Public/Update-CertificateViaEST.ps1
}

Describe 'SimpleReenrollmentTools' -Skip:(-not $IsWindows) {

    Context 'Update-CertificatesViaESTSimpleReenroll' {
        It 'Fails if both -user and -machine are specified' {
            { Update-CertificateViaEST -AppServiceUrl "https://test.com" -User -Machine } | Should -Throw 'You must specify either -User or -Machine.'
        }

        It 'Fails if neither -user nor -machine are specified' {
            { Update-CertificateViaEST -AppServiceUrl "https://test.com" } | Should -Throw 'You must specify either -User or -Machine.'
        }
    }

    Context 'With temporary certificate creation' {

        BeforeEach {
                # Create Test certificates with a very low key length so it is fast to create
            $script:testcerts = @(
                New-SelfSignedCertificate -Subject "CN=Cert1,OU=PesterTest" -KeyAlgorithm 'RSA' -KeyLength 512 -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddDays(20)
                New-SelfSignedCertificate -Subject "CN=Cert2,OU=PesterTest" -KeyAlgorithm 'RSA' -KeyLength 512 -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddDays(21)
            )
        }

        It 'Renews each certificate that is found' {
            Mock GetSCEPmanCerts {
                return $script:testcerts
            }

            Mock RenewCertificateMTLS {
                param($Certificate, $AppServiceUrl, [switch]$User, [switch]$Machine)

                $Certificate.Subject | Should -Match "OU=PesterTest"
                $User | Should -Be $true
                $Machine | Should -Be $false
                $AppServiceUrl | Should -Be "https://test.com"

                return "New certificate $($Certificate.Subject)"
            }

            $certs = Update-CertificateViaEST -AppServiceUrl "https://test.com" -User

            $certs | Should -HaveCount 2
            Should -Invoke -CommandName RenewCertificateMTLS -Exactly 2
        }

        It 'Terminates gracefully if no certificate is found' {
            Mock GetSCEPmanCerts {
                return @()
            }

            Mock RenewCertificateMTLS {
                param($Certificate, $AppServiceUrl, [switch]$User, [switch]$Machine)

                throw "Should not be called"
            }

            Update-CertificateViaEST -AppServiceUrl "https://test.com" -User

            Should -Invoke -CommandName RenewCertificateMTLS -Exactly 0
        }

        Context 'GetSCEPmanCerts' {
            BeforeAll {
                Mock Invoke-WebRequest {
                    $certCollection = [System.Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
                    $certCollection.Add($script:testcerts[0])
                    $binCert1 = $certCollection.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs7)
                    $b64Cert1 = [Convert]::ToBase64String($binCert1)
                    $b64Cert1Bytes = [System.Text.Encoding]::ASCII.GetBytes($b64Cert1)

                    return @{
                        StatusCode = 200
                        Content = $b64Cert1Bytes
                    }
                }
            }

            It 'Should find all certificates issued by the root' {
                $foundCerts = GetSCEPmanCerts -AppServiceUrl "https://test.com" -User -ValidityThresholdDays 45

                $foundCerts | Should -HaveCount 1
                $foundCerts[0].Subject | Should -Be $script:testcerts[0].Subject
            }

            It 'Should find certificates only when issued by the correct root' {
                $pesterTestCert1 = Get-Item -Path Cert:\CurrentUser\My\* | Where-Object { $_ -eq $script:testcerts[0] }
                $pesterTestCert1 | Remove-Item -Force

                $foundCerts = GetSCEPmanCerts -AppServiceUrl "https://test.com" -User -ValidityThresholdDays 45

                

                $foundCerts | Should -HaveCount 0
            }

            It 'Should not find a certificate if its still valid for long enough' {
                $foundCerts = GetSCEPmanCerts -AppServiceUrl "https://test.com" -User -ValidityThresholdDays 15

                $foundCerts | Should -HaveCount 0
            }

            It 'Should find certificates matching a text filter' {
                $foundCerts = GetSCEPmanCerts -AppServiceUrl "https://test.com" -User -FilterString "Cert1"

                $foundCerts | Should -HaveCount 1
                $foundCerts[0].Subject | Should -Be $script:testcerts[0].Subject
            }

            It 'Should filter out certificates that do not match a text filter' {
                $foundCerts = GetSCEPmanCerts -AppServiceUrl "https://test.com" -User -FilterString "Cert2"

                $foundCerts | Should -HaveCount 0
            }
        }

        AfterEach {
            # Clean up test certificates
            $pesterTestCerts = Get-Item -Path Cert:\CurrentUser\My\* | Where-Object { $_.Subject.Contains("OU=PesterTest") }
            $pesterTestCerts | Remove-Item -Force
        }
    }

    Context 'RenewCertificateMTLS' {
        BeforeAll {
            $basicConstraintsCaExtension = New-Object System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension $true, $true, 0, $true
            $rootCaGenerationParameters = @{
                Subject = "CN=TestRoot,OU=PesterTest"
                KeyAlgorithm = 'ECDSA_nistP256'
                CertStoreLocation = 'Cert:\CurrentUser\My'
                NotAfter = (Get-Date).AddYears(10)
                Extension = @($basicConstraintsCaExtension)
                KeyUsage = @('CertSign', 'CRLSign', 'DigitalSignature')
            }
            $script:testroot = New-SelfSignedCertificate @rootCaGenerationParameters
            New-SelfSignedCertificate -Subject "CN=UserCertificate,OU=PesterTest" -KeyAlgorithm 'RSA' -KeyLength 512 -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddDays(20)

            function IssueCertificate($csr) {
                $csr | Should -Match "-----BEGIN (NEW )?CERTIFICATE REQUEST-----"
                $csr = $csr.Replace('NEW CERTIFICATE REQUEST', 'CERTIFICATE REQUEST')   # Replace the old-style header with the RFC-7468-compliant one

                    # Mock the EST server, this is the code for a little CA
                $IncomingRequest = [System.Security.Cryptography.X509Certificates.CertificateRequest]::LoadSigningRequestPem(
                    $csr,
                    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                    [System.Security.Cryptography.X509Certificates.CertificateRequestLoadOptions]::UnsafeLoadCertificateExtensions,
                    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
                )
                $rootPrivateKey = [System.Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPrivateKey($script:testroot)
                $rootSignatureGenerator = [System.Security.Cryptography.X509Certificates.X509SignatureGenerator ]::CreateForECDsa($rootPrivateKey)
                $issuedCert = $IncomingRequest.Create(  # For some reason, we cannot use the overload taking a certificate, as they require that the algorithm for the issuer and subject cert are the same
                    $script:testroot.Subject,  # Issuer Name
                    $rootSignatureGenerator,   # CA certificate
                    [System.DateTime]::UtcNow, # Not Before
                    [System.DateTime]::UtcNow.AddYears(1), # Not After
                    [byte[]]@(0x40,2,3,4)  # Serial number
                )
                return $issuedCert
            }
        }

        It 'Should renew a certificate' {
            $cert = Get-Item -Path Cert:\CurrentUser\My\* | Where-Object { $_.Subject.Contains("CN=UserCertificate") -and $_.Subject.Contains("OU=PesterTest") }

            Mock CreateHttpClient {
                $HttpMessageHandler | Should -Not -BeNull
                $HttpMessageHandler.ClientCertificates | Should -HaveCount 1

                $clientMock = New-MockObject -Type System.Net.Http.HttpClient -Methods @{
                    Send = { 
                        param([System.Net.Http.HttpRequestMessage]$request)

                        $request | Should -Not -BeNull
                        $request.Method | Should -Be "POST"
                        $request.RequestUri | Should -Be "https://test.com/.well-known/est/simplereenroll"
                        $request.Content | Should -Not -BeNull
                        $request.Content.Headers.ContentType | Should -Be "application/pkcs10"
                        $requestBody = $request.Content.ReadAsStringAsync().Result

                            # Mock the EST server
                        $issuedCert = IssueCertificate($requestBody)

                        $binCert = $issuedCert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
                        $b64Cert = [Convert]::ToBase64String($binCert)

                        $response = New-Object System.Net.Http.HttpResponseMessage 200
                        $response.Content = New-Object System.Net.Http.StringContent $b64Cert

                        return $response
                    }
                    Dispose = { }
                }

                return $clientMock
            }

            RenewCertificateMTLS -Certificate $cert -AppServiceUrl "https://test.com" -User

            Should -Invoke -CommandName CreateHttpClient -Exactly 1

            # Verify that the function has added a certificate to the user store
            $newCert = Get-Item -Path Cert:\CurrentUser\My\* | Where-Object { $_.Issuer.Contains("CN=TestRoot") -and $_.Issuer.Contains("OU=PesterTest") -and -not $_.Subject.Contains("CN=TestRoot")}
            $newCert | Should -Not -BeNullOrEmpty

            # Cleanup
            $newCert | Remove-Item -Force
        }

        It 'Should find the leaf certificate in a chain' {
            # Arrange
            $privateKey = [System.Security.Cryptography.RSA]::Create($Certificate.PublicKey.Key.KeySize)
            $oCertRequest = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new($Certificate.Subject, $privateKey, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $sCertRequest = $oCertRequest.CreateSigningRequestPem()
    
            $leafCertificate = IssueCertificate($sCertRequest)

            $collection = [System.Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
            $collection.Add($leafCertificate)
            $collection.Add($script:testroot)

            # Act & Assert
            IsCertificateCaOfACertificateInTheCollection -PossibleCaCertificate $leafCertificate -Certificates $collection | Should -Be $false
            IsCertificateCaOfACertificateInTheCollection -PossibleCaCertificate $script:testroot -Certificates $collection | Should -Be $true
        }

        AfterAll {
            $rootCert = Get-Item -Path Cert:\CurrentUser\My\* | Where-Object { $_.Subject.Contains("CN=TestRoot") -and $_.Subject.Contains("OU=PesterTest") }
            $rootCert | Remove-Item -Force
        }
    }
}