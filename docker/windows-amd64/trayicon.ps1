# trayicon.ps1

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

# Restart item
$restartItem = New-Object System.Windows.Forms.MenuItem
$restartItem.Text = "Restart"
$restartItem.Add_Click({
    Write-Host "Restarting Docker containers..."
    Start-Process -NoNewWindow -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File .\start.ps1"
})

# Status item
$statusItem = New-Object System.Windows.Forms.MenuItem
$statusItem.Text = "Status"
$statusItem.Add_Click({
    Write-Host "Checking Docker containers status..."
    Start-Process -NoNewWindow -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File .\status.ps1"
})

# Exit item
$exitItem = New-Object System.Windows.Forms.MenuItem
$exitItem.Text = "Exit"
$exitItem.Add_Click({
    Write-Host "Stopping and exiting..."
    Remove-Item -Path $pidFilePath -Force
    Start-Process -NoNewWindow -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File .\stop.ps1"
    $trayIcon.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

# Add items to context menu
$contextMenu.MenuItems.Add($restartItem)
$contextMenu.MenuItems.Add($statusItem)
$contextMenu.MenuItems.Add($exitItem)

# Assign context menu to tray icon
$trayIcon.ContextMenu = $contextMenu

# Handle left-click event
$trayIcon.add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Start-Process "http://localhost:7000/webui"
    }
})

# Keep the script running to maintain the tray icon
[System.Windows.Forms.Application]::Run()

# Clean up the PID file when the script exits
Remove-Item -Path $pidFilePath -Force
