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
    if ($PSCmdlet.ShouldProcess("$VnetName", "Creating VNET and Subnet")) {
        $null = Invoke-Az @( "network", "vnet", "create", "--resource-group", $ResourceGroupName, "--name", $VnetName, "--subnet-name", $SubnetName, "--location", $Location)
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