$settingsPath = Join-Path $PSScriptRoot "settings.json"
$dockerComposePath = Join-Path $PSScriptRoot "docker-compose.yml"

# Prompt for external drive selection
$drives = Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 }
$externalDrive = $drives | Out-GridView -Title "Select External Drive" -OutputMode Single | Select-Object -ExpandProperty DeviceID

# Save settings
$settings = @{
    ExternalDrive = $externalDrive
}
$settings | ConvertTo-Json | Set-Content $settingsPath

# Replace placeholders in docker-compose.yml
$dockerComposeContent = Get-Content $dockerComposePath -Raw
$dockerComposeContent = $dockerComposeContent -replace '\${env:InstallationPath}', $PSScriptRoot.Replace('\', '/')
$dockerComposeContent = $dockerComposeContent -replace '\${env:envDir}', $PSScriptRoot.Replace('\', '/')
$dockerComposeContent = $dockerComposeContent -replace '\${env:ExternalDrive}', $externalDrive.Replace('\', '/')
$dockerComposeContent | Set-Content $dockerComposePath

# Run setup.ps1
& "$PSScriptRoot\setup.ps1" -InstallationPath $PSScriptRoot -ExternalDrive $externalDrive
