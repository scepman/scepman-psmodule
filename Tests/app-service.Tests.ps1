BeforeAll {
    . $PSScriptRoot/../SCEPman/Private/constants.ps1
    . $PSScriptRoot/../SCEPman/Private/az-commands.ps1
    . $PSScriptRoot/../SCEPman/Private/app-service.ps1
}

Describe 'App Service' {
    It 'Finds a good DotNet Runtime' {

        Mock Invoke-Az {
            param($azCommand)

            if ($azCommand[0] -ne 'webapp' -or $azCommand[1] -ne 'list-runtimes' -or $azCommand[2] -ne '--os' -or $azCommand[3] -ne 'windows')
            {
                throw "Unexpected command: $azCommand"
            }

            return @(
                "dotnet:8",
                "dotnet:7",
                "dotnet:6",
                "ASPNET:V4.8",
                "ASPNET:V3.5",
                "NODE:20LTS",
                "NODE:18LTS",
                "NODE:16LTS",
                "java:1.8:Java SE:8",
                "java:11:Java SE:11",
                "java:17:Java SE:17",
                "java:1.8:TOMCAT:10.1",
                "java:11:TOMCAT:10.1",
                "java:17:TOMCAT:10.1",
                "java:1.8:TOMCAT:10.0",
                "java:11:TOMCAT:10.0",
                "java:17:TOMCAT:10.0",
                "java:1.8:TOMCAT:9.0",
                "java:11:TOMCAT:9.0",
                "java:17:TOMCAT:9.0",
                "java:1.8:TOMCAT:8.5",
                "java:11:TOMCAT:8.5",
                "java:17:TOMCAT:8.5"
            )
        }

        $runtime = SelectBestDotNetRuntime

        $runtime | Should -Be "dotnet:8"
    }
}