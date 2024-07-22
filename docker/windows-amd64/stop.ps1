# stop.ps1
Write-Host "Stopping Docker containers..."
docker-compose down

# Path to the PID file in the temp directory for the Node.js server
$nodePidFilePath = Join-Path $env:TEMP "node_server.pid"

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

# Terminate any process named "fula-webui"
$fulaWebuiProcesses = Get-Process -Name "fula-webui" -ErrorAction SilentlyContinue
if ($fulaWebuiProcesses) {
    $fulaWebuiProcesses | ForEach-Object {
        Stop-Process -Id $_.Id -ErrorAction SilentlyContinue  # Suppress errors
        Write-Host "Terminated process 'fula-webui' with PID $($_.Id)."
    }
} else {
    Write-Host "No 'fula-webui' processes found."
}

# Path to the PID file in the temp directory for the tray icon
$pidFilePath = Join-Path $env:TEMP "trayicon.pid"

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
