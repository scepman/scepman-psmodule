BeforeAll {
    . $PSScriptRoot/test-helpers.ps1

    # Mock output functions to prevent console noise
    Mock Write-Error { }
    Mock Write-Information { }
    Mock Write-Warning { }
    Mock Write-Verbose { }

    # Now load the functions to test
    . $PSScriptRoot/../SCEPman/Private/active-directory.ps1
    . $PSScriptRoot/../SCEPman/Public/New-SCEPmanADPrincipal.ps1

    Function Get-ADDomain {
        return @{
            DNSRoot = "DC=contoso,DC=local"
            NetBIOSName = "CONTOSO"
            ComputersContainer = "CN=Computers,DC=contoso,DC=local"
        }
    }

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

    # Return a valid certificate
    Mock Invoke-WebRequest {
        $cert = New-InMemoryCertificate
        $derBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)

        return @{
            Content = $derBytes
        }
    }

    $PrincipalName = 'STEPman'
    $AppServiceUrl = 'scepman.contoso.com'
    $SCEPmanAppServiceName = 'app-scepman-contoso'
    $OU = 'OU=test,DC=contoso,DC=local'

    $ValidPath = [System.IO.Path]::GetTempFileName()
}

Describe "New-SCEPmanADPrincipal Prerequisites" {
    BeforeEach {
        # Assume working conditions
        Mock Get-Module { return $true } -ParameterFilter { $Name -eq 'ActiveDirectory' }
        Mock Import-Module { return $true } -ParameterFilter { $Name -eq 'ActiveDirectory' }
        Mock Get-Command { return $true }
    }

    It "Handles missing ActiveDirectory module" {
        Mock Get-Module { return $null } -ParameterFilter { $Name -eq 'ActiveDirectory' }
        { New-SCEPmanADPrincipal -Name $PrincipalName -AppServiceUrl $AppServiceUrl } | Should -Throw "*ActiveDirectory module not found*"
    }

    It "Handles failing ActiveDirectory module import" {
        Mock Import-Module { throw "Import failed" } -ParameterFilter { $Name -eq 'ActiveDirectory' }
        { New-SCEPmanADPrincipal -Name $PrincipalName -AppServiceUrl $AppServiceUrl } | Should -Throw "*Import failed*"
    }

    It "Handles missing ktpass executable" {
        Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'ktpass' }
        { New-SCEPmanADPrincipal -Name $PrincipalName -AppServiceUrl $AppServiceUrl } | Should -Throw "*ktpass.exe not found*"
    }

    It "Handles missing az CLI when AppServiceName is provided" {
        Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'az' }
        { New-SCEPmanADPrincipal -Name $PrincipalName -AppServiceUrl $AppServiceUrl -SCEPmanAppServiceName $SCEPmanAppServiceName } | Should -Throw "*az CLI not found*"
    }

    It "Handles missing System.Security assembly" {
        Mock Add-Type { throw "Add-Type failed" } -ParameterFilter { $AssemblyName -like '*System.Security*' }
        { New-SCEPmanADPrincipal -Name $PrincipalName -AppServiceUrl $AppServiceUrl } | Should -Throw "*Add-Type failed*"
    }

    It "Handles failure to retrieve AD domain information" {
        Mock Get-ADDomain { throw "Get-ADDomain failed" }
        { New-SCEPmanADPrincipal -Name $PrincipalName -AppServiceUrl $AppServiceUrl } | Should -Throw "*Get-ADDomain failed*"
    }

    It "Handles failure to retrieve AD domain information from given domain" {
        Mock Get-ADDomain { throw "Get-ADDomain failed" }
        { New-SCEPmanADPrincipal -Name $PrincipalName -AppServiceUrl $AppServiceUrl -Domain 'nonexistent.domain' } | Should -Throw "*Get-ADDomain failed*"
    }

    It "Handles missing domain information" {
        Mock Get-ADDomain { return @{} }
        { New-SCEPmanADPrincipal -Name $PrincipalName -AppServiceUrl $AppServiceUrl } | Should -Throw "*Could not retrieve domain information*"
    }

    It "Handles failing CA certificate download" {
        Mock Invoke-WebRequest { throw "Download failed" }
        { New-SCEPmanADPrincipal -Name $PrincipalName -AppServiceUrl $AppServiceUrl -OU $OU } | Should -Throw "*Download failed*"
    }

    It "Handles failing CA certificate import" {
        Mock Get-Item { throw "Get-Item failed" }
        { New-SCEPmanADPrincipal -Name $PrincipalName -AppServiceUrl $AppServiceUrl -OU $OU -CaCertificate $ValidPath } | Should -Throw "*Could not load DER certificate*"
    }
}

Describe "New-SCEPmanADPrincipal Processing" {
    BeforeEach {
        Mock Get-Module { return $true } -ParameterFilter { $Name -eq 'ActiveDirectory' }
        Mock Import-Module { } -ParameterFilter { $Name -eq 'ActiveDirectory' }
        Mock Get-Command { return $true }

        Mock New-SCEPmanADObject { return @{
            Name = 'TestComputer'
            DistinguishedName = 'CN=TestComputer,OU=test,DC=contoso,DC=local'
        }}

        Mock New-SCEPmanADKeyTab { return ,(1..10) }
    }

    It "Handles failing AD computer account creation" {
        Mock New-SCEPmanADObject { return $null }

        $result = New-SCEPmanADPrincipal -Name $PrincipalName -AppServiceUrl $AppServiceUrl -OU $OU -Quiet
        $result | Should -Be $null
    }

    It "Handles failing keytab creation" {
        Mock New-SCEPmanADKeyTab { return $null }

        $result = New-SCEPmanADPrincipal -Name $PrincipalName -AppServiceUrl $AppServiceUrl -OU $OU -Quiet
        $result | Should -Be $null
    }

    It "Handles failing keytab encryption" {
        Mock Protect-SCEPmanKeyTab { return $null }

        $result = New-SCEPmanADPrincipal -Name $PrincipalName -AppServiceUrl $AppServiceUrl -OU $OU -Quiet
        $result | Should -Be $null
    }

    It "Handles successful procedure" {
        $result = New-SCEPmanADPrincipal -Name $PrincipalName -AppServiceUrl $AppServiceUrl -OU $OU -Quiet

        $result | Should -Not -Be $null
        $result | Should -BeOfType [string]
    }
}