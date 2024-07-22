# start_node_server.ps1
param (
    [string]$InstallationPath
)

# Start the proxy server using the packaged executable
$executablePath = Join-Path $InstallationPath "fula-webui.exe"
$nodeProcess = Start-Process "cmd.exe" -ArgumentList "/c $executablePath" -WorkingDirectory $InstallationPath -NoNewWindow -PassThru
$nodeProcess.Id | Out-File (Join-Path $InstallationPath "node_server.pid")

Write-Host "Proxy server started with PID $($nodeProcess.Id)"
