# ==============================================================================
#  WindowsUpdateFull.ps1
# .SYNOPSYS: Führt ein vollständiges Windows System-Update durch. Es werden
#            Voraussetzungen geprüft und installiert, zwei Neustarts durchgeführt
#            und nach Abschluss eine Mail an den angegebenen Empfänger gesendet.
# .AUTHOR:   Malte Koelln, Ernst Bergau GmbH
# .REVISION: 23.02.2026
# ==============================================================================

# Setzen der benötigten Vaiablen
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
# Das hier muss ausgefüllt werden:
$smtpServer   = "smtp.example.com"
$smtpPort     = 587
$smtpFrom     = "absender@example.com"
$smtpTo       = "empfaenger@example.com"
$smtpUser     = "absender@example.com"
# Ablageort der Passwort-Dateien (AES256) für die Passwortverschlüsselung
$aesKeyFile   = Join-Path $scriptDir "mail_aes.key"
$encPwdFile   = Join-Path $scriptDir "mail_password.enc"

# E-Mail-Funktion
function Send-LogByMail {
    param([string]$LogFilePath)

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

    # Log-Datei als ZIP verpacken (umgeht Content-Filter fuer .log Dateien)
    $zipFilePath = [System.IO.Path]::ChangeExtension($LogFilePath, ".zip")
    try {
        if (Test-Path $zipFilePath) { Remove-Item $zipFilePath -Force }
        Compress-Archive -Path $LogFilePath -DestinationPath $zipFilePath -CompressionLevel Optimal
        Write-Log ("Log-Datei gezippt: " + $zipFilePath)
    }
    catch {
        Write-Log ("Fehler beim Erstellen des ZIP-Archivs: " + $_) "ERROR"
        return
    }

    try {
        $aesKey         = [System.IO.File]::ReadAllBytes($aesKeyFile)
        $encPwdString   = Get-Content $encPwdFile -Raw
        $securePassword = $encPwdString | ConvertTo-SecureString -Key $aesKey
        $credential     = New-Object System.Management.Automation.PSCredential($smtpUser, $securePassword)

        $subject        = [System.IO.Path]::GetFileName($zipFilePath)
        $body           = "Windows Update Log vom Computer $computerName ($date). Log-Datei im Anhang."

        $mailParams = @{
            SmtpServer  = $smtpServer
            Port        = $smtpPort
            UseSsl      = $true
            Credential  = $credential
            From        = $smtpFrom
            To          = $smtpTo
            Subject     = $subject
            Body        = $body
            Attachments = $zipFilePath
        }

        Send-MailMessage @mailParams
        Write-Log "E-Mail erfolgreich gesendet an: $smtpTo"
    }
    catch {
        Write-Log ("Fehler beim E-Mail-Versand: " + $_) "ERROR"
    }
    finally {
        # ZIP-Datei nach Versand wieder entfernen
        if (Test-Path $zipFilePath) {
            Remove-Item $zipFilePath -Force -ErrorAction SilentlyContinue
            Write-Log "Temporaere ZIP-Datei entfernt."
        }
    }
}

# Logging-Funktion
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    Write-Host $entry
    Add-Content -Path $logFile -Value $entry -Encoding UTF8
}

if (Test-Path $stepFile) {
    $step = (Get-Content $stepFile -Raw).Trim()
} else {
    $step = "1"
}

Write-Log "================================================================"
Write-Log "Script gestartet. Aktueller Schritt: $step"

# Script-Durchführung in drei Schritten, getrennt durch jeweils einen Neustart nach Schritt 1 und Schritt 2
switch ($step) {

    "1" {
        Write-Log "SCHRITT 1: NuGet und WinGet einrichten..."
        # NuGet Installation und Reparatur
        try {
            $progressPreference = 'SilentlyContinue'
            Write-Log "Installiere NuGet PackageProvider..."
            Install-PackageProvider -Name NuGet -Force | Out-Null

            Write-Log "Installiere Microsoft.WinGet.Client Modul..."
            Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery | Out-Null

            Write-Log "Fuehre Repair-WinGetPackageManager aus..."
            Repair-WinGetPackageManager -AllUsers
            Write-Log "WinGet Reparatur abgeschlossen."
        }
        catch {
            Write-Log ("Fehler in Schritt 1: " + $_) "ERROR"
            exit 1
        }
        # Setzen des Step-Markers für die Script-Weiterführung nah Neustart
        Set-Content -Path $stepFile -Value "2" -Encoding UTF8
        Write-Log "Step-Marker auf 2 gesetzt."
        # Erstellen des Scheduled Tasks für die Fortführung nach Neustart
        Write-Log "Erstelle Scheduled Task '$taskName'..."
        $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument ("-ExecutionPolicy Bypass -NonInteractive -File `"" + $scriptPath + "`"")
        $trigger   = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest -LogonType ServiceAccount
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Write-Log "Scheduled Task erfolgreich erstellt."
        # Neustart 1
        Write-Log "Neustart wird in 10 Sekunden durchgefuehrt..."
        Start-Sleep -Seconds 2
        shutdown.exe /r /t 10 /c "WindowsUpdate-Script: Neustart nach Schritt 1" /d p:4:1
    }

    "2" {
        # Neustart Netzwerkkarten
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
        # Prüfung / Installation von PSWindowsUpdate
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
            # Update-Suche
            $ConfirmPreference = 'None'
            Write-Log "Suche nach verfuegbaren Windows Updates..."
            $updates = Get-WindowsUpdate -AcceptAll -IgnoreReboot
            # Durchführung der Updates
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
            exit 1
        }
        # Setzen des Step-Markers für die Script-Weiterführung nah Neustart
        Set-Content -Path $stepFile -Value "3" -Encoding UTF8
        Write-Log "Step-Marker auf 3 gesetzt."
        Write-Log "Neustart wird in 10 Sekunden durchgefuehrt..."
        shutdown.exe /r /t 10 /c "Installieren von WindowsUpdates" /d p:4:1
    }

    "3" {
        # NIC-Neustart, Aufräumarbeiten und Mailversand
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

        Send-LogByMail -LogFilePath $logFile
    }

    default {
        Write-Log ("Unbekannter Schritt '" + $step + "' - breche ab.") "ERROR"
        exit 1
    }
}
