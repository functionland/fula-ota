# setup.ps1

param (
    [string]$InstallationPath = "C:\Users\$env:USERNAME\fula"
)

Write-Host "Setting up the environment..."

# Set environment variables
$env:ARCH_SUPPORT = "linux/amd64"
$env:DOCKER_REPO = "functionland"
$env:DEFAULT_TAG = "release_amd64"
$env:EXTERNAL_DRIVE_PATH = "D:/fula"

# Set installation directories
$env:envDir = "$InstallationPath"
$env:fulaDir = "$InstallationPath"
$env:internalDir = "$InstallationPath\.internal"
$env:ipfsDataDir = "$InstallationPath\.internal\ipfs_data"

# Create directories if they don't exist
New-Item -ItemType Directory -Force -Path $env:envDir
New-Item -ItemType Directory -Force -Path $env:fulaDir
New-Item -ItemType Directory -Force -Path $env:internalDir
New-Item -ItemType Directory -Force -Path $env:ipfsDataDir

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

# Update .env.cluster file
Write-Host "Updating .env.cluster file..."
(Get-Content $env:envDir\.env.cluster) -replace 'IPFS_CLUSTER_PATH=.*', "IPFS_CLUSTER_PATH=$env:EXTERNAL_DRIVE_PATH\ipfs-cluster" | Set-Content $env:envDir\.env.cluster

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

# Run docker-compose
Write-Host "Running docker-compose..."
docker-compose --env-file "$env:envDir\.env" -f "$env:envDir\docker-compose.yml" -p fula up -d

Write-Host "Setup complete."
