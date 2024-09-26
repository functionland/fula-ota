# trayicon.ps1

# Set the working directory to the script's location
Set-Location (Split-Path -Parent $MyInvocation.MyCommand.Path)

# Start transcript for logging
Start-Transcript -Path "$env:TEMP\trayicon_log.txt" -Append

# Path to the PID file
$pidFilePath = Join-Path (Get-Location) "trayicon.pid"

# Write the current process ID to the PID file
$PID | Out-File $pidFilePath

# Load the required assembly for creating tray icons
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Path to the custom icon
$iconPath = Join-Path (Get-Location) "trayicon.ico"

# Create a new tray icon
$trayIcon = New-Object System.Windows.Forms.NotifyIcon
$trayIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($iconPath)
$trayIcon.Visible = $true
$trayIcon.Text = "Fula Application"

# Create context menu with items
$contextMenu = New-Object System.Windows.Forms.ContextMenu

# Function to execute scripts with error handling
function Execute-Script {
    param (
        [string]$scriptName,
        [string]$description
    )
    try {
        Write-Host "${description}..."
        $scriptPath = Join-Path $PSScriptRoot $scriptName
        if (Test-Path $scriptPath) {
            Start-Process -NoNewWindow -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
        } else {
            Write-Host "Script not found: $scriptPath"
        }
    } catch {
        Write-Host "Error executing ${description}: ${_}"
    }
}

# Restart item
$restartItem = New-Object System.Windows.Forms.MenuItem
$restartItem.Text = "Restart"
$restartItem.Add_Click({ Execute-Script "start.ps1" "Restarting Docker containers" })

# Status item
$statusItem = New-Object System.Windows.Forms.MenuItem
$statusItem.Text = "Status"
$statusItem.Add_Click({ Execute-Script "status.ps1" "Checking Docker containers status" })

# Exit item
$exitItem = New-Object System.Windows.Forms.MenuItem
$exitItem.Text = "Exit"
$exitItem.Add_Click({
    Write-Host "Stopping and exiting..."
    Remove-Item -Path $pidFilePath -Force
    Execute-Script "stop.ps1" "Stopping Docker containers"
    $trayIcon.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

# Load FxBlox item
$fxBloxItem = New-Object System.Windows.Forms.MenuItem
$fxBloxItem.Text = "Blox Link"
$fxBloxItem.Add_Click({ Execute-Script "fxblox.ps1" "Loading FxBlox" })

# Add items to context menu
$contextMenu.MenuItems.Add($fxBloxItem)
$contextMenu.MenuItems.Add($restartItem)
$contextMenu.MenuItems.Add($statusItem)
$contextMenu.MenuItems.Add($exitItem)

# Assign context menu to tray icon
$trayIcon.ContextMenu = $contextMenu

# Handle left-click event
$trayIcon.add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Start-Process "http://localhost:7000/webui/"
    }
})

# Keep the script running to maintain the tray icon
[System.Windows.Forms.Application]::Run()

# Clean up the PID file when the script exits
Remove-Item -Path $pidFilePath -Force

# Stop transcript
Stop-Transcript