# start_node_server.ps1
param (
    [string]$InstallationPath
)

# Start the proxy server using the packaged executable
$executablePath = Join-Path $InstallationPath "server\make\squirrel.windows\x64\fula-webui-1.0.0 Setup.exe"
$nodeProcess = Start-Process "cmd.exe" -ArgumentList "/c `"$executablePath`"" -WorkingDirectory $InstallationPath -NoNewWindow -PassThru

# Path to the PID file in the temp directory
$pidFilePath = Join-Path $env:TEMP "node_server.pid"
$nodeProcess.Id | Out-File -FilePath $pidFilePath -Force

Write-Host "Proxy server started with PID $($nodeProcess.Id)"
