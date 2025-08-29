# Copilot Instructions for SCEPman PowerShell Module

## Repository Structure

```
LICENSE
README.md
Run-ScepmanTests.ps1
.github/
    dependabot.yml
    workflows/
SCEPman/
    scepman-icon.png
    SCEPman.psd1
    SCEPman.psm1
    Private/
        az-commands.ps1
        key-vault.ps1
        permissions.ps1
        ...
    Public/
        Complete-SCEPmanInstallation.ps1
        New-SCEPmanDeploymentSlot.ps1
        New-SCEPmanClone.ps1
        Register-SCEPmanApiClient.ps1
        New-IntermediateCA.ps1
        Sync-IntuneCertificate.ps1
        ...
Tests/
    app-service.Tests.ps1
    appregistrations.Tests.ps1
    az-commands.Tests.ps1
    constants.Tests.ps1
    key-vault.Tests.ps1
    New-IntermediateCA.Tests.ps1
    New-SCEPmanClone.Tests.ps1
    Register-SCEPmanApiClient.Tests.ps1
    storage-account.Tests.ps1
    subscriptions.Tests.ps1
    test-helpers.ps1
    ...
```

## Key Module Files

- **SCEPman.psd1**: Module manifest, lists exported functions.
- **SCEPman.psm1**: Main module loader, imports all functions from `Private` and `Public` folders.
- **Private/**: Internal helper scripts (not exported).
- **Public/**: Main cmdlets for SCEPman configuration and management.

## Purpose of the Module

This module provides CMDlets to manage installations of the SCEPman, a PKI solution running on Azure, primarily Azure App Services.

## Main Cmdlets

- `Complete-SCEPmanInstallation`
- `New-SCEPmanDeploymentSlot`
- `New-SCEPmanClone`
- `Register-SCEPmanCertMaster`
- `Register-SCEPmanApiClient`
- `New-IntermediateCA`
- `Sync-IntuneCertificate`
- `Update-CertificateViaEST`

## Testing

- Tests are located in the `Tests/` folder and use Pester.
- Run all tests with `Run-ScepmanTests.ps1`.

## Useful Hints for Copilot

- Always prefer workspace functions/types over standard library.
- `Complete-SCEPmanInstallation` is the most important CMDlet of the module, as it is required for the initial setup and configuration of SCEPman.
- Use exported functions from `SCEPman.psd1` for user-facing operations.
- The module makes heavy use of the Azure CLI (az). It shouldn't be called directly, though, but through `Invoke-Az` in `Private/az-commands.ps1`, because it is more robust -- it handles false positive error messages or other known issues with az.
- For operations with specific parts of azure, there are private code files to structure the code, e.g. code related to Key Vault is in `Private/key-vault.ps1`.
- Constants should be defined in a dedicated module (e.g. `Private/constants.ps1`) for better maintainability.
- `Public/Update-CertificateViaEST.ps1` and `Private/estclient.ps1` are deprecated, as there is now another module SCEPmanClient dedicated to client-side operations. For backwards compatibility, the old cmdlets will still work.
- When suggesting code, reference existing cmdlets and follow the repo's PowerShell style.
- Add file and symbol links in markdown for navigation.
- For tests, use helpers from `Tests/test-helpers.ps1`. The `CheckAzParameters` function is very helpful when mocking calls to az and must be used instead of checking the parameters otherwise.

## Documentation

- See [README.md](README.md) for usage and links to official docs.
- License: [MIT License](LICENSE)