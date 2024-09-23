# Function to add folder to Quick Access with custom icon
function Add-ToQuickAccessWithIcon {
    param (
        [string]$path,
        [string]$iconPath,
        [string]$shortcutName
    )
    
    try {
        # Create shortcut
        $shell = New-Object -ComObject WScript.Shell
        $desktop = [System.Environment]::GetFolderPath("Desktop")
        $shortcutPath = Join-Path $desktop "$shortcutName.lnk"
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $path
        
        # Set icon
        if (Test-Path $iconPath) {
            $shortcut.IconLocation = $iconPath
        } else {
            # Default icon for network drive
            $shortcut.IconLocation = "%SystemRoot%\System32\imageres.dll,15"
        }
        
        $shortcut.Save()

        # Pin to Quick Access
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.Namespace((Split-Path $shortcutPath -Parent))
        $item = $folder.ParseName((Split-Path $shortcutPath -Leaf))
        $item.InvokeVerb("pintohome")

        Write-Host "Added $path to Quick Access successfully with custom icon as '$shortcutName'."
    }
    catch {
        Write-Host "Error adding to Quick Access: $_"
    }
}

# Function to discover device using the Go app
function Find-Device {
    $goAppPath = Join-Path $PSScriptRoot "zeroconf\zeroconf_discovery.exe"
    
    if (-not (Test-Path $goAppPath)) {
        Write-Host "Error: zeroconf_discovery.exe not found. Please ensure it's in the correct location."
        return $null
    }

    try {
        $result = & $goAppPath | ConvertFrom-Json
        return $result
    }
    catch {
        Write-Host "Error running zeroconf_discovery.exe: $_"
        return $null
    }
}

# Main script
$maxAttempts = 3
$attempt = 1
$deviceInfo = $null

while ($attempt -le $maxAttempts -and -not $deviceInfo) {
    Write-Host "Attempt $attempt of $maxAttempts to discover device..."
    $deviceInfo = Find-Device
    
    if (-not $deviceInfo) {
        $attempt++
        if ($attempt -le $maxAttempts) {
            Write-Host "Device not found. Retrying in 5 seconds..."
            Start-Sleep -Seconds 5
        }
    }
}

if (-not $deviceInfo) {
    $manualEntry = Read-Host "Device not found automatically. Would you like to enter the IP manually? (Y/N)"
    if ($manualEntry -eq "Y" -or $manualEntry -eq "y") {
        $ip = Read-Host "Please enter the IP address of your device"
        $port = Read-Host "Please enter the port number (press Enter for default 80)"
        if ([string]::IsNullOrWhiteSpace($port)) {
            $port = 80
        }
        $deviceInfo = @{
            ip = $ip
            port = [int]$port
        }
    }
    else {
        Write-Host "No device information available. Exiting."
        exit
    }
}

if ($deviceInfo) {
    $networkPath = "\\$($deviceInfo.ip)\SharedFolder"
    $iconPath = Join-Path $PSScriptRoot "fula.png"
    $shortcutName = "FxBlox"
    Write-Host "iconPath set to $iconPath"
    Write-Host "Device found at IP: $($deviceInfo.ip), Port: $($deviceInfo.port)"
    
    # Add to Quick Access with custom icon
    Add-ToQuickAccessWithIcon -path $networkPath -iconPath $iconPath -shortcutName $shortcutName
}
else {
    Write-Host "No device information available. Exiting."
}