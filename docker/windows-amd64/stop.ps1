# stop.ps1
Write-Host "Stopping Docker containers..."
docker-compose down

# Path to the PID file
$pidFilePath = Join-Path (Get-Location) "trayicon.pid"

# Stop the tray icon process using the PID file
if (Test-Path $pidFilePath) {
    $existingPid = Get-Content $pidFilePath
    if (Get-Process -Id $existingPid -ErrorAction SilentlyContinue) {
        Stop-Process -Id $existingPid -ErrorAction SilentlyContinue  # Suppress errors
        Write-Host "Tray icon process stopped successfully."
        Remove-Item $pidFilePath -Force
    } else {
        Write-Host "Tray icon process not found."
        Remove-Item $pidFilePath -Force
    }
} else {
    Write-Host "Tray icon process PID file not found."
}
