# build_msix.ps1
param (
    [switch]$NoServerBuild
)

$ErrorActionPreference = "Stop"

# Set variables
$projectRoot = $PSScriptRoot
$msixFolder = Join-Path $projectRoot "MSIX\"
$outputPath = Join-Path $projectRoot "FulaSetup.msix"
$fxsupportPath = Join-Path $projectRoot "..\fxsupport\linux"
$serverDir = Join-Path $projectRoot "server"
$vfsDir = Join-Path $msixFolder "VFS\AppVPackageDrive\Fula\"

if (-not $NoServerBuild) {
    # Run npm commands
    Set-Location $serverDir
    & npm install
    & npm run build
    & npm run make
} else {
    Write-Host "Skipping server build..."
}
Set-Location $projectRoot

# Create the MSIX folder structure
New-Item -ItemType Directory -Force -Path (Join-Path $vfsDir "server\out\make\squirrel.windows\x64") | Out-Null

# Function to find the Windows SDK path
function Find-WindowsSDKPath {
    # Method 1: Check the registry
    $sdkPath = Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SDKs\Windows\v10.0" -Name "InstallationFolder" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty InstallationFolder

    if ($sdkPath -and (Test-Path $sdkPath)) {
        return $sdkPath
    }

    # Method 2: Check common installation paths
    $commonPaths = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin\10.0.19041.0",
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin\10.0.18362.0",
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin\10.0.17763.0"
    )

    foreach ($path in $commonPaths) {
        if (Test-Path $path) {
            return (Split-Path $path -Parent)
        }
    }

    # Method 3: Search for makeappx.exe
    $makeappxPath = Get-Command makeappx.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
    if ($makeappxPath) {
        return (Split-Path (Split-Path $makeappxPath -Parent) -Parent)
    }

    return $null
}

# Find the Windows SDK path
$sdkPath = Find-WindowsSDKPath

if (-not $sdkPath) {
    Write-Error "Windows SDK not found. Please ensure the Windows SDK is installed."
    exit 1
}

$makeappxPath = Join-Path $sdkPath "bin\x64\makeappx.exe"
$signtoolPath = Join-Path $sdkPath "bin\x64\signTool.exe"

if (-not (Test-Path $makeappxPath)) {
    Write-Error "makeappx.exe not found. Please ensure the Windows SDK is installed correctly."
    exit 1
}

if (-not (Test-Path $signtoolPath)) {
    Write-Error "signtool.exe not found. Please ensure the Windows SDK is installed correctly."
    exit 1
}

# Compile Fula.exe
Write-Host "Compiling Fula.exe..."
$cscPath = $null
$frameworkPaths = @(
    "${env:SystemRoot}\Microsoft.NET\Framework\v4.0.30319",
    "${env:SystemRoot}\Microsoft.NET\Framework64\v4.0.30319",
    "${env:ProgramFiles(x86)}\MSBuild\14.0\Bin",
    "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Community\MSBuild\Current\Bin",
    "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\BuildTools\MSBuild\Current\Bin"
)

foreach ($path in $frameworkPaths) {
    $possiblePath = Join-Path $path "csc.exe"
    if (Test-Path $possiblePath) {
        $cscPath = $possiblePath
        break
    }
}

if (-not $cscPath) {
    Write-Error "csc.exe not found. Please ensure .NET Framework is installed and in your PATH."
    exit 1
}

$fulaCSPath = Join-Path $projectRoot "Fula.cs"
$fulaExePath = Join-Path $msixFolder "Fula.exe"

& $cscPath /out:$fulaExePath $fulaCSPath

if (-not (Test-Path $fulaExePath)) {
    Write-Error "Failed to compile Fula.exe"
    exit 1
}

# Copy only the necessary files
Copy-Item -Path (Join-Path $fxsupportPath "kubo") -Destination $vfsDir -Recurse -Force
Copy-Item -Path (Join-Path $fxsupportPath "ipfs-cluster") -Destination $vfsDir -Recurse -Force
Copy-Item -Path (Join-Path $fxsupportPath ".env.cluster") -Destination $vfsDir -Force
Copy-Item -Path (Join-Path $fxsupportPath ".env.gofula") -Destination $vfsDir -Force
Copy-Item -Path (Join-Path $projectRoot "*.ps1") -Destination $vfsDir -Force
Copy-Item -Path (Join-Path $projectRoot "*.ico") -Destination $vfsDir -Force
Copy-Item -Path (Join-Path $projectRoot "docker-compose.yml") -Destination $vfsDir -Force

# Copy only the built application
$builtAppPath = Join-Path $serverDir "out\make\squirrel.windows\x64\fula-webui-1.0.0 Setup.exe"
Copy-Item -Path $builtAppPath -Destination (Join-Path $vfsDir "server\out\make\squirrel.windows\x64") -Force

# Build the MSIX package
Write-Host "Building MSIX package..."
& $makeappxPath pack /d $msixFolder /p $outputPath

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to create MSIX package."
    exit 1
}

Write-Host "MSIX package created successfully: $outputPath"

# Sign the MSIX package
Write-Host "Signing MSIX package..."
& $signtoolPath sign /a /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 $outputPath

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to sign MSIX package."
    exit 1
}

Write-Host "MSIX package signed successfully."

# Clean up
Remove-Item $fulaExePath -Force

Write-Host "Build process completed successfully."
