# stop.ps1
Write-Host "Stopping Docker containers..."
docker-compose down

# Path to the PID file for the Node.js server
$nodePidFilePath = Join-Path (Get-Location) "node_server.pid"

# Stop the proxy server using the PID file
if (Test-Path $nodePidFilePath) {
    $nodePid = Get-Content $nodePidFilePath
    if (Get-Process -Id $nodePid -ErrorAction SilentlyContinue) {
        Stop-Process -Id $nodePid -ErrorAction SilentlyContinue  # Suppress errors
        Write-Host "Proxy server stopped successfully."
        Remove-Item $nodePidFilePath -Force
    } else {
        Write-Host "Proxy server process not found."
        Remove-Item $nodePidFilePath -Force
    }
} else {
    Write-Host "Proxy server PID file not found."
}

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
