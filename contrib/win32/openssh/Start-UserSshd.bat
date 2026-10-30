@echo off
setlocal DisableDelayedExpansion
rem Keep this file beside sshd.exe in the complete patched package.
rem Usage: Start-UserSshd.bat [existing-sshd-config]
set "OPENSSH_CURRENT_USER_ONLY=1"
set "OPENSSH_USER_SSHD_EXE=%~dp0sshd.exe"
set "OPENSSH_USER_SSHD_CONFIG=%LOCALAPPDATA%\OpenSSH-User-2000\sshd_config"
if not "%~1"=="" set "OPENSSH_USER_SSHD_CONFIG=%~f1"

if not exist "%OPENSSH_USER_SSHD_EXE%" (
    echo Missing sshd.exe. Keep the entire patched OpenSSH package together. 1>&2
    exit /b 1
)
if not exist "%OPENSSH_USER_SSHD_CONFIG%" (
    echo Existing sshd config not found: "%OPENSSH_USER_SSHD_CONFIG%" 1>&2
    echo Usage: Start-UserSshd.bat [existing-sshd-config] 1>&2
    exit /b 1
)

rem Report configuration errors before starting the hidden launcher.
"%OPENSSH_USER_SSHD_EXE%" -t -f "%OPENSSH_USER_SSHD_CONFIG%"
if errorlevel 1 exit /b %errorlevel%

rem Launch independently so closing this batch window does not stop sshd.
rem Inherited environment variables preserve paths without PowerShell quoting.
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -Command "while ($true) { & $env:OPENSSH_USER_SSHD_EXE -D -e -f $env:OPENSSH_USER_SSHD_CONFIG; Start-Sleep -Seconds 2 }"
exit /b %errorlevel%
