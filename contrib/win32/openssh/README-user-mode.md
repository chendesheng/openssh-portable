# Concurrent sshd as the current Windows user

This fork adds an experimental, opt-in current-user mode for a portable Windows
OpenSSH server. It is intended for a standard user who cannot install a service
but needs multiple independent SSH clients on the same port. It preserves the
normal listener/monitor/session processes and native Windows terminal support.

## What changes

Set `OPENSSH_CURRENT_USER_ONLY=1` in the server process environment and start
`sshd -D`, **without** lowercase `-d`. The listener keeps accepting clients.

The Windows spawn path checks that the requested token is the exact current
process primary token, comparing `TOKEN_STATISTICS.TokenId`, before using
`CreateProcessW`. A matching SID alone is insufficient: a restricted token or a
different logon can have the same SID. Failed token queries and differing tokens
are rejected in this mode. SYSTEM spawning uses the existing path.

Authentication additionally checks the requested account's SID against the
process account and rejects other accounts (and SYSTEM). Normal SSH public-key
verification, authorized_keys permissions, AllowUsers/DenyUsers, limits, and
protocol handling remain in force. Use public-key-only authentication: password
or GSS logon tokens can differ from the current process token and are not a
supported way to authenticate in this mode. This does not grant privileges,
change Windows service permissions, or enable logins as other Windows users.

With the environment variable unset, existing service and process-spawning
behavior is unchanged. `-d` still means one connection, even in a Release build.
Untrusted pre-auth workers run as the launcher account in current-user mode;
this is not the SYSTEM service's separate low-privilege virtual account.

## Build from a Mac

Use the **Windows current-user build** GitHub Actions workflow on your fork.
It builds native x64 Release binaries on `windows-2022`; the existing portable
CI's Cygwin builds are not equivalent. The workflow also parses the PowerShell
scripts and runs the compiled server test as a separate, non-administrator local
account. Download the artifact for the exact commit you intend to test.

Alternatively, on a Windows build machine with VS 2022 C++ tools, the Windows
SDK, Spectre libraries and vcpkg integration installed:

```powershell
Import-Module .\contrib\win32\openssh\OpenSSHBuildHelper.psm1 -Force
Start-OpenSSHBuild -Configuration Release -NativeHostArch x64 -Verbose
Start-OpenSSHPackage -Configuration Release -NativeHostArch x64
```

The SDK/build dependencies may require administrator installation on the build
machine. The resulting user-mode server is intended to run as an ordinary user
on the destination computer. Include the whole matching package, not just
`sshd.exe`: `sshd-auth.exe`, `sshd-session.exe`, `ssh-shellhost.exe`, crypto DLLs
and the other helper executables must come from that build.

## Run on Windows without admin

Extract the package into a user-writable directory. Copy `Start-UserSshd.ps1`
beside `sshd.exe`, and supply the connecting clients' public keys, one per line:

```powershell
.\Start-UserSshd.ps1 -ClientPublicKeyPath .\authorized_clients.pub -Port 2000
```

The launcher generates/reuses the host key and writes its isolated config in
`%LOCALAPPDATA%\OpenSSH-User-2000`. The directory grants access to the current
user and SYSTEM. Each run rewrites its generated config and authorized_keys;
edit the input public-key file or launcher parameters instead of those outputs.
Use `-ValidateOnly` to generate/check that configuration without starting a
listener. Local account names are normalized to OpenSSH's unqualified SAM form.
Existing `%USERPROFILE%\.ssh\authorized_keys` is not changed. Do not put client
private keys on the server.

The default listener is `127.0.0.1:2000`, which works with the existing sing-box
mapping `100.96.0.4:PORT -> 127.0.0.1:PORT`. No VPS or WireGuard changes are
needed. Multiple phones/computers can connect using that same port and Windows
account, each with an authorized key. To deliberately allow LAN connections,
use `-ListenAddress 0.0.0.0`; Windows Firewall must already permit the connection.

To use an existing private config directly:

```powershell
$env:OPENSSH_CURRENT_USER_ONLY = '1'
.\sshd.exe -t -f "$env:LOCALAPPDATA\OpenSSH-User-2000\sshd_config"
.\sshd.exe -D -e -f "$env:LOCALAPPDATA\OpenSSH-User-2000\sshd_config"
```

Use a non-elevated console for testing. Keep it open; Ctrl+C stops the listener.
The launcher restarts after server exit, not after every connection. No startup
task or Windows service is installed. Back up the state directory privately to
preserve the host key/fingerprint when restoring this Windows installation.

## Verify

Run `Test-UserSshd.ps1 -OpenSshDirectory <extracted-package>` from an ordinary
Windows account. It refuses an elevated/SYSTEM context and uses temporary keys,
config, loopback listener and an isolated port. It validates and uses the actual
launcher's generated config with two authorized client keys. It requires two independent SSH
connections to succeed concurrently, verifies the returned Windows identity,
forces a PTY session, rejects an unauthorized client key, and checks that the
listener survives session completion. Test-only private material is deleted.

Also test the actual Mac and phone simultaneously, SFTP and the intended terminal
application. Keep one client connected while starting the other; connection
sharing is not a concurrency test. Confirm only the intended Windows account
can authenticate. The original OpenSSH/Windows build, runner OS and exact commit
must accompany any reported result; a source review or successful compilation
alone is not runtime proof.

## Rollback

Keep the previous official package and launcher separately. Stop the test server
before restoring it, preserve its private state/host key, and unset
`OPENSSH_CURRENT_USER_ONLY`. The old debug launcher will again serve one
connection at a time. Do not install the experimental binaries over a working
SYSTEM service. No change to VPS exit routing, sing-box credentials or WireGuard
peer enrollment is part of this experiment.

## Recorded checks (2026-10-29)

The first Windows workflow run (commit `b2e2251`) built native x64 Release
binaries successfully. Its integration wrapper incorrectly treated a null child
exit code as success; the test actually stopped during key generation, so that
run does **not** prove non-admin concurrency. The corrected harness retains
process handles and requires a result JSON containing the expected standard-user
SID plus a completion marker after all checks. Record the corrected run's
result here once it completes.
Portable API-double tests also exercise restricted/different token rejection,
failed queries, token ownership and the default/SYSTEM paths; these are not
substitutes for Windows runtime tests. The user's Windows installation and
phone/Mac clients have not been tested with these experimental binaries.
