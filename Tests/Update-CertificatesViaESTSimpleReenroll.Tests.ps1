BeforeAll {
    . $PSScriptRoot/../SCEPman/Public/Update-CertificatesViaESTSimpleReenroll.ps1
}

Describe 'SimpleReenrollmentTools' -Skip:(-not $IsWindows) {

    Context 'Update-CertificatesViaESTSimpleReenroll' {
        It 'Fails if both -user and -machine are specified' {
            { Update-CertificatesViaESTSimpleReenroll -AppServiceUrl "https://test.com" -User -Machine } | Should -Throw 'You must specify either -User or -Machine.'
        }

        It 'Fails if neither -user nor -machine are specified' {
            { Update-CertificatesViaESTSimpleReenroll -AppServiceUrl "https://test.com" } | Should -Throw 'You must specify either -User or -Machine.'
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
            }

            Update-CertificatesViaESTSimpleReenroll -AppServiceUrl "https://test.com" -User

            Should -Invoke -CommandName RenewCertificateMTLS -Exactly 2
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
            $script:testroot = New-SelfSignedCertificate -Subject "CN=TestRoot,OU=PesterTest" -KeyAlgorithm 'RSA' -KeyLength 512 -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddYears(10)
        }

        It 'Should renew a certificate' -Skip {
            $cert = Get-Item -Path Cert:\CurrentUser\My\* | Where-Object { $_.Subject.Contains("CN=TestRoot") -and $_.Subject.Contains("OU=PesterTest") }

            Mock Invoke-WebRequest {    # Mock the EST server, this is the code for a little CA
                param($Uri, $Method, $Headers, $Body)

                $Body | Should -Match "-----BEGIN CERTIFICATE REQUEST-----"
                $Uri | Should -Be "https://test.com/.well-known/est/simplereenroll"
                $Method | Should -Be "POST"
                $Headers | Should -ContainKey "Content-Type"
                $Headers["Content-Type"] | Should -Be "application/pkcs10"

                $IncomingRequest = [System.Security.Cryptography.X509Certificates.CertificateRequest]::LoadSigningRequestPem(
                    $Body,
                    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                    [System.Security.Cryptography.X509Certificates.CertificateRequestLoadOptions]::UnsafeLoadCertificateExtensions,
                    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
                    )
                $issuedCert = $IncomingRequest.Create(
                    $script:testroot,   # CA certificate
                    [System.DateTime]::UtcNow, # Not Before
                    [System.DateTime]::UtcNow.AddYears(1), # Not After
                    [byte[]]@(0x40,2,3,4)  # Serial number
                )
                $binCert = $issuedCert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)

                return @{
                    StatusCode = 200
                    Content = $binCert
                }
            }

            Mock CreateHttpClient {
                $HttpClientHandler | Should -Not -BeNull
                $HttpClientHandler.ClientCertificates | Should -HaveCount 1

                $clientMock = New-MockObject -Type System.Net.Http.HttpClient -Methods @{
                    Send = { 
                        $request. | Should -Be "POST https://test.com/.well-known/est/simplereenroll HTTP/1.1`r`nContent-Type: application/pkcs10`r`n`r`n-----BEGIN CERTIFICATE REQUEST-----"


                        $response = New-Object System.Net.Http.HttpResponseMessage 200


                        return $response
                    }
                }
            }

            RenewCertificateMTLS -Certificate $cert -AppServiceUrl "https://test.com" -User

            Should -Invoke -CommandName Invoke-WebRequest -Exactly 1

            # Verify that the function has added a certificate to the user store
            $newCert = Get-Item -Path Cert:\CurrentUser\My\* | Where-Object { $_.Issuer.Contains("CN=TestRoot") -and $_.Issuer.Contains("OU=PesterTest") -and -not $_.Subject.Contains("CN=TestRoot")}
            $newCert | Should -Not -BeNullOrEmpty

            # Cleanup
            $newCert | Remove-Item -Force
        }

        AfterAll {
            $rootCert = Get-Item -Path Cert:\CurrentUser\My\* | Where-Object { $_.Subject.Contains("CN=TestRoot") -and $_.Subject.Contains("OU=PesterTest") }
            $rootCert | Remove-Item -Force
        }
    }
}