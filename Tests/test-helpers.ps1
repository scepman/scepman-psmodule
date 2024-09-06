function CheckAzParameters($argsFromCommand, [string] $azCommandPrefix) {
    if ($argsFromCommand[0].Count -gt 1) {  # Sometimes the args are passed as an array as the first element of the args array. Sometimes they are the first array directly
        $argsFromCommand = $argsFromCommand[0]
    }

    $theCommand = $argsFromCommand -join ' '

    return $theCommand.StartsWith($azCommandPrefix)
}