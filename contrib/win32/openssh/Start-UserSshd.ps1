# Save beside sshd.exe in the extracted OpenSSH-Win64 folder.
# Requires this fork's current-user-only patch; official binaries do not support it.
# Runs a concurrent foreground server without installing a Windows service.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ClientPublicKeyPath,

    [string]$OpenSshDirectory,

    [ValidateRange(1, 65535)]
    [int]$Port = 2000,

    [System.Net.IPAddress]$ListenAddress = '127.0.0.1',

    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this script on Windows.' }

# Resolve the default after parameter binding, with an explicit fallback.
if ([string]::IsNullOrWhiteSpace($OpenSshDirectory)) {
    $OpenSshDirectory = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($OpenSshDirectory) -and $PSCommandPath) {
        $OpenSshDirectory = [IO.Path]::GetDirectoryName($PSCommandPath)
    }
    if ([string]::IsNullOrWhiteSpace($OpenSshDirectory)) {
        $OpenSshDirectory = (Get-Location).Path
    }
}
$OpenSshDirectory = (Resolve-Path -LiteralPath $OpenSshDirectory).Path
$sshd = Join-Path $OpenSshDirectory 'sshd.exe'
$keygen = Join-Path $OpenSshDirectory 'ssh-keygen.exe'
foreach ($exe in @($sshd, $keygen)) {
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "Missing $exe. Keep the entire extracted OpenSSH package together."
    }
}

# Authorize a PUBLIC key from the computer you will connect from.
# Existing Windows authorized_keys files are left untouched.
if (-not (Test-Path -LiteralPath $ClientPublicKeyPath -PathType Leaf)) {
    throw "Public key file not found: $ClientPublicKeyPath"
}
$publicKeys = @(Get-Content -LiteralPath $ClientPublicKeyPath | ForEach-Object {
    $_.Trim()
} | Where-Object { $_ -and -not $_.StartsWith('#') })
if ($publicKeys.Count -eq 0) { throw 'The public-key file is empty.' }
foreach ($key in $publicKeys) {
    if ($key -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/]+={0,2}( .*)?$') {
        throw 'Supply OpenSSH public keys, one per line, without authorized_keys options.'
    }
}
$publicKey = $publicKeys -join "`n"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$login = $identity.Name.ToLowerInvariant()
# OpenSSH canonicalizes local accounts to an unqualified SAM name.
$localPrefix = [Environment]::MachineName.ToLowerInvariant() + '\'
if ($login.StartsWith($localPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    $login = $login.Substring($localPrefix.Length)
}
$state = Join-Path $env:LOCALAPPDATA "OpenSSH-User-$Port"
$null = New-Item -ItemType Directory -Path $state -Force

# Read and write only the DACL through .NET (Windows PowerShell 5.1).
# Set-Acl can try to persist the SACL too, requiring SeSecurityPrivilege.
# Leave the directory's existing owner, group and audit rules untouched.
$stateDirectory = [IO.DirectoryInfo]::new($state)
$acl = $stateDirectory.GetAccessControl(
    [Security.AccessControl.AccessControlSections]::Access)
$acl.SetAccessRuleProtection($true, $false)
$existingRules = @($acl.GetAccessRules(
    $true, $false, [Security.Principal.SecurityIdentifier]))
foreach ($existingRule in $existingRules) {
    $acl.RemoveAccessRuleSpecific($existingRule)
}
foreach ($sid in @($identity.User, [Security.Principal.SecurityIdentifier]'S-1-5-18')) {
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $sid, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
}
$stateDirectory.SetAccessControl($acl)

$authorized = Join-Path $state 'authorized_keys'
$hostKey = Join-Path $state 'ssh_host_ed25519_key'
$config = Join-Path $state 'sshd_config'
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($authorized, "$publicKey`n", $utf8)

if (-not (Test-Path -LiteralPath $hostKey)) {
    # Start-Process preserves an explicit empty passphrase in Windows PS 5.1.
    $process = Start-Process -FilePath $keygen -ArgumentList @(
        '-q', '-t', 'ed25519', '-N', '""', '-f', ('"{0}"' -f $hostKey)
    ) -NoNewWindow -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw 'Host key generation failed.' }
}

$hostKeyConfig = $hostKey.Replace('\', '/')
$authorizedConfig = $authorized.Replace('\', '/')
[IO.File]::WriteAllText($config, @"
Port $Port
ListenAddress $ListenAddress
HostKey "$hostKeyConfig"
AuthorizedKeysFile "$authorizedConfig"
AllowUsers "$login"
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
StrictModes yes
Subsystem sftp internal-sftp
LogLevel VERBOSE

"@, $utf8)

& $sshd -t -f $config
if ($LASTEXITCODE -ne 0) {
    throw 'sshd configuration/key validation failed. See the error above.'
}

if ($ValidateOnly) {
    Write-Host "Validated configuration: $config"
    return
}

Write-Host "Starting concurrent current-user sshd on $ListenAddress port $Port as $login."
Write-Host "Connect through the private network: ssh -i ~/.ssh/windows_ssh -p $Port -l '$login' 100.96.0.4"
Write-Host 'Keep this window open. Press Ctrl+C to stop.'
Write-Warning 'Use the complete patched binary package, including sshd-auth.exe and sshd-session.exe.'

$previousMode = $env:OPENSSH_CURRENT_USER_ONLY
try {
    $env:OPENSSH_CURRENT_USER_ONLY = '1'
    while ($true) {
        & $sshd -D -e -f $config
        Write-Warning "sshd exited with code $LASTEXITCODE; restarting in 2 seconds."
        Start-Sleep -Seconds 2
    }
}
finally {
    $env:OPENSSH_CURRENT_USER_ONLY = $previousMode
}
