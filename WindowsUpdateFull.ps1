# ==============================================================================
#  WindowsUpdateFull.ps1
# .SYNOPSYS: Führt ein vollständiges Windows System-Update durch. Es werden
#            Voraussetzungen geprüft und installiert, zwei Neustarts durchgeführt
#            und nach Abschluss eine Status-Mail an den angegebenen Empfänger gesendet.
# .REQUIRES: Windows Server 2016 or higher, Powershell 3 or higher
# .AUTHOR:   Malte Koelln
# .REVISION: 02/24/2026
# ==============================================================================

$scriptPath = $MyInvocation.MyCommand.Path
$scriptDir  = Split-Path $scriptPath -Parent
$taskName   = "WindowsUpdate-Script"
$stepFile   = "$env:ProgramData\WindowsUpdateScript_step.txt"

$computerName = $env:COMPUTERNAME
$date         = Get-Date -Format "yyyy-MM-dd"
$logFile      = Join-Path $scriptDir ($computerName + "_" + $date + "_WindowsUpdate.log")

# ==============================================================================
# SMTP-Konfiguration
# Passwort-Dateien werden per Setup-Script (Setup-MailPassword.ps1) erstellt.
# ==============================================================================
$smtpServer   = "smtp.example.com"
$smtpPort     = 587
$smtpFrom     = "absender@example.com"
$smtpTo       = "empfaenger@example.com"
$smtpUser     = "absender@example.com"
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
# Mail-Versand
# $Subject: wenn leer, wird der Dateiname als Betreff verwendet (Erfolgsfall).
#           Bei Fehler wird "ERROR <HOSTNAME> <DATUM>" uebergeben.
# ==============================================================================
function Send-LogByMail {
    param(
        [string]$LogFilePath,
        [string]$Subject = ""
    )

    Write-Log "Sende Log-Datei per E-Mail..."

    if (-not (Test-Path $aesKeyFile)) {
        Write-Log ("AES-Key-Datei nicht gefunden: " + $aesKeyFile) "ERROR"
        return
    }
    if (-not (Test-Path $encPwdFile)) {
        Write-Log ("Verschluesseltes Passwort nicht gefunden: " + $encPwdFile) "ERROR"
        return
    }
    if (-not (Test-Path $LogFilePath)) {
        Write-Log ("Log-Datei nicht gefunden: " + $LogFilePath) "ERROR"
        return
    }

    try {
        $aesKey         = [System.IO.File]::ReadAllBytes($aesKeyFile)
        $encPwdString   = Get-Content $encPwdFile -Raw
        $securePassword = $encPwdString | ConvertTo-SecureString -Key $aesKey
        $credential     = New-Object System.Management.Automation.PSCredential($smtpUser, $securePassword)

        if ([string]::IsNullOrWhiteSpace($Subject)) {
            $Subject = [System.IO.Path]::GetFileName($LogFilePath)
            $body    = "Windows Update Log vom Computer $computerName ($date). Log-Datei im Anhang."
        }
        else {
            $body = "Windows Update Script FEHLER auf $computerName am $date. Details siehe angehaengte Log-Datei."
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
        Write-Log "E-Mail erfolgreich gesendet an: $smtpTo"
    }
    catch {
        Write-Log ("Fehler beim E-Mail-Versand: " + $_) "ERROR"
    }
}

# Hilfsfunktion: Baut den Fehler-Betreff zusammen
function Get-ErrorSubject {
    $d = Get-Date -Format "yyyy-MM-dd"
    return "ERROR $computerName $d"
}

# ==============================================================================
# WinGet-Installation als Fallback (direkt via GitHub MSIX)
# Wird verwendet, wenn Repair-WinGetPackageManager fehlschlaegt oder haengt.
# ==============================================================================
function Install-WinGetFallback {
    Write-Log "Starte WinGet-Fallback-Installation via GitHub..."

    try {
        $apiUrl   = "https://api.github.com/repos/microsoft/winget-cli/releases/latest"
        $headers  = @{ "User-Agent" = "WindowsUpdateScript" }
        $release  = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 30

        $msixAsset = $release.assets | Where-Object { $_.name -like "*.msixbundle" } | Select-Object -First 1
        $licAsset  = $release.assets | Where-Object { $_.name -like "*.License1.xml" } | Select-Object -First 1

        if (-not $msixAsset) {
            Write-Log "Kein MSIX-Bundle in GitHub-Release gefunden." "ERROR"
            return $false
        }

        $tmpMsix = Join-Path $env:TEMP "winget.msixbundle"
        $tmpLic  = Join-Path $env:TEMP "winget_license.xml"

        Write-Log ("Lade WinGet herunter: " + $msixAsset.browser_download_url)
        Invoke-WebRequest -Uri $msixAsset.browser_download_url -OutFile $tmpMsix -TimeoutSec 120

        if ($licAsset) {
            Write-Log ("Lade Lizenz herunter: " + $licAsset.browser_download_url)
            Invoke-WebRequest -Uri $licAsset.browser_download_url -OutFile $tmpLic -TimeoutSec 30
            Add-AppxProvisionedPackage -Online -PackagePath $tmpMsix -LicensePath $tmpLic | Out-Null
        }
        else {
            Add-AppxPackage -Path $tmpMsix | Out-Null
        }

        Write-Log "WinGet-Fallback-Installation abgeschlossen."
        return $true
    }
    catch {
        Write-Log ("WinGet-Fallback fehlgeschlagen: " + $_) "ERROR"
        return $false
    }
    finally {
        Remove-Item $tmpMsix -Force -ErrorAction SilentlyContinue
        Remove-Item $tmpLic  -Force -ErrorAction SilentlyContinue
    }
}

# ==============================================================================
# Prueft ob winget verfuegbar ist
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
# Hauptlogik
# ==============================================================================
if (Test-Path $stepFile) {
    $step = (Get-Content $stepFile -Raw).Trim()
}
else {
    $step = "1"
}

Write-Log "================================================================"
Write-Log "Script gestartet. Aktueller Schritt: $step"

switch ($step) {

    "1" {
        Write-Log "SCHRITT 1: NuGet und WinGet einrichten..."

        try {
            $progressPreference = 'SilentlyContinue'

            Write-Log "Installiere NuGet PackageProvider..."
            Install-PackageProvider -Name NuGet -Force -ErrorAction Stop | Out-Null

            Write-Log "Installiere Microsoft.WinGet.Client Modul..."
            Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery -ErrorAction Stop | Out-Null

            # --- Repair-WinGetPackageManager mit Timeout (90 Sek.) ---
            Write-Log "Fuehre Repair-WinGetPackageManager aus (Timeout: 90s)..."
            $repairJob = Start-Job -ScriptBlock {
                Import-Module Microsoft.WinGet.Client -Force
                Repair-WinGetPackageManager -AllUsers
            }

            $completed = Wait-Job -Job $repairJob -Timeout 90

            if ($completed) {
                $jobOutput = Receive-Job -Job $repairJob 2>&1
                if ($repairJob.State -eq 'Failed') {
                    Write-Log ("Repair-WinGetPackageManager Job fehlgeschlagen: " + ($jobOutput -join ' ')) "WARN"
                }
                else {
                    Write-Log "Repair-WinGetPackageManager abgeschlossen."
                }
            }
            else {
                Stop-Job  -Job $repairJob
                Write-Log "Repair-WinGetPackageManager hat Timeout ueberschritten - wird abgebrochen." "WARN"
            }
            Remove-Job -Job $repairJob -Force

            # --- Pruefe ob WinGet nun verfuegbar ist, sonst Fallback ---
            if (Test-WinGet) {
                Write-Log "WinGet ist verfuegbar. Schritt 1 erfolgreich."
            }
            else {
                Write-Log "WinGet nicht verfuegbar nach Repair - starte Fallback-Installation..." "WARN"
                $fallbackOk = Install-WinGetFallback
                if (-not $fallbackOk) {
                    throw "WinGet konnte weder per Repair noch per Fallback installiert werden."
                }
            }
        }
        catch {
            Write-Log ("Fehler in Schritt 1: " + $_) "ERROR"
            Send-LogByMail -LogFilePath $logFile -Subject (Get-ErrorSubject)
            exit 1
        }

        Set-Content -Path $stepFile -Value "2" -Encoding UTF8
        Write-Log "Step-Marker auf 2 gesetzt."

        Write-Log "Erstelle Scheduled Task '$taskName'..."
        $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument ("-ExecutionPolicy Bypass -NonInteractive -File `"" + $scriptPath + "`"")
        $trigger   = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest -LogonType ServiceAccount
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Write-Log "Scheduled Task erfolgreich erstellt."

        Write-Log "Neustart wird in 10 Sekunden durchgefuehrt..."
        Start-Sleep -Seconds 2
        shutdown.exe /r /t 10 /c "WindowsUpdate-Script: Neustart nach Schritt 1" /d p:4:1
    }

    "2" {
        Write-Log "SCHRITT 2: Netzwerkadapter neu starten und Windows Updates installieren..."

        try {
            Write-Log "Warte 60 Sekunden und starte alle Netzwerkadapter neu..."
            Start-Sleep -Seconds 60
            Get-NetAdapter | Restart-NetAdapter -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5
            Write-Log "Netzwerkadapter neugestartet."
        }
        catch {
            Write-Log ("Warnung beim Neustart der Netzwerkadapter: " + $_) "WARN"
        }

        try {
            Write-Log "Pruefe PSWindowsUpdate Modul..."
            if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
                Write-Log "PSWindowsUpdate nicht gefunden - installiere..."
                Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers | Out-Null
                Write-Log "PSWindowsUpdate installiert."
            }
            else {
                Write-Log "PSWindowsUpdate bereits vorhanden."
            }

            Import-Module PSWindowsUpdate -Force
            Write-Log "PSWindowsUpdate Modul geladen."

            $ConfirmPreference = 'None'
            Write-Log "Suche nach verfuegbaren Windows Updates..."
            $updates = Get-WindowsUpdate -AcceptAll -IgnoreReboot

            if ($updates) {
                Write-Log ("Updates gefunden: " + $updates.Count + " Update(s). Starte Installation...")
                Install-WindowsUpdate -AcceptAll -IgnoreReboot -AutoReboot:$false | ForEach-Object {
                    Write-Log ("  Update: " + $_.Title + " - Status: " + $_.Status)
                }
                Write-Log "Update-Installation abgeschlossen."
            }
            else {
                Write-Log "Keine Updates verfuegbar."
            }
        }
        catch {
            Write-Log ("Fehler in Schritt 2: " + $_) "ERROR"
            Send-LogByMail -LogFilePath $logFile -Subject (Get-ErrorSubject)
            exit 1
        }

        Set-Content -Path $stepFile -Value "3" -Encoding UTF8
        Write-Log "Step-Marker auf 3 gesetzt."
        Write-Log "Neustart wird in 10 Sekunden durchgefuehrt..."
        shutdown.exe /r /t 10 /c "Installieren von WindowsUpdates" /d p:4:1
    }

    "3" {
        Write-Log "SCHRITT 3: Aufraeumen nach Updates..."

        try {
            Write-Log "Warte 60 Sekunden und starte alle Netzwerkadapter neu..."
            Start-Sleep -Seconds 60
            Get-NetAdapter | Restart-NetAdapter -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5
            Write-Log "Netzwerkadapter neugestartet."
        }
        catch {
            Write-Log ("Warnung beim Neustart der Netzwerkadapter: " + $_) "WARN"
        }

        Remove-Item $stepFile -Force -ErrorAction SilentlyContinue
        Write-Log "Step-Marker-Datei entfernt."

        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log "Scheduled Task entfernt."

        Write-Log "================================================================"
        Write-Log "FERTIG: Windows Update Prozess vollstaendig abgeschlossen!"

        # Erfolgsmail - Betreff = Dateiname.
        Send-LogByMail -LogFilePath $logFile
    }

    default {
        Write-Log ("Unbekannter Schritt '" + $step + "' - breche ab.") "ERROR"
        Send-LogByMail -LogFilePath $logFile -Subject (Get-ErrorSubject)
        exit 1
    }
}
