BeforeAll {
    . $PSScriptRoot/../SCEPman/Public/Update-CertificatesViaESTSimpleReenroll.ps1
}

Describe 'Update-CertificatesViaESTSimpleReenroll' -Skip:(-not $IsWindows) {
    It 'Fails if both -user and -machine are specified' {
        { Update-CertificatesViaESTSimpleReenroll -AppServiceUrl "https://test.com" -User -Machine } | Should -Throw 'You must specify either -User or -Machine.'
    }

    It 'Fails if neither -user nor -machine are specified' {
        { Update-CertificatesViaESTSimpleReenroll -AppServiceUrl "https://test.com" } | Should -Throw 'You must specify either -User or -Machine.'
    }
    
    It 'Finds a good DotNet Runtime' -Skip {

        Mock Invoke-WebRequest {
            param($Uri, $OutFile)

            if ($Uri -ne 'https://test.com/root-ca.crt')
            {
                throw "Unexpected Uri: $Uri"
            }

            return $true
        }

        Mock Get-ChildItem {
            param($Path)

            if ($Path -ne "Cert:\LocalMachine\My")
            {
                throw "Unexpected Path: $Path"
            }

            return @(
                [PSCustomObject]@{Issuer = "CN=Test Root CA"}
            )
        }

        Mock New-TimeSpan {
            param($Days)

            if ($Days -ne 30)
            {
                throw "Unexpected Days: $Days"
            }

            return [TimeSpan]::FromDays(30)
        }

        $certs = Update-CertificatesViaESTSimpleReenroll -AppServiceUrl "https://test.com" -Machine

        $certs | Should -Be @(
            [PSCustomObject]@{Subject = "CN=Test Subject"; Issuer = "CN=Test Root CA"; Thumbprint = "Test Thumbprint"}
        )
    }
}