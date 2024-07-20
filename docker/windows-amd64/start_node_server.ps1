# start_node_server.ps1
param (
    [string]$InstallationPath
)

# Start the proxy server
$nodeProcess = Start-Process "cmd.exe" -ArgumentList "/c node server/app.js" -WorkingDirectory $InstallationPath -NoNewWindow -PassThru
$nodeProcess.Id | Out-File (Join-Path $InstallationPath "node_server.pid")

Write-Host "Proxy server started with PID $($nodeProcess.Id)"
