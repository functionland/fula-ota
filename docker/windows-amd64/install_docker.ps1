# install_docker.ps1

# Check for admin rights
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator"))
{
    Write-Warning "You do not have Administrator rights to run this script!`nPlease re-run this script as an Administrator!"
    Exit 1
}

Write-Host "Checking if WSL is installed..."
$wsl = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux

if ($wsl.State -ne "Enabled") {
    Write-Host "WSL is not installed. Attempting to install WSL..."
    try {
        Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart
        Write-Host "WSL has been successfully installed. A system restart may be required."
    } catch {
        Write-Host "Error: Failed to install WSL. Please install it manually before proceeding with Docker installation."
        exit 1
    }
}

Write-Host "Checking if Docker is installed..."

$docker = Get-Command docker -ErrorAction SilentlyContinue
if (-not $docker) {
    Write-Host "Docker not found. Installing Docker..."
    Invoke-WebRequest -Uri "https://desktop.docker.com/win/stable/Docker%20Desktop%20Installer.exe" -OutFile "$env:TEMP\DockerInstaller.exe"
    Start-Process -FilePath "$env:TEMP\DockerInstaller.exe" -ArgumentList "install", "--quiet" -Wait
    Remove-Item -Force "$env:TEMP\DockerInstaller.exe"
} else {
    Write-Host "Docker is already installed."
}
