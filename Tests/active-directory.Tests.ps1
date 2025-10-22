BeforeAll {
    . $PSScriptRoot/test-helpers.ps1

    # Mock output functions to prevent console noise
    Mock Write-Error { }
    Mock Write-Information { }
    Mock Write-Warning { }
    Mock Write-Verbose { }

    # Now load the functions to test
    . $PSScriptRoot/../SCEPman/Private/active-directory.ps1
}

Describe 'New-SCEPmanADObject' {
    BeforeAll {
        # Define a custom exception to simulate AD not found errors
        class ADIdentityNotFoundException : System.Exception {
            ADIdentityNotFoundException([string]$message) : base($message) {}
        }

        Function Get-ADComputer { }
        Function New-ADComputer { }

        $Name = "TestComputer"
        $OU = "OU=Computers,DC=contoso,DC=local"
    }
    BeforeEach {
        # Reset any state before each test
        $script:CallCount = 0

        Mock Get-AdComputer {
            # Increase before as we throw on first call
            $script:CallCount++

            if ($script:CallCount -eq 1) {
                throw [ADIdentityNotFoundException]::new("This is not the Computer you are looking for")
            } elseif ($script:CallCount -eq 2) {
                return [PSCustomObject] @{
                    Name = $Name
                }
            }
        }

        Mock New-ADComputer { return $null }
    }

    It "Creates a new AD computer object successfully" {
        $result = New-SCEPmanADObject -Name $Name -OU $OU

        # Assert
        $result | Should -Not -BeNullOrEmpty
        $result.Name | Should -Be "TestComputer"
        # Spare the
        Should -Invoke New-ADComputer -Exactly 1
    }

    It "Handles existing AD computer object gracefully" {
        Mock Get-AdComputer {
            return [PSCustomObject] @{
                Name = "ExistingComputer"
            }
        }

        { New-SCEPmanADObject -Name $Name -OU $OU } | Should -Throw "*A computer account with the name * already exists*"
    }

    It "Handles errors during AD computer creation" {
        Mock New-ADComputer { throw "Simulated creation error" }

        { New-SCEPmanADObject -Name $Name -OU $OU } | Should -Throw "*An error occurred while creating account*"
    }

    It "Handles errors during initial AD computer validation" {
        Mock Get-AdComputer {
            throw "Simulated validation error"
        }

        { New-SCEPmanADObject -Name $Name -OU $OU } | Should -Throw "*An error occurred while checking for existing account*"
    }

    It "Handles not finding account after creation" {
        Mock Get-AdComputer {
            throw [ADIdentityNotFoundException]::new("Computer not found")
        }

        { New-SCEPmanADObject -Name $Name -OU $OU } | Should -Throw "*An error occurred while validating account*"
    }

    It "Handles unexpected errors during existence check" {
        Mock Get-AdComputer {
            $script:CallCount++

            if ($script:CallCount -eq 1) {
                # Throw as expected on first call
                throw [ADIdentityNotFoundException]::new("This is not the Computer you are looking for")
            } elseif ($script:CallCount -eq 2) {
                throw "Generic on second call"
            }
        }

        { New-SCEPmanADObject -Name $Name -OU $OU } | Should -Throw "*An error occurred while validating account*"
    }
}

Describe 'Get-TempFilePath' {
    It "Generates a valid temporary file path" {
        $tempFilePath = Get-TempFilePath

        # Assert
        $tempFilePath | Should -Not -BeNullOrEmpty
        Test-Path -Path $tempFilePath | Should -Be $true
    }
}

Describe 'Read-FileBytes' {
    BeforeEach {
        # Create a temporary file with known content
        $script:tempFilePath = [System.IO.Path]::GetTempFileName()
        [System.IO.File]::WriteAllBytes($script:tempFilePath, [byte[]](10,20,30,40,50))
    }

    AfterEach {
        # Clean up the temporary file
        Remove-Item -Path $script:tempFilePath -ErrorAction SilentlyContinue
    }

    It "Reads bytes from a file correctly" {
        $bytes = Read-FileBytes -Path $script:tempFilePath

        # Assert
        $bytes | Should -Not -BeNullOrEmpty
        $bytes.Length | Should -Be 5
        $bytes | Should -BeExactly ([byte[]](10,20,30,40,50))
    }
}

Describe 'New-SCEPmanADKeyTab' {
    BeforeAll {
        Class MockStandardOutput {
            [string] $Message
            MockStandardOutput($message) {
                $this.Message = $message
            }

            [string] ReadToEnd() {
                return $this.Message
            }
        }

        Class MockStandardError {
            [string] $Message
            MockStandardError($message) {
                $this.Message = $message
            }

            [string] ReadToEnd() {
                return $this.Message
            }
        }

        Class MockProcess {
            [object] $StartInfo
            [int] $ExitCode
            [MockStandardOutput] $StandardOutput
            [MockStandardError] $StandardError

            # Constructor
            MockProcess($ExitCode) {
                $this.StartInfo = $null
                $this.ExitCode = $ExitCode

                $this.StandardOutput = [MockStandardOutput]::new("ktpass stdout message")

                switch ($ExitCode) {
                    0 { $this.StandardError = [MockStandardError]::new("No Error occurred") }
                    1 { $this.StandardError = [MockStandardError]::new("Failed to set property 'servicePrincipalName'") }
                    2 { $this.StandardError = [MockStandardError]::new("Failed to set property 'userPrincipalName'")}
                    3 { throw "Simulated exception during ktpass execution" }
                    default {
                        $this.StandardError = [MockStandardError]::new("Generic error message")
                    }
                }
            }

            [void] Start() { }
            [void] WaitForExit() { }
        }
    }

    BeforeEach {
        # Mock the ProcessStartInfo constructor
        Mock New-Object {
            if ($TypeName -eq 'System.Diagnostics.ProcessStartInfo') {
                return [PSCustomObject]@{
                    FileName = $null
                    RedirectStandardError = $null
                    RedirectStandardOutput = $null
                    UseShellExecute = $null
                    Arguments = $null
                }
            }
            return $null
        } -ParameterFilter { $TypeName -eq 'System.Diagnostics.ProcessStartInfo' }

        # Mock the Process object
        Mock New-Object {
            return [MockProcess]::new(0)
        } -ParameterFilter { $TypeName -eq 'System.Diagnostics.Process' }

        # Mock file operations
        Mock Test-Path { return $true }
        Mock Remove-Item { }

        $DownlevelLogonName = "CONTOSO\stepman$"
        $ServicePrincipalName = "host/stepman.contoso.com@CONTOSO.LOCAL"
    }

    It "Creates a new AD keytab successfully" {
        Mock Read-FileBytes {
            return [byte[]](1,2,3,4,5)
        }

        $result = New-SCEPmanADKeyTab -DownlevelLogonName $DownlevelLogonName -ServicePrincipalName $ServicePrincipalName

        # Assert
        $result | Should -Not -BeNullOrEmpty
    }

    It "Handles ktpass failure due to servicePrincipalName error" {
        Mock New-Object {
            return [MockProcess]::new(1)
        } -ParameterFilter { $TypeName -eq 'System.Diagnostics.Process' }

        { New-SCEPmanADKeyTab -DownlevelLogonName $DownlevelLogonName -ServicePrincipalName $ServicePrincipalName } | Should -Throw "*ServicePrincipalName could not be set successfully*"
    }

    It "Handles ktpass failure due to userPrincipalName error" {
        Mock New-Object {
            return [MockProcess]::new(2)
        } -ParameterFilter { $TypeName -eq 'System.Diagnostics.Process' }

        { New-SCEPmanADKeyTab -DownlevelLogonName $DownlevelLogonName -ServicePrincipalName $ServicePrincipalName } | Should -Throw "*UserPrincipalName could not be set successfully*"
    }

    It "Handles ktpass failure due to exception being thrown" {
        Mock New-Object {
            return [MockProcess]::new(3)
        } -ParameterFilter { $TypeName -eq 'System.Diagnostics.Process' }

        { New-SCEPmanADKeyTab -DownlevelLogonName $DownlevelLogonName -ServicePrincipalName $ServicePrincipalName } | Should -Throw "*An error occurred while creating keytab*"
    }

    It "Handles ktpass failure due to generic error message" {
        Mock New-Object {
            return [MockProcess]::new(11)
        } -ParameterFilter { $TypeName -eq 'System.Diagnostics.Process' }

        { New-SCEPmanADKeyTab -DownlevelLogonName $DownlevelLogonName -ServicePrincipalName $ServicePrincipalName } | Should -Throw "*ktpass failed with exit code*"
    }

    It "Handles ShowKtpassOutput parameter correctly" {
        Mock Read-FileBytes {
            return [byte[]](1,2,3,4,5)
        }

        $result = New-SCEPmanADKeyTab -DownlevelLogonName $DownlevelLogonName -ServicePrincipalName $ServicePrincipalName -ShowKtpassOutput

        # Assert
        $result | Should -Not -BeNullOrEmpty
    }

    It "Handles invalid ktpass path scenario" {
        Mock Test-Path { return $false }

        $result = New-SCEPmanADKeyTab -DownlevelLogonName $DownlevelLogonName -ServicePrincipalName $ServicePrincipalName

        # Assert
        $result | Should -BeNullOrEmpty
    }
}

Describe 'Protect-SCEPmanKeyTab' {
    BeforeAll {
        Function New-InMemoryCertificate {
            $rsa = [System.Security.Cryptography.RSA]::Create(1024)

            $csr = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest(
                "CN=InMemoryCert_SCEPman_Test",
                $rsa,
                [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
            )

            $notBefore = [DateTime]::UtcNow
            $notAfter = $notBefore.AddYears(1)
            return $csr.CreateSelfSigned($notBefore, $notAfter)
        }

        $RecipientCert = New-InMemoryCertificate
    }

    It "Protects keytab data successfully" {
        $keyTabData = [byte[]](1,2,3,4,5)

        $result = Protect-SCEPmanKeyTab -KeyTabData $keyTabData -RecipientCert $RecipientCert

        # Assert
        $result | Should -Not -BeNullOrEmpty
        # Is Base64 string
        $result | Should -Match '^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{3}=|[A-Za-z0-9+/]{2}==)?$'
    }
}