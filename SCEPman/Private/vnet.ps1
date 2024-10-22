function New-Vnet {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param (
        [Parameter(Mandatory=$true)] [string]$ResourceGroupName,
        [Parameter(Mandatory=$true)] [string]$VnetName,
        [Parameter(Mandatory=$true)] [string]$SubnetName,
        [Parameter(Mandatory=$true)] [string]$Location,
        [Parameter(Mandatory=$true)] [string]$StorageAccountLocation
    )

    Write-Information "Creating Vnet $VnetName in Resource Group $ResourceGroupName with subnet $SubnetName in location $Location"

    # Concatenate inputs to create a unique string
    $inputString = "$ResourceGroupName$VnetName$SubnetName$Location$StorageAccountLocation"

    $IpRangePrefix = RandomizeIpRangePrefix -inputString $inputString

    Write-Information "Using IP range prefix $IpRangePrefix"

    if ($PSCmdlet.ShouldProcess("$VnetName", "Creating VNET and Subnet with IP range $IpRangePrefix.0/24")) {
        $null = Invoke-Az @( "network", "vnet", "create", "--resource-group", $ResourceGroupName, "--name", $VnetName, "--subnet-name", $SubnetName, "--location", $Location, "--address-prefixes", "['$IpRangePrefix.0/24']", "--subnet-prefixes", "['$IpRangePrefix.32/27']" )
    }
    if(AreTwoRegionsInTheSameGeo -Region1 $Location -Region2 $StorageAccountLocation) {
        $StorageAccountServiceEndpoint = 'Microsoft.Storage'
    } else {
        $StorageAccountServiceEndpoint = 'Microsoft.Storage.Global'
    }

    if ($PSCmdlet.ShouldProcess("$SubnetName", "Creating Service Endpoint $StorageAccountServiceEndpoint in Subnet")) {
        $subnetJson = Invoke-Az @( "network", "vnet", "subnet", "update", "--resource-group", $ResourceGroupName, "--vnet-name", $VnetName, "--name", $SubnetName, "--service-endpoints", "['Microsoft.KeyVault', '$StorageAccountServiceEndpoint']", "--delegations", "Microsoft.Web/serverFarms" )
    }
    return Convert-LinesToObject -lines $subnetJson
}


function RandomizeIpRangePrefix ([string]$inputString) {
    <#
    .SYNOPSIS
    Generates a randomized three byte IP range prefix based on the input string.

    .DESCRIPTION
    This function takes an input string, generates a SHA256 hash from it, and uses the first two bytes of the hash to create a pseudo-randomized IP range prefix. The second and third bytes of the IP address are derived from the hash and are ensured to be within the valid range for IP addresses (1-254).

    .PARAMETER inputString
    The input string used to generate the hash. This string should be unique to ensure a unique IP range prefix.

    .OUTPUTS
    [string]
    Returns a string representing the IP range prefix in the format "10.x.x." where x is a value between 1 and 254.

    .EXAMPLE
    $ipRangePrefix = RandomizeIpRangePrefix -inputString "abcxyz"
    Write-Output $ipRangePrefix
    # Output: "10.123.45" (example output, actual values will vary)
    #>

   # Generate a hash from the input string
   $hashBytes = [System.Security.Cryptography.HashAlgorithm]::Create("SHA256").ComputeHash([System.Text.Encoding]::UTF8.GetBytes($inputString))

   # Extract bytes and ensure they are within the valid range for IP addresses (1-254)
   $secondByte = [Math]::Min([Math]::Max($hashBytes[0], 1), 254)
   $thirdByte = [Math]::Min([Math]::Max($hashBytes[1], 1), 254)

   # Form the IP range prefix
   return "10.$secondByte.$thirdByte"
}