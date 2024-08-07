# setup.ps1

param (
    [string]$InstallationPath,
    [string]$ExternalDrive
)

Write-Host "Setting up the environment..."

# Set environment variables
$env:ARCH_SUPPORT = "linux/amd64"
$env:DOCKER_REPO = "functionland"
$env:DEFAULT_TAG = "release_amd64"
$env:EXTERNAL_DRIVE_PATH = "$ExternalDrive\uniondrive"

# Set installation directories
$env:envDir = "$InstallationPath"
Write-Host "Installation Path: $InstallationPath"
Write-Host "Environment Directory: $env:envDir"
$env:fulaDir = "$InstallationPath"
$env:internalDir = "$InstallationPath\.internal"
$env:ipfsDataDir = "$InstallationPath\.internal\ipfs_data"

# Create directories if they don't exist
New-Item -ItemType Directory -Force -Path $env:envDir
New-Item -ItemType Directory -Force -Path $env:fulaDir
New-Item -ItemType Directory -Force -Path $env:internalDir
New-Item -ItemType Directory -Force -Path $env:ipfsDataDir

New-Item -ItemType File -Force -Path "$env:ipfsDataDir\version"
New-Item -ItemType File -Force -Path "$env:ipfsDataDir\datastore_spec"

Write-Host "Setting network parameters..."
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "TcpWindowSize" -Value 2500000
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "TcpTimedWaitDelay" -Value 30


# Resolve the shortcut path to the actual target path
$WshShell = New-Object -ComObject WScript.Shell
$ShortcutPath = Join-Path (Get-Location) "linux.lnk"
$TargetPath = $WshShell.CreateShortcut($ShortcutPath).TargetPath

# Copy necessary files
Write-Host "Copying necessary files..."
Copy-Item -Force "$TargetPath\.env.cluster" $env:envDir\.env.cluster
Copy-Item -Force "$TargetPath\.env.gofula" $env:envDir\.env.gofula
Copy-Item -Recurse -Force "$TargetPath\kubo" $env:fulaDir\kubo\
Copy-Item -Recurse -Force "$TargetPath\ipfs-cluster" $env:fulaDir\ipfs-cluster\

if (!(Test-Path "$env:ipfsDataDir\config")) {
    Copy-Item -Force "$env:fulaDir\kubo\config" "$env:ipfsDataDir\config"
}
if (!(Test-Path "$env:internalDir\ipfs_config")) {
    Copy-Item -Force "$env:fulaDir\kubo\config" "$env:internalDir\ipfs_config"
}

# Convert Windows path to Unix path for Docker
function Convert-PathToUnix ($path) {
    return $path -replace '\\', '/' -replace 'C:', '/c'
}

# Create .env file
Write-Host "Creating .env file..."
$envContent = @"
GO_FULA=index.docker.io/$env:DOCKER_REPO/go-fula:$env:DEFAULT_TAG
FX_SUPPROT=index.docker.io/$env:DOCKER_REPO/fxsupport:$env:DEFAULT_TAG
SUGARFUNGE_NODE=index.docker.io/$env:DOCKER_REPO/node:$env:DEFAULT_TAG
IPFS_CLUSTER=index.docker.io/$env:DOCKER_REPO/ipfs-cluster:$env:DEFAULT_TAG
CURRENT_USER=$env:USERNAME
EXTERNAL_DRIVE_PATH=$env:EXTERNAL_DRIVE_PATH
ENV_CLUSTER_PATH=$env:envDir\.env.cluster
"@
$envContent | Set-Content $env:envDir\.env

# Replace placeholders in docker-compose.yml with Unix-style paths
Write-Host "Replacing paths in docker-compose.yml..."
$dockerComposePath = Join-Path (Get-Location) "docker-compose.yml"
$unixInstallationPath = Convert-PathToUnix $InstallationPath
$unixEnvDirPath = Convert-PathToUnix $env:envDir
(Get-Content $dockerComposePath) -replace '\${env:InstallationPath}', $unixInstallationPath -replace '\${env:envDir}', $unixEnvDirPath | Set-Content "$env:envDir\docker-compose.yml"

# Open port 4000
Write-Host "Opening port 4000..."
Start-Process "netsh" -ArgumentList "int ipv4 add excludedportrange protocol=tcp startport=4000 numberofports=1 store=persistent" -Verb RunAs

Write-Host "Opening port 8181..."
Start-Process "netsh" -ArgumentList "int ipv4 add excludedportrange protocol=tcp startport=8181 numberofports=1 store=persistent" -Verb RunAs

Write-Host "Opening port 9094..."
Start-Process "netsh" -ArgumentList "int ipv4 add excludedportrange protocol=tcp startport=9094 numberofports=1 store=persistent" -Verb RunAs

Write-Host "Opening port 7000..."
Start-Process "netsh" -ArgumentList "int ipv4 add excludedportrange protocol=tcp startport=7000 numberofports=1 store=persistent" -Verb RunAs

# Run docker-compose
Write-Host "Running docker-compose..."
docker-compose --env-file "$env:envDir\.env" -f "$env:envDir\docker-compose.yml" -p fula up -d

Write-Host "Setup complete."
exit 0
