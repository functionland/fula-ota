param (
    [string]$InstallationPath
)

Write-Host "Uninstalling Fula and cleaning up Docker..."

# Stop and remove Docker containers and volumes
Write-Host "Stopping Docker containers..."
docker-compose -f "$InstallationPath\docker-compose.yml" down -v --rmi all

# Remove Docker
Write-Host "Uninstalling Docker..."
Start-Process "powershell" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"Uninstall-Package -Name docker -Force`"" -Verb RunAs

Write-Host "Uninstallation complete."
