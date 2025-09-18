BeforeAll {
    . $PSScriptRoot/../SCEPman/Private/constants.ps1
    . $PSScriptRoot/../SCEPman/Private/az-commands.ps1
    . $PSScriptRoot/../SCEPman/Private/appregistrations.ps1
    . $PSScriptRoot/../SCEPman/Public/Register-SCEPmanCertMaster.ps1

    . $PSScriptRoot/test-helpers.ps1
}

Describe "Register-SCEPmanCertMaster" {
    
    Context "URL Validation" {
        BeforeAll {
            # Create a test function with the same validation as the actual function
            $TestValidation = {
                param(
                    [Parameter(Mandatory=$true)]
                    [ValidateScript({
                        # Ensure URL has a protocol prefix, add https:// if missing
                        if ($_ -match '^https?://') {
                            return $true
                        } elseif ($_ -match '^[a-zA-Z0-9][a-zA-Z0-9\.\-]*[a-zA-Z0-9]\.[a-zA-Z]{2,}(:\d+)?(/.*)?$' -or $_ -match '^localhost(:\d+)?(/.*)?$') {
                            # Looks like a domain name or localhost without protocol, we'll add https://
                            return $true
                        } else {
                            throw "CertMasterBaseURL must be a valid URL with protocol (http:// or https://) or a valid domain name."
                        }
                    })]
                    [string]$CertMasterBaseURL
                )
                return $CertMasterBaseURL
            }
        }
        
        It "Accepts URLs with https:// prefix" {
            { & $TestValidation -CertMasterBaseURL "https://scepman-cm.azurewebsites.net" } | Should -Not -Throw
        }

        It "Accepts URLs with http:// prefix" {
            { & $TestValidation -CertMasterBaseURL "http://scepman-cm.azurewebsites.net" } | Should -Not -Throw
        }

        It "Accepts domain names without protocol" {
            { & $TestValidation -CertMasterBaseURL "scepman-cm.azurewebsites.net" } | Should -Not -Throw
        }

        It "Accepts localhost with port without protocol" {
            { & $TestValidation -CertMasterBaseURL "localhost:8080" } | Should -Not -Throw
        }

        It "Rejects invalid URLs" {
            { & $TestValidation -CertMasterBaseURL "not-a-valid-url" } | Should -Throw "*CertMasterBaseURL must be a valid URL*"
        }

        It "Rejects empty URLs" {
            { & $TestValidation -CertMasterBaseURL "" } | Should -Throw "*CertMasterBaseURL must be a valid URL*"
        }

        It "Rejects URLs with invalid protocols" {
            { & $TestValidation -CertMasterBaseURL "ftp://scepman-cm.azurewebsites.net" } | Should -Throw "*CertMasterBaseURL must be a valid URL*"
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

        It "Successfully registers CertMaster with valid URL" {
            # Act
            Register-SCEPmanCertMaster -CertMasterBaseURL "https://scepman-cm.azurewebsites.net"

            # Assert
            Should -Invoke CreateCertMasterAppRegistration -Exactly 1 -ParameterFilter { 
                $AzureADAppNameForCertMaster -eq "SCEPman-CertMaster" -and 
                $CertMasterBaseURLs[0] -eq "https://scepman-cm.azurewebsites.net" 
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

        It "Automatically adds https:// prefix when missing" {
            # Act
            Register-SCEPmanCertMaster -CertMasterBaseURL "scepman-cm.azurewebsites.net"

            # Assert
            Should -Invoke CreateCertMasterAppRegistration -Exactly 1 -ParameterFilter { 
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