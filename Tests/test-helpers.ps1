function CheckAzParameters($argsFromCommand, [string] $azCommandPrefix = $null, [string] $azCommandMidfix = $null, [string] $azCommandSuffix = $null) {
    if ($argsFromCommand[0].Count -gt 1) {  # Sometimes the args are passed as an array as the first element of the args array. Sometimes they are the first array directly
        $argsFromCommand = $argsFromCommand[0]
    }

    $theCommand = $argsFromCommand -join ' '

    if ($azCommandPrefix -ne $null -and -not $theCommand.StartsWith($azCommandPrefix)) {
        return $false
    }

    if ($azCommandMidfix -ne $null -and -not $theCommand.Contains($azCommandMidfix)) {
        return $false
    }

    if ($azCommandSuffix -ne $null -and -not $theCommand.EndsWith($azCommandSuffix)) {
        return $false
    }

    return $true
}