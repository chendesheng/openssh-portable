[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OpenSshDirectory,
    [string]$OtherUser,
    [string]$ResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'This test needs Windows.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if ($identity.IsSystem -or $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this test as a standard, non-administrator account.'
}
$OpenSshDirectory = (Resolve-Path -LiteralPath $OpenSshDirectory).Path
$sshd = Join-Path $OpenSshDirectory 'sshd.exe'
$ssh = Join-Path $OpenSshDirectory 'ssh.exe'
$keygen = Join-Path $OpenSshDirectory 'ssh-keygen.exe'
$state = Join-Path $env:TEMP ('sshd-user-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $state
$directory = [IO.DirectoryInfo]::new($state)
$acl = $directory.GetAccessControl([Security.AccessControl.AccessControlSections]::Access)
$acl.SetAccessRuleProtection($true, $false)
foreach ($rule in @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))) {
    $acl.RemoveAccessRuleSpecific($rule)
}
foreach ($sid in @($identity.User, [Security.Principal.SecurityIdentifier]'S-1-5-18')) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $sid, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
}
$directory.SetAccessControl($acl)
$utf8 = [Text.UTF8Encoding]::new($false)
$processes = [Collections.Generic.List[Diagnostics.Process]]::new()
$previousMode = $env:OPENSSH_CURRENT_USER_ONLY

# Start-Process -PassThru in Windows PowerShell can return a Process without
# a retained handle/exit code. Start through .NET and drain output using C#
# handlers (PowerShell scriptblocks cannot run on these background threads).
if (-not ('OpenSshUserModeNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
public static class OpenSshUserModeNative {
    private static readonly Dictionary<Process, StreamWriter[]> Writers = new Dictionary<Process, StreamWriter[]>();
    public static Process Start(string file, string arguments, string output, string error) {
        Process p = new Process();
        p.StartInfo = new ProcessStartInfo(file, arguments);
        p.StartInfo.UseShellExecute = false;
        p.StartInfo.CreateNoWindow = true;
        p.StartInfo.RedirectStandardInput = true;
        p.StartInfo.RedirectStandardOutput = true;
        p.StartInfo.RedirectStandardError = true;
        StreamWriter stdout = new StreamWriter(new FileStream(output, FileMode.Create, FileAccess.Write, FileShare.ReadWrite), new UTF8Encoding(false));
        StreamWriter stderr = new StreamWriter(new FileStream(error, FileMode.Create, FileAccess.Write, FileShare.ReadWrite), new UTF8Encoding(false));
        stdout.AutoFlush = stderr.AutoFlush = true;
        p.OutputDataReceived += (sender, data) => { if (data.Data != null) { lock (stdout) { stdout.WriteLine(data.Data); } } };
        p.ErrorDataReceived += (sender, data) => { if (data.Data != null) { lock (stderr) { stderr.WriteLine(data.Data); } } };
        try {
            p.Start();
            Writers.Add(p, new StreamWriter[] { stdout, stderr });
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            p.StandardInput.Close();
            return p;
        } catch {
            stdout.Dispose(); stderr.Dispose(); p.Dispose(); throw;
        }
    }
    public static string ReadLiveFile(string path) {
        using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        using (StreamReader reader = new StreamReader(stream, Encoding.UTF8)) {
            return reader.ReadToEnd();
        }
    }
    public static void Drain(Process p) {
        p.WaitForExit();
        StreamWriter[] output;
        if (Writers.TryGetValue(p, out output)) {
            Writers.Remove(p);
            output[0].Dispose(); output[1].Dispose();
        }
    }
}
'@
}

function Quote-NativeArgument([string]$Value) {
    '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
function Start-Native([string]$File, [string[]]$Arguments, [string]$Name) {
    $commandLine = ($Arguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' '
    $p = [OpenSshUserModeNative]::Start($File, $commandLine,
        (Join-Path $state ($Name + '.out')), (Join-Path $state ($Name + '.err')))
    $processes.Add($p)
    return $p
}
function Wait-Success([Diagnostics.Process]$Process, [int]$Seconds = 15) {
    if (-not $Process.WaitForExit($Seconds * 1000)) { throw 'Child process timed out.' }
    [OpenSshUserModeNative]::Drain($Process)
    if ($Process.ExitCode -ne 0) { throw "Child process failed: $($Process.ExitCode)" }
}
function Encode-Command([string]$Source) {
    'powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand ' +
        [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Source))
}
try {
    $env:OPENSSH_CURRENT_USER_ONLY = '1'
    foreach ($name in @('client', 'second-client', 'unauthorized')) {
        Wait-Success (Start-Native $keygen @('-q', '-t', 'ed25519', '-N', '', '-f', (Join-Path $state $name)) $name)
    }
    $authorized = Join-Path $state 'authorized_clients.pub'
    $keys = [IO.File]::ReadAllText((Join-Path $state 'client.pub')).Trim() + "`n" +
        [IO.File]::ReadAllText((Join-Path $state 'second-client.pub')).Trim() + "`n"
    [IO.File]::WriteAllText($authorized, $keys, $utf8)
    $reservation = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $reservation.Start()
    $port = $reservation.LocalEndpoint.Port
    $reservation.Stop()
    $login = $identity.Name.ToLowerInvariant()
    # Exercise the production launcher's ACLs, multi-key parsing and local SAM
    # normalization; keep its generated files isolated from the user's settings.
    $escapedState = $state.Replace("'", "''")
    $escapedPackage = $OpenSshDirectory.Replace("'", "''")
    $escapedKeys = $authorized.Replace("'", "''")
    $launcherCommand = Encode-Command "`$env:LOCALAPPDATA = '$escapedState'; & '$escapedPackage\Start-UserSshd.ps1' -OpenSshDirectory '$escapedPackage' -ClientPublicKeyPath '$escapedKeys' -Port $port -ValidateOnly"
    $encodedLauncher = $launcherCommand.Substring($launcherCommand.LastIndexOf(' ') + 1)
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Wait-Success (Start-Native $powershell @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedLauncher) 'launcher')
    $config = Join-Path $state "OpenSSH-User-$port\sshd_config"
    Wait-Success (Start-Native $sshd @('-t', '-f', $config) 'validate')
    # Uppercase -D is essential: two separate connections must be accepted.
    $server = Start-Native $sshd @('-D', '-e', '-f', $config) 'server'
    $ready = $false
    for ($i = 0; $i -lt 100 -and -not $ready; $i++) {
        if ($server.HasExited) { throw 'The foreground listener exited.' }
        $probe = [Net.Sockets.TcpClient]::new()
        try {
            $probe.Connect('127.0.0.1', $port)
            $ready = $true
        } catch { Start-Sleep -Milliseconds 100 }
        finally { $probe.Dispose() }
    }
    if (-not $ready) { throw 'Listener did not become ready.' }
    $common = @('-n', '-p', "$port", '-i', (Join-Path $state 'client'),
        '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
        '-o', 'ControlMaster=no', '-o', 'ControlPath=none',
        '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL',
        '-l', $login, '127.0.0.1')
    $marker = Join-Path $state 'first-ready'
    $escapedMarker = $marker.Replace("'", "''")
    $firstCommand = Encode-Command "[IO.File]::WriteAllText('$escapedMarker', 'ready'); Start-Sleep -Seconds 30; whoami"
    $first = Start-Native $ssh ($common + @($firstCommand)) 'first'
    for ($i = 0; $i -lt 150 -and -not (Test-Path -LiteralPath $marker); $i++) {
        if ($first.HasExited) { throw 'First client exited before its session was ready.' }
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $marker)) { throw 'First authenticated session never became ready.' }
    # A separate process/TCP connection, explicitly without ControlMaster.
    $secondArgs = @($common)
    $secondKeyIndex = [array]::IndexOf($secondArgs, '-i') + 1
    $secondArgs[$secondKeyIndex] = Join-Path $state 'second-client'
    $ptyArgs = @('-tt') + $secondArgs + @((Encode-Command 'whoami'))
    $second = Start-Native $ssh $ptyArgs 'second'
    Wait-Success $second
    if ($first.HasExited) { throw 'The two authenticated clients did not overlap.' }
    $returnedIdentity = [IO.File]::ReadAllText((Join-Path $state 'second.out')).ToLowerInvariant()
    if (-not $returnedIdentity.Contains($login)) { throw 'PTY session ran as the wrong account.' }
    Write-Output 'PASS: two authorized client keys, concurrent independent clients and PTY run as the standard user.'
    $badArgs = @($common)
    $keyIndex = [array]::IndexOf($badArgs, '-i') + 1
    $badArgs[$keyIndex] = Join-Path $state 'unauthorized'
    $bad = Start-Native $ssh ($badArgs + @('whoami')) 'bad-key'
    if (-not $bad.WaitForExit(15000)) { throw 'Unauthorized-key test timed out.' }
    if ($bad.ExitCode -eq 0) { throw 'An unauthorized client key was accepted.' }
    Write-Output 'PASS: unauthorized client key rejected.'
    if ($OtherUser) {
        $otherArgs = @($common)
        $loginIndex = [array]::IndexOf($otherArgs, '-l') + 1
        $otherArgs[$loginIndex] = $OtherUser
        $other = Start-Native $ssh ($otherArgs + @('whoami')) 'other-user'
        if (-not $other.WaitForExit(15000)) { throw 'Other-account test timed out.' }
        if ($other.ExitCode -eq 0) { throw 'A different account was accepted.' }
        $guardSeen = $false
        for ($i = 0; $i -lt 50 -and -not $guardSeen; $i++) {
            $serverLog = [OpenSshUserModeNative]::ReadLiveFile((Join-Path $state 'server.err'))
            $guardSeen = $serverLog.Contains('not allowed by current-user-only mode')
            if (-not $guardSeen) { Start-Sleep -Milliseconds 100 }
        }
        if (-not $guardSeen) {
            throw 'The explicit account restriction was not exercised.'
        }
        Write-Output 'PASS: another enabled account is rejected by the current-user-only guard.'
    }
    Wait-Success $first 45
    $third = Start-Native $ssh ($common + @('whoami')) 'third'
    Wait-Success $third
    if ($server.HasExited) { throw 'Listener stopped after a completed session.' }
    Write-Output 'PASS: the listener continues accepting clients after sessions exit.'
}
catch {
    foreach ($log in Get-ChildItem -LiteralPath $state -File | Where-Object { $_.Extension -in '.out', '.err' }) {
        Write-Output "--- $($log.Name) ---"
        Get-Content -LiteralPath $log.FullName -Tail 100
    }
    throw
}
finally {
    foreach ($p in $processes) {
        if (-not $p.HasExited) { & "$env:SystemRoot\System32\taskkill.exe" /PID $p.Id /T /F 2>$null | Out-Null }
        [OpenSshUserModeNative]::Drain($p)
        $p.Dispose()
    }
    $env:OPENSSH_CURRENT_USER_ONLY = $previousMode
    Remove-Item -LiteralPath $state -Recurse -Force
}

# A machine-readable result prevents a missing/null child exit code from
# making the elevated CI wrapper report a false success. Reached only after
# all checks and cleanup complete successfully.
if ($ResultPath) {
    $result = @{ passed = $true; sid = $identity.User.Value; administrator = $false; clients = 2; authorizedKeys = 2 }
    [IO.File]::WriteAllText($ResultPath, ($result | ConvertTo-Json), $utf8)
}
Write-Output 'ALL_USER_MODE_TESTS_PASSED'
