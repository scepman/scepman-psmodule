function New-Vnet ($ResourceGroupName, $VnetName, $SubnetName, $Location, $StorageAccountLocation) {
    Write-Information "Creating Vnet $VnetName in Resource Group $ResourceGroupName with subnet $SubnetName in location $Location"
    $null = Invoke-Az @( "network", "vnet", "create", "--resource-group", $ResourceGroupName, "--name", $VnetName, "--subnet-name", $SubnetName, "--location", $Location)
    if(AreTwoRegionsInTheSameGeo -Region1 $Location -Region2 $StorageAccountLocation) {
        $StorageAccountServiceEndpoint = 'Microsoft.Storage'
    } else {
        $StorageAccountServiceEndpoint = 'Microsoft.Storage.Global'
    }

    $subnetJson = Invoke-Az @( "network", "vnet", "subnet", "update", "--resource-group", $ResourceGroupName, "--vnet-name", $VnetName, "--name", $SubnetName, "--service-endpoints", "['Microsoft.KeyVault', '$StorageAccountServiceEndpoint']", "--delegations", "Microsoft.Web/serverFarms" )
    return Convert-LinesToObject -lines $subnetJson
}