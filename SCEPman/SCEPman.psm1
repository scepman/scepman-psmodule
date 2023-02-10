# PowerShell Module structure based on https://stackoverflow.com/a/44512990/4054714

#Get public and private function definition files.
$Private = @( Get-ChildItem -Path $PSScriptRoot\Private\*.ps1 -ErrorAction SilentlyContinue )
$Public  = @( Get-ChildItem -Path $PSScriptRoot\Public\*.ps1 -ErrorAction SilentlyContinue )

#Dot source the files
Foreach($import in @($Private + $Public))
{
    Try
    {
        . $import.fullname
    }
    Catch
    {
        Write-Error -Message "Failed to import function $($import.fullname): $_"
    }
}

Export-ModuleMember -Function Complete-SCEPmanInstallation
Export-ModuleMember -Function New-SCEPmanDeploymentSlot
Export-ModuleMember -Function New-SCEPmanClone
Export-ModuleMember -Function Register-SCEPmanCertMaster
Export-ModuleMember -Function New-IntermediateCA
Export-ModuleMember -Function Get-IntermediateCaPolicy
Export-ModuleMember -Function Set-IntermediateCaPolicy
Export-ModuleMember -Function Reset-IntermediateCaPolicy
