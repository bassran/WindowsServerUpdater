# ======================================================================================================
#  WindowsUpdateFull.ps1
# .SYNOPSYS: Performs a complete Windows system update. Prerequisites are checked
#            and installed, two restarts are performed and upon completion a status email
#            is sent to the specified recipient.
# .REQUIRES: Windows 10 Version 1809 or higher, Windows Server 2019 or higher, Powershell 5.1 or higher
# .AUTHOR:   bassran
# .REVISION: 02/24/2026
# ======================================================================================================

$scriptPath = $MyInvocation.MyCommand.Path
$scriptDir  = Split-Path $scriptPath -Parent
$taskName   = "WindowsUpdate-Script"
$stepFile   = "$env:ProgramData\WindowsUpdateScript_step.txt"

$computerName = $env:COMPUTERNAME
$date         = Get-Date -Format "yyyy-MM-dd"
$logFile      = Join-Path $scriptDir ($computerName + "_" + $date + "_WindowsUpdate.log")

# ==============================================================================
# SMTP Configuration
# Password files are created via Setup script (Setup-MailPassword.ps1).
# ==============================================================================
$smtpServer   = "smtp.example.com"
$smtpPort     = 587 # Adjust if your SMTP server uses a different port (e.g., 465 for SSL)
$smtpFrom     = "sender@example.com"
$smtpTo       = "recipient@example.com"
$smtpUser     = "sender@example.com"
$aesKeyFile = Join-Path $scriptDir "mail_aes.key"
$encPwdFile = Join-Path $scriptDir "mail_password.enc"

# ==============================================================================
# Logging
# ==============================================================================
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    Write-Host $entry
    Add-Content -Path $logFile -Value $entry -Encoding UTF8
}

# ==============================================================================
# Email sending
# $Subject: if empty, the file name is used as the subject (success case).
#           In case of error, "ERROR <HOSTNAME> <DATE>" is passed.
# ==============================================================================
function Send-LogByMail {
    param(
        [string]$LogFilePath,
        [string]$Subject = ""
    )

    Write-Log "Sending log file via email..."

    if (-not (Test-Path $aesKeyFile)) {
        Write-Log ("AES key file not found: " + $aesKeyFile) "ERROR"
        return
    }
    if (-not (Test-Path $encPwdFile)) {
        Write-Log ("Encrypted password not found: " + $encPwdFile) "ERROR"
        return
    }
    if (-not (Test-Path $LogFilePath)) {
        Write-Log ("Log file not found: " + $LogFilePath) "ERROR"
        return
    }

    try {
        $aesKey         = [System.IO.File]::ReadAllBytes($aesKeyFile)
        $encPwdString   = Get-Content $encPwdFile -Raw
        $securePassword = $encPwdString | ConvertTo-SecureString -Key $aesKey
        $credential     = New-Object System.Management.Automation.PSCredential($smtpUser, $securePassword)

        if ([string]::IsNullOrWhiteSpace($Subject)) {
            $Subject = [System.IO.Path]::GetFileName($LogFilePath)
            $body    = "Windows Update log from computer $computerName ($date). Log file attached."
        }
        else {
            $body = "Windows Update script ERROR on $computerName on $date. See attached log file for details."
        }

        $mailParams = @{
            SmtpServer  = $smtpServer
            Port        = $smtpPort
            UseSsl      = $true
            Credential  = $credential
            From        = $smtpFrom
            To          = $smtpTo
            Subject     = $Subject
            Body        = $body
            Attachments = $LogFilePath
        }

        Send-MailMessage @mailParams
        Write-Log "Email sent successfully to: $smtpTo"
    }
    catch {
        Write-Log ("Error sending email: " + $_) "ERROR"
    }
}

# Helper function: builds the error subject
function Get-ErrorSubject {
    $d = Get-Date -Format "yyyy-MM-dd"
    return "ERROR $computerName $d"
}

# ==============================================================================
# WinGet installation as fallback (directly via GitHub MSIX)
# Used when Repair-WinGetPackageManager fails or hangs.
# ==============================================================================
function Install-WinGetFallback {
    Write-Log "Starting WinGet fallback installation via GitHub..."

    try {
        $apiUrl   = "https://api.github.com/repos/microsoft/winget-cli/releases/latest"
        $headers  = @{ "User-Agent" = "WindowsUpdateScript" }
        $release  = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 30

        $msixAsset = $release.assets | Where-Object { $_.name -like "*.msixbundle" } | Select-Object -First 1
        $licAsset  = $release.assets | Where-Object { $_.name -like "*.License1.xml" } | Select-Object -First 1

        if (-not $msixAsset) {
            Write-Log "No MSIX bundle found in GitHub release." "ERROR"
            return $false
        }

        $tmpMsix = Join-Path $env:TEMP "winget.msixbundle"
        $tmpLic  = Join-Path $env:TEMP "winget_license.xml"

        Write-Log ("Downloading WinGet: " + $msixAsset.browser_download_url)
        Invoke-WebRequest -Uri $msixAsset.browser_download_url -OutFile $tmpMsix -TimeoutSec 120

        if ($licAsset) {
            Write-Log ("Downloading license: " + $licAsset.browser_download_url)
            Invoke-WebRequest -Uri $licAsset.browser_download_url -OutFile $tmpLic -TimeoutSec 30
            Add-AppxProvisionedPackage -Online -PackagePath $tmpMsix -LicensePath $tmpLic | Out-Null
        }
        else {
            Add-AppxPackage -Path $tmpMsix | Out-Null
        }

        Write-Log "WinGet fallback installation completed."
        return $true
    }
    catch {
        Write-Log ("WinGet fallback failed: " + $_) "ERROR"
        return $false
    }
    finally {
        Remove-Item $tmpMsix -Force -ErrorAction SilentlyContinue
        Remove-Item $tmpLic  -Force -ErrorAction SilentlyContinue
    }
}

# ==============================================================================
# Check if winget is available
# ==============================================================================
function Test-WinGet {
    try {
        $null = & winget --version 2>&1
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
}

# ==============================================================================
# Main logic
# ==============================================================================
if (Test-Path $stepFile) {
    $step = (Get-Content $stepFile -Raw).Trim()
}
else {
    $step = "1"
}

Write-Log "================================================================"
Write-Log "Script started. Current step: $step"

switch ($step) {

    "1" {
        Write-Log "STEP 1: Setting up NuGet and WinGet..."

        try {
            $progressPreference = 'SilentlyContinue'

            Write-Log "Installing NuGet PackageProvider..."
            Install-PackageProvider -Name NuGet -Force -ErrorAction Stop | Out-Null

            Write-Log "Installing Microsoft.WinGet.Client module..."
            Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery -ErrorAction Stop | Out-Null

            # --- Repair-WinGetPackageManager with timeout (90 sec) ---
            Write-Log "Running Repair-WinGetPackageManager (timeout: 90s)..."
            $repairJob = Start-Job -ScriptBlock {
                Import-Module Microsoft.WinGet.Client -Force
                Repair-WinGetPackageManager -AllUsers
            }

            $completed = Wait-Job -Job $repairJob -Timeout 90

            if ($completed) {
                $jobOutput = Receive-Job -Job $repairJob 2>&1
                if ($repairJob.State -eq 'Failed') {
                    Write-Log ("Repair-WinGetPackageManager job failed: " + ($jobOutput -join ' ')) "WARN"
                }
                else {
                    Write-Log "Repair-WinGetPackageManager completed."
                }
            }
            else {
                Stop-Job  -Job $repairJob
                Write-Log "Repair-WinGetPackageManager exceeded timeout - aborting." "WARN"
            }
            Remove-Job -Job $repairJob -Force

            # --- Check if WinGet is now available, otherwise fallback ---
            if (Test-WinGet) {
                Write-Log "WinGet is available. Step 1 successful."
            }
            else {
                Write-Log "WinGet not available after repair - starting fallback installation..." "WARN"
                $fallbackOk = Install-WinGetFallback
                if (-not $fallbackOk) {
                    throw "WinGet could not be installed via repair or fallback."
                }
            }
        }
        catch {
            Write-Log ("Error in step 1: " + $_) "ERROR"
            Send-LogByMail -LogFilePath $logFile -Subject (Get-ErrorSubject)
            exit 1
        }

        Set-Content -Path $stepFile -Value "2" -Encoding UTF8
        Write-Log "Step marker set to 2."

        Write-Log "Creating scheduled task '$taskName'..."
        $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument ("-ExecutionPolicy Bypass -NonInteractive -File `"" + $scriptPath + "`"")
        $trigger   = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest -LogonType ServiceAccount
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Write-Log "Scheduled task created successfully."

        Write-Log "Restarting in 10 seconds..."
        Start-Sleep -Seconds 2
        shutdown.exe /r /t 10 /c "WindowsUpdate-Script: Restart after step 1" /d p:4:1
    }

    "2" {
        Write-Log "STEP 2: Restart network adapters and install Windows updates..."

        try {
            Write-Log "Warte 60 Sekunden und starte alle Netzwerkadapter neu..."
            Start-Sleep -Seconds 60
            Get-NetAdapter | Restart-NetAdapter -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5
            Write-Log "Netzwerkadapter neugestartet."
        }
        catch {
            Write-Log ("Warning restarting network adapters: " + $_) "WARN"
        }

        try {
            Write-Log "Checking PSWindowsUpdate module..."
            if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
                Write-Log "PSWindowsUpdate not found - installing..."
                Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers | Out-Null
                Write-Log "PSWindowsUpdate installed."
            }
            else {
                Write-Log "PSWindowsUpdate already present."
            }

            Import-Module PSWindowsUpdate -Force
            Write-Log "PSWindowsUpdate module loaded."

            $ConfirmPreference = 'None'
            Write-Log "Searching for available Windows updates..."
            $updates = Get-WindowsUpdate -AcceptAll -IgnoreReboot

            if ($updates) {
                Write-Log ("Updates found: " + $updates.Count + " update(s). Starting installation...")
                Install-WindowsUpdate -AcceptAll -IgnoreReboot -AutoReboot:$false | ForEach-Object {
                    Write-Log ("  Update: " + $_.Title + " - Status: " + $_.Status)
                }
                Write-Log "Update installation completed."
            }
            else {
                Write-Log "No updates available."
            }
        }
        catch {
            Write-Log ("Error in step 2: " + $_) "ERROR"
            Send-LogByMail -LogFilePath $logFile -Subject (Get-ErrorSubject)
            exit 1
        }

        Set-Content -Path $stepFile -Value "3" -Encoding UTF8
        Write-Log "Step marker set to 3."
        Write-Log "Restarting in 10 seconds..."
        shutdown.exe /r /t 10 /c "Installing Windows updates" /d p:4:1
    }

    "3" {
        Write-Log "STEP 3: Cleaning up after updates..."

        try {
            Write-Log "Warte 60 Sekunden und starte alle Netzwerkadapter neu..."
            Start-Sleep -Seconds 60
            Get-NetAdapter | Restart-NetAdapter -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5
            Write-Log "Netzwerkadapter neugestartet."
        }
        catch {
            Write-Log ("Warning restarting network adapters: " + $_) "WARN"
        }

        Remove-Item $stepFile -Force -ErrorAction SilentlyContinue
        Write-Log "Step marker file removed."

        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log "Scheduled task removed."

        Write-Log "================================================================"
        Write-Log "FINISHED: Windows Update process completed successfully!"

        # Success email - subject = file name.
        Send-LogByMail -LogFilePath $logFile
    }

    default {
        Write-Log ("Unknown step '" + $step + "' - aborting.") "ERROR"
        Send-LogByMail -LogFilePath $logFile -Subject (Get-ErrorSubject)
        exit 1
    }
}
