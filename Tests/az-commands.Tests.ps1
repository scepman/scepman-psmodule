BeforeAll {
    . $PSScriptRoot/../SCEPman/Private/az-commands.ps1
    . $PSScriptRoot/../SCEPman/Private/key-vault.ps1

    . $PSScriptRoot/test-helpers.ps1
}

Describe 'Convert-LinesToObject' {
    It 'Should convert lines to object' {
        $lines = @(
            '{',
                '   "key1": "value1",',
                '   "key2": "value2"',
            '}'
        )

        $result = Convert-LinesToObject -Lines $lines

        $result.key1 | Should -Be "value1"
        $result.key2 | Should -Be "value2"
    }
}

Describe 'CheckAzOutput' {
    It 'Should throw an error if output is invalid' {
        $exception = New-Object System.Exception("This is a test exception")
        $errorRecord = New-Object System.Management.Automation.ErrorRecord($exception, "ErrorId", [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
        $output = @(
            @($errorRecord)
        )

        { CheckAzOutput -azOutput $output -fThrowOnError $true } | Should -Throw
    }

    It 'Should not throw an error if the output is valid' {
        $output = @(
            {
                key1="value1"
                key2="value2"
            }
        )

        { CheckAzOutput -azOutput $output -fThrowOnError $true } | Should -Not -Throw
    }

}

Describe 'AzLogin' {
    BeforeAll {

    }

    It 'Should throw an error if Az not installed' {
        Mock Get-Command {
            $exception = New-Object System.Exception("CommandNotFoundException")
            $errorRecord = New-Object System.Management.Automation.ErrorRecord($exception, "ErrorId", [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
            return @($errorRecord)
        }

        { AzLogin 2>$null } | Should -Throw
    }

}


Describe 'ExecuteAzCommandRobustly' {
    BeforeAll {

    }

    It 'Should execute az command if it works' {
        Mock az {
            return 0
        }

        { ExecuteAzCommandRobustly -azCommand "az dummy" -callAzNatively } | Should -Not -Throw
    }

    It 'Should throw an error if az command fails' {
        Mock az {
            $exception = New-Object System.Exception("This is a test exception")
            $errorRecord = New-Object System.Management.Automation.ErrorRecord($exception, "ErrorId", [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
            return @($errorRecord)
        }

        { ExecuteAzCommandRobustly -azCommand "az dummy" -callAzNatively } | Should -Throw
    }

}