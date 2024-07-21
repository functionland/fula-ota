# install_docker.ps1

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
