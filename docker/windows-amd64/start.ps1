# start.ps1
Write-Host "Starting Docker containers..."
docker-compose up -d

# Start the proxy server
Write-Host "Starting the proxy server..."
& .\start_node_server.ps1 -InstallationPath (Get-Location)

# Path to the PID file
$pidFilePath = Join-Path (Get-Location) "trayicon.pid"

# Check if the tray icon process is already running
if (Test-Path $pidFilePath) {
    $existingPid = Get-Content $pidFilePath
    if (Get-Process -Id $existingPid -ErrorAction SilentlyContinue) {
        Write-Host "Tray icon process is already running."
        exit
    } else {
        Remove-Item $pidFilePath -Force
    }
}

# Start tray icon in a hidden PowerShell window
$trayIconProcess = Start-Process -WindowStyle Hidden -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File .\trayicon.ps1" -PassThru
$trayIconProcess.Id | Out-File $pidFilePath

Write-Host "Tray icon process started."
