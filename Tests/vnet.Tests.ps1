BeforeAll {
    . $PSScriptRoot/../SCEPman/Private/az-commands.ps1
    . $PSScriptRoot/../SCEPman/Private/vnet.ps1

    . $PSScriptRoot/test-helpers.ps1
}

Describe 'VNet' {
    Context 'When creating a new Vnet' {
        BeforeEach {
            Mock az {
              $LASTEXITCODE = 0
              return Get-Content -Path "./Tests/Data/vnet.json"
            } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix 'network vnet create' }

            Mock az {
                $LASTEXITCODE = 0
                return Get-Content -Path "./Tests/Data/subnet.json"
            } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix 'network vnet subnet update' }

            Mock az {
              throw "Unexpected parameter for az: $args (with array values $($args[0]) [$($args[0].GetType())], $($args[1]), ... -- #$($args.Count) in total)"
            }

            Function AreTwoRegionsInTheSameGeo {
                return $true
            }
        }

        It 'Should create a Vnet with the correct parameters' {
            # Arrange
            $ResourceGroupName = 'TestResourceGroup'
            $VnetName = 'TestVnet'
            $SubnetName = 'TestSubnet'
            $Location = 'EastUS'
            $StorageAccountLocation = 'WestUS'

            # Act
            $result = New-Vnet -ResourceGroupName $ResourceGroupName -VnetName $VnetName -SubnetName $SubnetName -Location $Location -StorageAccountLocation $StorageAccountLocation

            # Assert
            $result | Should -Not -BeNullOrEmpty
            $result | Should -BeOfType [PSCustomObject]
            
        }
    }

    Context 'Helper Functions' {
        $arrayOfTestInputs = 1..50 | ForEach-Object { @{ randomizationInput = "test-input-$_" } }

        It 'Should generate a valid IP range prefix for randomized input <randomizationInput>' -ForEach $arrayOfTestInputs {
            # Act
            $ipRangePrefix = RandomizeIpRangePrefix -inputString $randomizationInput

            $bytes = $ipRangePrefix -replace '^10\.(\d{1,3})\.(\d{1,3})\.$', '$1 $2'
            $secondByte, $thirdByte = $bytes -split ' '

            # Convert to integers
            $secondByte = [int]$secondByte
            $thirdByte = [int]$thirdByte

            # Assert
            $ipRangePrefix | Should -Match '^10\.\d{1,3}\.\d{1,3}\.$'

            $secondByte | Should -BeGreaterThan 0
            $secondByte | Should -BeLessOrEqual 254
            $thirdByte | Should -BeGreaterOrEqual 1
            $thirdByte | Should -BeLessOrEqual 254
        }
    }
}