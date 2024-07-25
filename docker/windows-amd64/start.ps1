# start.ps1
# Check if Docker Desktop is running
$dockerDesktopProcess = Get-Process -Name "Docker Desktop" -ErrorAction SilentlyContinue

if (-not $dockerDesktopProcess) {
    Write-Host "Docker Desktop is not running. Attempting to start it..."
    Start-Process -FilePath "C:\Program Files\Docker\Docker\Docker Desktop.exe" -NoNewWindow
    # Wait for Docker Desktop to start
    Start-Sleep -Seconds 15
    Write-Host "Docker Desktop started successfully."
} else {
    Write-Host "Docker Desktop is already running."
}

Write-Host "Starting Docker containers..."
docker-compose up -d

# Function to check if all containers are running
function Test-AllContainersRunning {
    $containers = docker-compose ps --services | ForEach-Object { docker-compose ps -q $_ }
    foreach ($container in $containers) {
        $status = docker inspect -f '{{.State.Status}}' $container
        if ($status -ne "running") {
            return $false
        }
    }
    return $true
}

# Wait for containers to start (max 2 minutes)
$timeout = New-TimeSpan -Minutes 2
$stopwatch = [diagnostics.stopwatch]::StartNew()

while (-not (Test-AllContainersRunning)) {
    if ($stopwatch.Elapsed -gt $timeout) {
        Write-Host "Error: Not all containers are running after 2 minutes. Please check Docker logs for more information."
        exit 1
    }
    Write-Host "Waiting for all containers to start..."
    Start-Sleep -Seconds 10
}

Write-Host "All Docker containers are running successfully."

# Start the proxy server
Write-Host "Starting the proxy server..."
& .\start_node_server.ps1 -InstallationPath (Get-Location)

# Path to the PID file in the temp directory
$pidFilePath = Join-Path $env:TEMP "trayicon.pid"

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
$trayIconProcess = Start-Process -WindowStyle Hidden -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `".\trayicon.ps1`"" -PassThru
$trayIconProcess.Id | Out-File -FilePath $pidFilePath -Force

Write-Host "Tray icon process started."
