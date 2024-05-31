function New-Vnet ($ResourceGroupName, $VnetName, $SubnetName) {
    Write-Information "Creating Vnet $VnetName in Resource Group $ResourceGroupName with subnet $SubnetName"
    $null = Invoke-Az @( "network", "vnet", "create", "--resource-group", $ResourceGroupName, "--name", $VnetName, "--subnet-name", $SubnetName)
    $subnetJson = Invoke-Az @( "network", "vnet", "subnet", "update", "--resource-group", $ResourceGroupName, "--vnet-name", $VnetName, "--name", $SubnetName, "--service-endpoints", "['Microsoft.KeyVault', 'Microsoft.Storage']", "--delegations", "Microsoft.Web/serverFarms" )
    return Convert-LinesToObject -lines $subnetJson
}