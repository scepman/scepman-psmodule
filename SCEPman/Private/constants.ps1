# Some hard-coded definitions
New-Variable -Name "MSGraphAppId" -Value "00000003-0000-0000-c000-000000000000" -Scope "Script" -Option ReadOnly
#$MSGraphAppId = "00000003-0000-0000-c000-000000000000"
New-Variable -Name "MSGraphUserReadPermission" -Value "e1fe6dd8-ba31-4d61-89e7-88639da4683d" -Scope "Script" -Option ReadOnly

New-Variable -Name "MSGraphDirectoryReadAllPermission" -Value "7ab1d382-f21e-4acd-a863-ba3e13f7da61" -Scope "Script" -Option ReadOnly
New-Variable -Name "MSGraphDeviceManagementReadPermission" -Value "2f51be20-0bb4-4fed-bf7b-db946066c75e" -Scope "Script" -Option ReadOnly
New-Variable -Name "MSGraphIdentityRiskyUserReadPermission" -Value "dc5007c0-2d7d-4c42-879c-2dab87571379" -Scope "Script" -Option ReadOnly # IdentityRiskyUser.Read.All

# "0000000a-0000-0000-c000-000000000000" # Service Principal App Id of Intune, not required here
New-Variable -Name "IntuneAppId" -Value "c161e42e-d4df-4a3d-9b42-e7a3c31f59d4" -Scope "Script" -Option ReadOnly # Well-known App ID of the Intune API
New-Variable -Name "IntuneSCEPChallengePermission" -Value "39d724e8-6a34-4930-9a36-364082c35716" -Scope "Script" -Option ReadOnly

# JSON defining App Role that CertMaster uses to authenticate against SCEPman
New-Variable -Name "ScepmanManifest" -Scope "Script" -Option ReadOnly -Value '[{
        \"allowedMemberTypes\": [
          \"Application\"
        ],
        \"description\": \"Request certificates via the raw CSR API\",
        \"displayName\": \"CSR Requesters\",
        \"isEnabled\": \"true\",
        \"value\": \"CSR.Request\"
    }]'.Replace("`r", [String]::Empty).Replace("`n", [String]::Empty)

# JSON defining App Role that User can have to when authenticating against CertMaster
New-Variable -Name "CertmasterManifest" -Scope "Script" -Option ReadOnly -Value '[{
    \"allowedMemberTypes\": [
      \"User\"
    ],
    \"description\": \"Full access to all SCEPman CertMaster functions like requesting and managing certificates\",
    \"displayName\": \"Full Admin\",
    \"isEnabled\": \"true\",
    \"value\": \"Admin.Full\"
}]'.Replace("`r", [String]::Empty).Replace("`n", [String]::Empty)

New-Variable -Name "Artifacts_Certmaster" -Scope "Script" -Option ReadOnly -Value @{
  prod =  "https://raw.githubusercontent.com/scepman/install/master/dist-certmaster/CertMaster-Artifacts.zip"
  beta = "https://raw.githubusercontent.com/scepman/install/master/dist-certmaster/CertMaster-Artifacts-Beta.zip"
  internal = "https://raw.githubusercontent.com/scepman/install/master/dist-certmaster/CertMaster-Artifacts-Intern.zip"
}

New-Variable -Name "Artifacts_Scepman" -Scope "Script" -Option ReadOnly -Value @{
  prod =  "https://raw.githubusercontent.com/scepman/install/master/dist/Artifacts.zip"
  beta = "https://raw.githubusercontent.com/scepman/install/master/dist/Artifacts-Beta.zip"
  internal = "https://raw.githubusercontent.com/scepman/install/master/dist/Artifacts-Intern.zip"
}