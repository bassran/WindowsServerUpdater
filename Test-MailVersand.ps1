# ==============================================================================
# Test-MailVersand.ps1
# Isolierter Test des SMTP-Mailversands mit ausfuehrlicher Diagnose
# ==============================================================================

# --- Konfiguration (identisch zu WindowsUpdateFull.ps1 anpassen) ---
$smtpServer = "smtp.example.com"
$smtpPort   = 587
$smtpFrom   = "absender@example.com"
$smtpTo     = "empfaenger@example.com"
$smtpUser   = "absender@example.com"

$scriptDir  = Split-Path $MyInvocation.MyCommand.Path -Parent
$aesKeyFile = Join-Path $scriptDir "mail_aes.key"
$encPwdFile = Join-Path $scriptDir "mail_password.enc"

function Log {
    param([string]$Msg, [string]$Color = "White")
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host ("[$ts] " + $Msg) -ForegroundColor $Color
}

Log "================================================================" Cyan
Log "SMTP Diagnose-Tool" Cyan
Log "================================================================" Cyan

# ------------------------------------------------------------------------------
# SCHRITT 1: Dateien pruefen
# ------------------------------------------------------------------------------
Log ""
Log "[ SCHRITT 1 ] Pruefe Schlussel- und Passwortdateien..." Yellow

if (Test-Path $aesKeyFile) {
    $keySize = (Get-Item $aesKeyFile).Length
    Log ("  OK  AES-Key gefunden: " + $aesKeyFile + " (" + $keySize + " Bytes)") Green
    if ($keySize -ne 32) {
        Log "  WARNUNG: AES-Key sollte 32 Bytes haben (256-bit) - Datei ggf. beschaedigt!" Red
    }
} else {
    Log ("  FEHLER: AES-Key nicht gefunden: " + $aesKeyFile) Red
    Log "  Bitte Setup-MailPassword.ps1 ausfuehren!" Red
    exit 1
}

if (Test-Path $encPwdFile) {
    Log ("  OK  Passwort-Datei gefunden: " + $encPwdFile) Green
} else {
    Log ("  FEHLER: Passwort-Datei nicht gefunden: " + $encPwdFile) Red
    Log "  Bitte Setup-MailPassword.ps1 ausfuehren!" Red
    exit 1
}

# ------------------------------------------------------------------------------
# SCHRITT 2: Passwort entschluesseln
# ------------------------------------------------------------------------------
Log ""
Log "[ SCHRITT 2 ] Entschluessele Passwort..." Yellow

try {
    $aesKey         = [System.IO.File]::ReadAllBytes($aesKeyFile)
    $encPwdString   = Get-Content $encPwdFile -Raw
    $securePassword = $encPwdString | ConvertTo-SecureString -Key $aesKey
    $credential     = New-Object System.Management.Automation.PSCredential($smtpUser, $securePassword)
    Log "  OK  Passwort erfolgreich entschluesselt." Green
}
catch {
    Log ("  FEHLER beim Entschluesseln: " + $_) Red
    exit 1
}

# ------------------------------------------------------------------------------
# SCHRITT 3: DNS-Aufloesung des SMTP-Servers
# ------------------------------------------------------------------------------
Log ""
Log ("[ SCHRITT 3 ] DNS-Aufloesung fuer: " + $smtpServer) Yellow

try {
    $dns = [System.Net.Dns]::GetHostAddresses($smtpServer)
    foreach ($ip in $dns) {
        Log ("  OK  " + $smtpServer + " -> " + $ip.IPAddressToString) Green
    }
}
catch {
    Log ("  FEHLER: DNS-Aufloesung fehlgeschlagen: " + $_) Red
    Log "  Moegliche Ursache: Falscher Servername oder kein DNS-Zugriff." Red
    exit 1
}

# ------------------------------------------------------------------------------
# SCHRITT 4: TCP-Verbindung auf SMTP-Port testen
# ------------------------------------------------------------------------------
Log ""
Log ("[ SCHRITT 4 ] TCP-Verbindungstest auf Port " + $smtpPort + "...") Yellow

try {
    $tcpClient = New-Object System.Net.Sockets.TcpClient
    $result    = $tcpClient.BeginConnect($smtpServer, $smtpPort, $null, $null)
    $success   = $result.AsyncWaitHandle.WaitOne(5000)
    if ($success -and $tcpClient.Connected) {
        Log ("  OK  TCP-Verbindung zu " + $smtpServer + ":" + $smtpPort + " erfolgreich.") Green
        $tcpClient.Close()
    } else {
        Log ("  FEHLER: Keine TCP-Verbindung zu " + $smtpServer + ":" + $smtpPort) Red
        Log "  Moegliche Ursachen:" Red
        Log "    - Firewall blockiert Port $smtpPort" Red
        Log "    - SMTP-Server akzeptiert keine Verbindung auf diesem Port" Red
        Log "    - Falscher Port (uebliche Ports: 25, 465, 587)" Red
        $tcpClient.Close()
        exit 1
    }
}
catch {
    Log ("  FEHLER bei TCP-Test: " + $_) Red
    exit 1
}

# ------------------------------------------------------------------------------
# SCHRITT 5: Testmail senden mit ausfuehrlicher Fehlerausgabe
# ------------------------------------------------------------------------------
Log ""
Log "[ SCHRITT 5 ] Sende Testmail..." Yellow
Log ("  Von    : " + $smtpFrom) Cyan
Log ("  An     : " + $smtpTo) Cyan
Log ("  Server : " + $smtpServer + ":" + $smtpPort) Cyan
Log ("  SSL    : true") Cyan

try {
    $mailParams = @{
        SmtpServer  = $smtpServer
        Port        = $smtpPort
        UseSsl      = $true
        Credential  = $credential
        From        = $smtpFrom
        To          = $smtpTo
        Subject     = "SMTP Test - " + $env:COMPUTERNAME + " - " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        Body        = "Dies ist eine Testmail vom SMTP-Diagnose-Tool auf " + $env:COMPUTERNAME + "."
    }

    Send-MailMessage @mailParams
    Log "  OK  Testmail erfolgreich gesendet!" Green
}
catch {
    $errMsg = $_.ToString()
    Log ("  FEHLER beim Senden: " + $errMsg) Red
    Log "" White

    # Hilfreiche Hinweise je nach Fehlertyp
    if ($errMsg -like "*5.7*" -or $errMsg -like "*authentication*" -or $errMsg -like "*credentials*") {
        Log "  HINWEIS: Authentifizierungsfehler - Benutzername oder Passwort falsch." Yellow
        Log "           Ggf. App-Passwort benoetigt (z.B. bei Gmail, Office365)." Yellow
    }
    elseif ($errMsg -like "*SSL*" -or $errMsg -like "*TLS*" -or $errMsg -like "*certificate*") {
        Log "  HINWEIS: SSL/TLS-Fehler." Yellow
        Log "           Bei Port 465 ggf. UseSsl = false + implizites SSL noetig." Yellow
        Log "           Bei Port 587 sollte UseSsl = true (STARTTLS) funktionieren." Yellow
    }
    elseif ($errMsg -like "*timeout*" -or $errMsg -like "*timed out*") {
        Log "  HINWEIS: Verbindungs-Timeout - Server antwortet nicht rechtzeitig." Yellow
    }
    elseif ($errMsg -like "*5.5.1*" -or $errMsg -like "*relay*") {
        Log "  HINWEIS: Relay-Fehler - Server erlaubt keinen Versand von dieser Absenderadresse." Yellow
    }
    exit 1
}

Log ""
Log "================================================================" Cyan
Log "Alle Tests bestanden. Mail wurde gesendet." Cyan
Log "================================================================" Cyan
