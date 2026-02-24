# WindowsServerUpdater
Powershell toolset to manage Windows Server updates, reliable and trackable.

Purpose

Automates a complete Windows system update with prerequisites, network adapter management, and email reporting.

Key Features

Three-stage execution separated by system restarts:

Step 1: Installs/repairs NuGet and WinGet package managers, then creates a scheduled task for automatic continuation after reboot

Step 2: Restarts network adapters, checks for Windows updates, and installs them via PSWindowsUpdate module

Step 3: Final network adapter restart, cleanup, removal of scheduled task, and email log delivery

Logging: Comprehensive logging to a timestamped file with computer name

Email Integration:            Sends compressed update log to specified recipient using encrypted SMTP credentials (AES-256 encrypted password stored separately)

Resilience:                   Persistent step tracking via file to handle script interruptions

SMTP Configuration Required:  Must be customized with server, port, sender/recipient addresses before deployment.

                              Plese use "Setup-MailPassword.ps1" for generating encrypted mail password and key.
