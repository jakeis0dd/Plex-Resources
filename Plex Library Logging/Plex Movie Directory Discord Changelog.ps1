# Define the directories to monitor
# For multiple directories use this format: $directories = @("C:\Movies", "C:\Kids Movies")
$directories = @("C:\your plex directory path goes here")

# Get the current date and time
$dateTime = Get-Date -Format "yyyyMMdd_HHmmss"

# Define output paths
$outputDirectory = "C:\Wherever you would like to log your changes locally"
$outputFilePath = Join-Path -Path $outputDirectory -ChildPath "FolderList_$dateTime.txt"
$changeLogPath = Join-Path -Path $outputDirectory -ChildPath "ChangeLog.txt"

# Discord Webhook URL
$webhookUrl = "Discord whebhook URL goes here"

# Get the current list of movie folders from both directories
$currentFolders = @()
foreach ($directory in $directories) {
    $currentFolders += Get-ChildItem -Path $directory -Directory | Select-Object -ExpandProperty Name
}

# Remove duplicates (if a folder exists in both locations)
$currentFolders = $currentFolders | Sort-Object -Unique

# Find the most recent folder list
$previousFile = Get-ChildItem -Path $outputDirectory -Filter "FolderList_*.txt" | 
    Sort-Object LastWriteTime -Descending | 
    Select-Object -First 1

# Read the previous folder list if it exists
if ($previousFile) {
    $previousFolders = Get-Content $previousFile.FullName
} else {
    $previousFolders = @()
}

# Compare previous and current folder lists
$addedFolders = $currentFolders | Where-Object { $_ -notin $previousFolders }
$removedFolders = $previousFolders | Where-Object { $_ -notin $currentFolders }

# If changes are detected, update the output file, log changes, and send a Discord notification
if ($addedFolders -or $removedFolders) {
    # Write new folder list with a timestamped filename
    $currentFolders | Out-File -FilePath $outputFilePath

    # Append changes to the changelog file
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $changeLogPath -Value "`n[$timestamp] Changes detected:"

    $discordMessage = "`n**Movie Library Changes:**`n"

    if ($addedFolders) {
        Add-Content -Path $changeLogPath -Value "Added:"
        $discordMessage += "`n**Added:**`n"
        $addedFolders | ForEach-Object {
            Add-Content -Path $changeLogPath -Value "  + $_"
            $discordMessage += ":white_check_mark: $_`n"
        }
    }

    if ($removedFolders) {
        Add-Content -Path $changeLogPath -Value "Removed:"
        $discordMessage += "`n**Removed:**`n"
        $removedFolders | ForEach-Object {
            Add-Content -Path $changeLogPath -Value "  - $_"
            $discordMessage += ":x: $_`n"
        }
    }

    # Define the payload for the Discord webhook
    $body = @{
        content = $discordMessage
    } | ConvertTo-Json -Depth 1

    # Post the message to Discord
    Invoke-RestMethod -Uri $webhookUrl -Method Post -ContentType "application/json" -Body $body

    Write-Host "Folder list updated in: $outputFilePath"
    Write-Host "Changes logged in: $changeLogPath"
    Write-Host "Notification sent to Discord."
} else {
    Write-Host "No changes detected. Folder list remains unchanged."
}
