# Define the directories for Movies and TV Shows
$movieDirectories = @("E:\Movies (Primary)", "E:\Kids Movies (Primary)")
$tvDirectories = @("E:\TV (Primary)", "E:\Kids TV (Primary)")
#$dcwh = "Paste your discord webhook here"

# Get the current date and time
$dateTime = Get-Date -Format "yyyyMMdd_HHmmss"

# Define output directories for logs
$outputBaseDir = "C:\temp\Outputs\PlexDirectoryLog"
$movieLogDir = Join-Path -Path $outputBaseDir -ChildPath "MovieLog"
$tvLogDir = Join-Path -Path $outputBaseDir -ChildPath "TVLog"

# Ensure output directories exist
New-Item -ItemType Directory -Path $movieLogDir -Force | Out-Null
New-Item -ItemType Directory -Path $tvLogDir -Force | Out-Null

# Define changelog files
$movieChangeLog = Join-Path -Path $movieLogDir -ChildPath "ChangeLog.txt"
$tvChangeLog = Join-Path -Path $tvLogDir -ChildPath "ChangeLog.txt"

# Define Discord webhook and Signal CLI settings
$discordWebhook = "$dcwh"
$signalCli = "C:\Signal\signal-cli.exe"
$signalSender = "+1234567890"
$signalRecipients = @("+0987654321", "+1123456789")  # Add more numbers as needed

function Monitor-Directory {
    param (
        [string[]]$directories,
        [string]$logDir,
        [string]$changeLog,
        [string]$type,  # "Movie" or "TV Show"
        [bool]$includeSubfolders = $false
    )

    # Get the current list of folders (include subfolders if needed)
    $currentFolders = @()
    foreach ($directory in $directories) {
        if ($includeSubfolders) {
            # Get all subdirectories in a "Show\Season" format
            $currentFolders += Get-ChildItem -Path $directory -Directory -Recurse | 
                ForEach-Object { $_.FullName.Replace($directory, "").TrimStart("\") }
        } else {
            # Get only the top-level directories
            $currentFolders += Get-ChildItem -Path $directory -Directory | Select-Object -ExpandProperty Name
        }
    }
    $currentFolders = $currentFolders | Sort-Object -Unique

    # Find the most recent log file
    $previousFile = Get-ChildItem -Path $logDir -Filter "FolderList_*.txt" | 
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

    # If changes are detected, update logs and send notifications
    if ($addedFolders -or $removedFolders) {
        # Save new folder list
        $outputFilePath = Join-Path -Path $logDir -ChildPath "FolderList_$dateTime.txt"
        $currentFolders | Out-File -FilePath $outputFilePath

        # Append changes to the changelog file
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -Path $changeLog -Value "`n[$timestamp] $type Library Changes:"

        $discordMessage = "**$type Library Changes:**`n"
        $signalMessage = "$type Library Updates:`n"

        if ($addedFolders) {
            Add-Content -Path $changeLog -Value "Added:"
            $discordMessage += "`nAdded:`n"
            $signalMessage += "`nAdded:`n"
            $addedFolders | ForEach-Object {
                Add-Content -Path $changeLog -Value "  + $_"
                $discordMessage += "- $_`n"
                $signalMessage += "- $_`n"
            }
        }

        if ($removedFolders) {
            Add-Content -Path $changeLog -Value "Removed:"
            $discordMessage += "`nRemoved:`n"
            $signalMessage += "`nRemoved:`n"
            $removedFolders | ForEach-Object {
                Add-Content -Path $changeLog -Value "  - $_"
                $discordMessage += "- $_`n"
                $signalMessage += "- $_`n"
            }
        }

        # Send Discord Notification
        $body = @{ content = $discordMessage } | ConvertTo-Json -Depth 1
        Invoke-RestMethod -Uri $discordWebhook -Method Post -ContentType "application/json" -Body $body

        # Send Signal Notification
        $recipientArgs = $signalRecipients -join " "
        Start-Process -FilePath $signalCli -ArgumentList "send", "-m", "`"$signalMessage`"", "-a", $signalSender, $recipientArgs -NoNewWindow -Wait

        Write-Host "$type Folder list updated in: $outputFilePath"
        Write-Host "Changes logged in: $changeLog"
        Write-Host "$type Notification sent to Discord & Signal."
    } else {
        Write-Host "No changes detected for $type Library. Folder list remains unchanged."
    }
}

# Monitor Movies and TV Shows separately
Monitor-Directory -directories $movieDirectories -logDir $movieLogDir -changeLog $movieChangeLog -type "Movie"
Monitor-Directory -directories $tvDirectories -logDir $tvLogDir -changeLog $tvChangeLog -type "TV Show" -includeSubfolders $true
