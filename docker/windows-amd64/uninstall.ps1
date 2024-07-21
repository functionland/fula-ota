param (
    [string]$InstallationPath
)

Write-Host "Uninstalling Fula and cleaning up Docker..."

# Stop all running services
Write-Host "Stopping all services..."
& "$InstallationPath\stop.ps1"

# Remove Docker containers and volumes
Write-Host "Stopping Docker containers..."
docker-compose -f "$InstallationPath\docker-compose.yml" down -v --rmi all

Write-Host "Uninstallation complete."
