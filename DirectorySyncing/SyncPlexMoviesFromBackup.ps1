# PROD_SyncPlexMoviesFromBackup.ps1
# Copies recent missing movies from:
#   D:\Movies.Backup
# to:
#   E:\Movies (Primary)
#
# Plex scans separately every 15 minutes.
# This script does NOT call the Plex API.
#
# After successful moves, it re-scans the destination folder.
# If moved items are confirmed present, it closes File Explorer windows
# open to the source drive and ejects the PlexBackup external drive.

# ----------------------------
# CONFIG
# ----------------------------

$SourceFolder = "D:\Movies.Backup"
$DestinationFolder = "E:\Movies (Primary)"
$StagingFolder = "E:\_PlexMovieImportStaging"

$LookbackDays = 30

$LogFile = "C:\temp\Outputs\PlexSyncLog\Sync-PlexMoviesFromBackup.log"

# External drive info for eject
$SourceDriveLetter = "D"
$SourceDriveLabel = "PlexBackup"
$EjectSourceDriveAfterSuccessfulMove = $true

$ExcludedNames = @(
    ".fseventsd",
    ".Spotlight-V100",
    ".Trashes",
    ".parts",
    "_Cleanup"
)

# ----------------------------
# PREP LOGGING
# ----------------------------

$LogDirectory = Split-Path -Path $LogFile -Parent

if (-not (Test-Path $LogDirectory)) {
    New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
}

function Write-Log {
    param ([string]$Message)

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogFile -Value "$timestamp - $Message"
}

function Normalize-Name {
    param ([string]$Name)

    return $Name.Trim().ToLowerInvariant()
}

function Get-TopLevelDestinationIndex {
    param ([string]$Path)

    $Index = @{}

    Get-ChildItem -Path $Path -Force |
        ForEach-Object {
            $NormalizedName = Normalize-Name $_.Name
            $Index[$NormalizedName] = $_.FullName
        }

    return $Index
}

function Close-ExplorerWindowsForDrive {
    param ([string]$DriveLetter)

    $DriveRoot = "$DriveLetter`:\"

    try {
        Write-Log "Checking for File Explorer windows open to $DriveRoot"

        $Shell = New-Object -ComObject Shell.Application
        $Windows = @($Shell.Windows())

        foreach ($Window in $Windows) {
            try {
                $LocationUrl = $Window.LocationURL

                if ([string]::IsNullOrWhiteSpace($LocationUrl)) {
                    continue
                }

                $LocationPath = [System.Uri]::UnescapeDataString($LocationUrl)

                # Convert file:///D:/Movies.Backup style URLs to path-like text.
                $LocationPath = $LocationPath -replace "^file:///", ""
                $LocationPath = $LocationPath -replace "/", "\"

                if ($LocationPath -like "$DriveLetter`:*") {
                    Write-Log "Closing File Explorer window open to source drive: $LocationPath"
                    $Window.Quit()
                }
            }
            catch {
                Write-Log "WARNING: Could not inspect/close one Explorer window: $($_.Exception.Message)"
            }
        }

        Start-Sleep -Seconds 2
    }
    catch {
        Write-Log "WARNING: Could not enumerate File Explorer windows: $($_.Exception.Message)"
    }
}

function Eject-Drive {
    param (
        [string]$DriveLetter,
        [string]$ExpectedLabel
    )

    try {
        $Volume = Get-Volume -DriveLetter $DriveLetter -ErrorAction Stop

        if ($Volume.FileSystemLabel -ne $ExpectedLabel) {
            Write-Log "Eject skipped. Drive $DriveLetter`: label is '$($Volume.FileSystemLabel)', expected '$ExpectedLabel'."
            return $false
        }

        Write-Log "Attempting to eject drive $DriveLetter`: labeled '$ExpectedLabel'."

        $Shell = New-Object -ComObject Shell.Application
        $ShellNamespace = $Shell.Namespace(17)
        $DrivePath = "$DriveLetter`:\"
        $DriveItem = $ShellNamespace.ParseName($DrivePath)

        if ($null -eq $DriveItem) {
            Write-Log "Eject failed. Could not find shell item for drive path: $DrivePath"
            return $false
        }

        $DriveItem.InvokeVerb("Eject")

        Start-Sleep -Seconds 5

        if (Test-Path $DrivePath) {
            Write-Log "Eject attempted, but drive still appears mounted: $DrivePath"
            return $false
        }
        else {
            Write-Log "Drive successfully ejected: $DrivePath"
            return $true
        }
    }
    catch {
        Write-Log "ERROR ejecting drive $DriveLetter`: $($_.Exception.Message)"
        return $false
    }
}

# ----------------------------
# SCRIPT START
# ----------------------------

Write-Log "----- Plex movie sync started -----"

$HadErrors = $false
$MovedItems = @()

# ----------------------------
# SAFETY CHECKS
# ----------------------------

if (-not (Test-Path $SourceFolder)) {
    Write-Log "Source folder not found: $SourceFolder. PlexBackup drive may not be connected. Exiting."
    Write-Log "----- Plex movie sync finished -----"
    exit 0
}

if (-not (Test-Path $DestinationFolder)) {
    Write-Log "Destination folder not found: $DestinationFolder. Exiting."
    Write-Log "----- Plex movie sync finished -----"
    exit 1
}

try {
    $SourceVolume = Get-Volume -DriveLetter $SourceDriveLetter -ErrorAction Stop

    if ($SourceVolume.FileSystemLabel -ne $SourceDriveLabel) {
        Write-Log "WARNING: Source drive $SourceDriveLetter`: label is '$($SourceVolume.FileSystemLabel)', expected '$SourceDriveLabel'. Script will continue, but eject will be skipped unless label matches."
    }
}
catch {
    Write-Log "WARNING: Could not verify source drive label for $SourceDriveLetter`: $($_.Exception.Message)"
}

if (-not (Test-Path $StagingFolder)) {
    New-Item -Path $StagingFolder -ItemType Directory -Force | Out-Null
    Write-Log "Created staging folder: $StagingFolder"
}

$CutoffDate = (Get-Date).AddDays(-$LookbackDays)

Write-Log "Source: $SourceFolder"
Write-Log "Destination: $DestinationFolder"
Write-Log "Staging: $StagingFolder"
Write-Log "Looking for top-level items modified after: $CutoffDate"

# ----------------------------
# BUILD EXISTING DESTINATION INDEX
# ----------------------------

Write-Log "Building existing top-level destination index."

$ExistingDestinationNames = Get-TopLevelDestinationIndex -Path $DestinationFolder

Write-Log "Indexed $($ExistingDestinationNames.Count) existing top-level destination items."

# ----------------------------
# FIND RECENT TOP-LEVEL SOURCE ITEMS
# ----------------------------

$RecentItems = Get-ChildItem -Path $SourceFolder -Force |
    Where-Object {
        $_.LastWriteTime -ge $CutoffDate -and
        $ExcludedNames -notcontains $_.Name
    }

if (-not $RecentItems) {
    Write-Log "No recent items found. Nothing to copy."
    Write-Log "----- Plex movie sync finished -----"
    exit 0
}

# ----------------------------
# COPY RECENT MISSING ITEMS
# ----------------------------

foreach ($Item in $RecentItems) {
    $NormalizedItemName = Normalize-Name $Item.Name

    $DestinationPath = Join-Path $DestinationFolder $Item.Name
    $StagingPath = Join-Path $StagingFolder $Item.Name

    # Primary skip check: destination index
    if ($ExistingDestinationNames.ContainsKey($NormalizedItemName)) {
        Write-Log "Already exists in Plex folder by indexed name, skipping: $($Item.Name) -> $($ExistingDestinationNames[$NormalizedItemName])"
        continue
    }

    # Secondary skip check: direct path
    if (Test-Path -LiteralPath $DestinationPath) {
        Write-Log "Already exists in Plex folder by direct path, skipping: $($Item.Name)"
        $ExistingDestinationNames[$NormalizedItemName] = $DestinationPath
        continue
    }

    # Remove stale staging item if present
    if (Test-Path -LiteralPath $StagingPath) {
        Write-Log "Removing old staging copy: $StagingPath"
        Remove-Item -LiteralPath $StagingPath -Recurse -Force
    }

    try {
        Write-Log "Copying to staging: $($Item.FullName) -> $StagingPath"

        if ($Item.PSIsContainer) {
            robocopy $Item.FullName $StagingPath /E /COPY:DAT /DCOPY:DAT /R:2 /W:5 /NFL /NDL /NP | Out-Null
            $RoboExitCode = $LASTEXITCODE

            if ($RoboExitCode -le 7) {
                Write-Log "Copied folder to staging successfully: $($Item.Name). Robocopy exit code: $RoboExitCode"

                # Final check before move
                if ($ExistingDestinationNames.ContainsKey($NormalizedItemName) -or (Test-Path -LiteralPath $DestinationPath)) {
                    Write-Log "Destination exists before final move, removing staging copy: $($Item.Name)"
                    Remove-Item -LiteralPath $StagingPath -Recurse -Force
                }
                else {
                    Move-Item -LiteralPath $StagingPath -Destination $DestinationPath
                    $ExistingDestinationNames[$NormalizedItemName] = $DestinationPath
                    $MovedItems += [PSCustomObject]@{
                        Name = $Item.Name
                        NormalizedName = $NormalizedItemName
                        DestinationPath = $DestinationPath
                    }
                    Write-Log "Moved folder into Plex library: $($Item.Name)"
                }
            }
            else {
                $HadErrors = $true
                Write-Log "ROBOCOPY ERROR for folder: $($Item.Name). Exit code: $RoboExitCode"
            }
        }
        else {
            Copy-Item -LiteralPath $Item.FullName -Destination $StagingPath -Force
            Write-Log "Copied file to staging successfully: $($Item.Name)"

            # Final check before move
            if ($ExistingDestinationNames.ContainsKey($NormalizedItemName) -or (Test-Path -LiteralPath $DestinationPath)) {
                Write-Log "Destination exists before final move, removing staging copy: $($Item.Name)"
                Remove-Item -LiteralPath $StagingPath -Force
            }
            else {
                Move-Item -LiteralPath $StagingPath -Destination $DestinationPath
                $ExistingDestinationNames[$NormalizedItemName] = $DestinationPath
                $MovedItems += [PSCustomObject]@{
                    Name = $Item.Name
                    NormalizedName = $NormalizedItemName
                    DestinationPath = $DestinationPath
                }
                Write-Log "Moved file into Plex library: $($Item.Name)"
            }
        }
    }
    catch {
        $HadErrors = $true
        Write-Log "ERROR processing $($Item.Name): $($_.Exception.Message)"
    }
}

# ----------------------------
# POST-MOVE CONFIRMATION SCAN
# ----------------------------

if ($MovedItems.Count -eq 0) {
    Write-Log "No new items were moved. Eject will not be attempted."
    Write-Log "----- Plex movie sync finished -----"
    exit 0
}

Write-Log "Moved item count: $($MovedItems.Count)"
Write-Log "Running post-move confirmation scan against destination folder."

$PostMoveDestinationNames = Get-TopLevelDestinationIndex -Path $DestinationFolder

$MissingAfterMove = @()

foreach ($MovedItem in $MovedItems) {
    if ($PostMoveDestinationNames.ContainsKey($MovedItem.NormalizedName)) {
        Write-Log "Confirmed moved item present: $($MovedItem.Name) -> $($PostMoveDestinationNames[$MovedItem.NormalizedName])"
    }
    else {
        $MissingAfterMove += $MovedItem
        Write-Log "CONFIRMATION FAILED. Moved item not found in destination scan: $($MovedItem.Name)"
    }
}

if ($MissingAfterMove.Count -gt 0) {
    $HadErrors = $true
    Write-Log "Post-move confirmation failed for $($MissingAfterMove.Count) item(s). Eject will not be attempted."
    Write-Log "----- Plex movie sync finished -----"
    exit 1
}

if ($HadErrors) {
    Write-Log "One or more errors occurred during sync. Eject will not be attempted."
    Write-Log "----- Plex movie sync finished -----"
    exit 1
}

Write-Log "Post-move confirmation succeeded for all moved items."

# ----------------------------
# CLOSE EXPLORER WINDOWS AND EJECT SOURCE DRIVE
# ----------------------------

if ($EjectSourceDriveAfterSuccessfulMove) {
    Close-ExplorerWindowsForDrive -DriveLetter $SourceDriveLetter

    $EjectResult = Eject-Drive -DriveLetter $SourceDriveLetter -ExpectedLabel $SourceDriveLabel

    if ($EjectResult) {
        Write-Log "Source drive eject completed successfully."
    }
    else {
        Write-Log "Source drive eject did not complete successfully. You may need to eject it manually."
    }
}
else {
    Write-Log "EjectSourceDriveAfterSuccessfulMove is disabled. Source drive will remain mounted."
}

Write-Log "----- Plex movie sync finished -----"
exit 0
