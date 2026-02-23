# ==============================================================================
# Setup-MailPassword.ps1
# Einmalig ausfuehren um das SMTP-Passwort AES-verschluesselt zu speichern.
# Die erzeugten Dateien (mail_aes.key + mail_password.enc) muessen im
# gleichen Ordner wie WindowsUpdateFull.ps1 liegen.
# ==============================================================================

$scriptDir  = Split-Path $MyInvocation.MyCommand.Path -Parent
$aesKeyFile = Join-Path $scriptDir "mail_aes.key"
$encPwdFile = Join-Path $scriptDir "mail_password.enc"

Write-Host ""
Write-Host "=== SMTP Passwort Setup ===" -ForegroundColor Cyan
Write-Host "Die Dateien werden gespeichert in: $scriptDir"
Write-Host ""

# Passwort sicher einlesen (wird nicht im Klartext angezeigt)
$securePassword = Read-Host -Prompt "SMTP-Passwort eingeben" -AsSecureString

# 256-Bit AES-Schluessel zufaellig generieren
$aesKey = New-Object byte[] 32
[System.Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($aesKey)

# Passwort mit AES-Key verschluesseln
$encryptedPassword = $securePassword | ConvertFrom-SecureString -Key $aesKey

# Dateien speichern
[System.IO.File]::WriteAllBytes($aesKeyFile, $aesKey)
Set-Content -Path $encPwdFile -Value $encryptedPassword -Encoding UTF8

Write-Host ""
Write-Host "Fertig! Folgende Dateien wurden erstellt:" -ForegroundColor Green
Write-Host "  AES-Key  : $aesKeyFile"
Write-Host "  Passwort : $encPwdFile"
Write-Host ""
Write-Host "Hinweis: Beide Dateien sind vertraulich - Zugriff einschraenken!" -ForegroundColor Yellow

# SIDs verwenden - sprachunabhaengig (funktioniert auf DE/EN/FR/...)
# S-1-5-18          = SYSTEM
# S-1-5-32-544      = Administratoren / Administrators (built-in)
$sidSystem = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")
$sidAdmins = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")

$ruleSystem = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $sidSystem, "FullControl", "Allow")
$ruleAdmins = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $sidAdmins, "FullControl", "Allow")

foreach ($targetFile in @($aesKeyFile, $encPwdFile)) {
    $acl = Get-Acl $targetFile
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule($ruleSystem)
    $acl.AddAccessRule($ruleAdmins)
    Set-Acl -Path $targetFile -AclObject $acl
}

Write-Host "Berechtigungen gesetzt: Nur SYSTEM und Administratoren haben Zugriff." -ForegroundColor Green
Write-Host ""
