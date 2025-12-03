BeforeAll {
    . $PSScriptRoot/../SCEPman/Private/constants.ps1
    . $PSScriptRoot/../SCEPman/Private/az-commands.ps1
    . $PSScriptRoot/../SCEPman/Private/appregistrations.ps1
    . $PSScriptRoot/../SCEPman/Public/Register-SCEPmanCertMaster.ps1

    . $PSScriptRoot/test-helpers.ps1
}

Describe "Register-SCEPmanCertMaster" {

    Context "Protocol Prefix Handling" {
        BeforeAll {
            # Mock the Azure CLI and authentication functions
            Mock az {
                return '{"azure-cli": "2.60.0"}'
            } -ParameterFilter { $args[0] -eq 'version' }

            Mock AzLogin {
                return @{ homeTenantId = "test-tenant-id" }
            }

            Mock CreateCertMasterAppRegistration {
                return @{ appId = "12345678-aad6-4711-82a9-0123456789ab" }
            }
        }

        It "Preserves URLs with https:// prefix" {
            # Act
            Register-SCEPmanCertMaster -CertMasterBaseURL "https://scepman-cm.azurewebsites.net"

            # Assert
            Should -Invoke CreateCertMasterAppRegistration -Exactly 1 -ParameterFilter {
                $CertMasterBaseURLs[0] -eq "https://scepman-cm.azurewebsites.net"
            }
        }

        It "Preserves URLs with http:// prefix" {
            # Act
            Register-SCEPmanCertMaster -CertMasterBaseURL "http://scepman-cm.azurewebsites.net"

            # Assert
            Should -Invoke CreateCertMasterAppRegistration -Exactly 1 -ParameterFilter {
                $CertMasterBaseURLs[0] -eq "http://scepman-cm.azurewebsites.net"
            }
        }

        It "Automatically adds https:// prefix when missing" {
            # Act
            Register-SCEPmanCertMaster -CertMasterBaseURL "scepman-cm.azurewebsites.net"

            # Assert
            Should -Invoke CreateCertMasterAppRegistration -Exactly 1 -ParameterFilter {
                $CertMasterBaseURLs[0] -eq "https://scepman-cm.azurewebsites.net"
            }
        }

        It "Adds https:// prefix to localhost" {
            # Act
            Register-SCEPmanCertMaster -CertMasterBaseURL "localhost:8080"

            # Assert
            Should -Invoke CreateCertMasterAppRegistration -Exactly 1 -ParameterFilter {
                $CertMasterBaseURLs[0] -eq "https://localhost:8080"
            }
        }

        It "Adds https:// prefix to any input without protocol" {
            # Act
            Register-SCEPmanCertMaster -CertMasterBaseURL "example.com"

            # Assert
            Should -Invoke CreateCertMasterAppRegistration -Exactly 1 -ParameterFilter {
                $CertMasterBaseURLs[0] -eq "https://example.com"
            }
        }
    }

    Context "Full Integration" {
        BeforeAll {
            # Mock the Azure CLI and authentication functions
            Mock az {
                return '{"azure-cli": "2.60.0"}'
            } -ParameterFilter { $args[0] -eq 'version' }

            Mock AzLogin {
                return @{ homeTenantId = "test-tenant-id" }
            }

            Mock CreateCertMasterAppRegistration {
                return @{ appId = "12345678-aad6-4711-82a9-0123456789ab" }
            }
        }

        It "Successfully registers CertMaster with custom app name" {
            # Act
            Register-SCEPmanCertMaster -CertMasterBaseURL "https://scepman-cm.azurewebsites.net" -AzureADAppNameForCertMaster "CustomCertMaster"

            # Assert
            Should -Invoke CreateCertMasterAppRegistration -Exactly 1 -ParameterFilter {
                $AzureADAppNameForCertMaster -eq "CustomCertMaster" -and
                $CertMasterBaseURLs[0] -eq "https://scepman-cm.azurewebsites.net"
            }
        }

        It "Handles CreateCertMasterAppRegistration failure" {
            # Arrange - Override the mock to return null
            Mock CreateCertMasterAppRegistration {
                return $null
            }

            # Act & Assert
            { Register-SCEPmanCertMaster -CertMasterBaseURL "https://scepman-cm.azurewebsites.net" } | Should -Throw "*We are unable to register the CertMaster app*"
        }
    }
}