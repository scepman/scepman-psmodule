# Some hard-coded definitions
$MSGraphAppId = "00000003-0000-0000-c000-000000000000"
$MSGraphUserReadPermission = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"

$MSGraphDirectoryReadAllPermission = "7ab1d382-f21e-4acd-a863-ba3e13f7da61"
$MSGraphDeviceManagementReadPermission = "2f51be20-0bb4-4fed-bf7b-db946066c75e"

# "0000000a-0000-0000-c000-000000000000" # Service Principal App Id of Intune, not required here
$IntuneAppId = "c161e42e-d4df-4a3d-9b42-e7a3c31f59d4" # Well-known App ID of the Intune API
$IntuneSCEPChallengePermission = "39d724e8-6a34-4930-9a36-364082c35716"

$azureADAppNameForSCEPman = 'SCEPman-api' #Azure AD app name for SCEPman
$azureADAppNameForCertMaster = 'SCEPman-CertMaster' #Azure AD app name for certmaster

# JSON defining App Role that CertMaster uses to authenticate against SCEPman
$ScepmanManifest = '[{
        \"allowedMemberTypes\": [
          \"Application\"
        ],
        \"description\": \"Request certificates via the raw CSR API\",
        \"displayName\": \"CSR Requesters\",
        \"isEnabled\": \"true\",
        \"value\": \"CSR.Request\"
    }]'.Replace("`r", [String]::Empty).Replace("`n", [String]::Empty)

# JSON defining App Role that User can have to when authenticating against CertMaster
$CertmasterManifest = '[{
    \"allowedMemberTypes\": [
      \"User\"
    ],
    \"description\": \"Full access to all SCEPman CertMaster functions like requesting and managing certificates\",
    \"displayName\": \"Full Admin\",
    \"isEnabled\": \"true\",
    \"value\": \"Admin.Full\"
}]'.Replace("`r", [String]::Empty).Replace("`n", [String]::Empty)