<#
.SYNOPSIS
    run.ps1 - manage a recurring sovereign agent on Ritual testnet (chain 1979).
    Commands: deploy (default), view, topup. Windows companion to run.sh. Runs on
    Windows PowerShell 5.1+ or pwsh 7. Auto-installs foundry + uv.
#>
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

# cast "reverts" exit non-zero by design and the script reads that via $LASTEXITCODE / empty output,
# so opt out of PowerShell 7.4+ turning native non-zero exits into terminating errors. Harmless on 5.1.
$PSNativeCommandUseErrorActionPreference = $false

# Script directory. $PSScriptRoot is normally set, but is empty when the script is piped to stdin
# or dot-sourced oddly - fall back to the invocation path, then the current directory, so .env and
# the keystore lookups never resolve against a bare "\".
$HERE = $PSScriptRoot
if (-not $HERE -and $MyInvocation.MyCommand.Path) { $HERE = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $HERE) { $HERE = (Get-Location).Path }

# Windows PowerShell 5.1 hardening (harmless on pwsh 7): force TLS 1.2 (5.1 defaults to TLS 1.0 and
# fails against GitHub/astral) and silence the slow Invoke-WebRequest progress bar.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

# Switch the console to UTF-8 so the braille spinner glyphs render. Windows PowerShell 5.1 defaults
# to the OEM code page (cp437/1252), which turns them into mojibake. Wrapped in try/catch because
# setting this throws when stdout is redirected to a file.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# Enable ANSI/VT escape interpretation on the Windows console. pwsh 7 and Windows Terminal do this
# already; legacy conhost (powershell.exe) does not, so without this the color and cursor-hide codes
# print literally as "<-[38;5;141m". Returns $true when ANSI sequences will be honoured.
function Enable-AnsiOutput {
    # Non-Windows pwsh always honours ANSI on a tty.
    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { return $true }
    try {
        if (-not ('Ritual.Vt' -as [type])) {
            Add-Type -Namespace Ritual -Name Vt -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern System.IntPtr GetStdHandle(int nStdHandle);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetConsoleMode(System.IntPtr handle, out uint mode);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleMode(System.IntPtr handle, uint mode);
'@ | Out-Null
        }
        $h = [Ritual.Vt]::GetStdHandle(-11)  # STD_OUTPUT_HANDLE
        if ($h -eq [System.IntPtr]::Zero -or $h -eq [System.IntPtr]::new(-1)) { return $false }
        [uint32]$mode = 0
        if (-not [Ritual.Vt]::GetConsoleMode($h, [ref]$mode)) { return $false }  # not a real console
        $ENABLE_VT = [uint32]0x0004
        if (($mode -band $ENABLE_VT) -ne 0) { return $true }
        return [Ritual.Vt]::SetConsoleMode($h, ($mode -bor $ENABLE_VT))
    } catch { return $false }
}

# Write UTF-8 without a BOM. 5.1's `Set-Content -Encoding UTF8` prepends a BOM, which corrupts the
# first .env line when run.sh reads it back.
function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))
}

### ---------- look and feel ----------
# Color only when stdout is a real console, the console honours ANSI, and NO_COLOR is not set.
$ESC = [char]27
$script:AnsiOk = Enable-AnsiOutput
$script:UseColor = $script:AnsiOk -and (-not [Console]::IsOutputRedirected) -and (-not $env:NO_COLOR)

# Braille spinner glyphs need both a UTF-8 console and a font that carries them. pwsh 7, Windows
# Terminal and any Unix tty have both; legacy conhost under powershell.exe usually lacks the glyphs
# and shows blanks, so fall back to an ASCII spinner there.
$script:Unicode = [Console]::OutputEncoding.CodePage -eq 65001 -and
                  ($PSVersionTable.PSVersion.Major -ge 6 -or [bool]$env:WT_SESSION)
if ($UseColor) {
    $RESET = "$ESC[0m"; $BOLD = "$ESC[1m"; $DIM = "$ESC[2m"; $CLR = "$ESC[K"
    $ACCENT = "$ESC[38;5;141m"; $OKC = "$ESC[38;5;78m"; $BADC = "$ESC[38;5;203m"
    $WARNC = "$ESC[38;5;214m"; $MUTED = "$ESC[38;5;244m"; $HIDE = "$ESC[?25l"; $SHOW = "$ESC[?25h"
} else {
    $RESET = $BOLD = $DIM = $CLR = $ACCENT = $OKC = $BADC = $WARNC = $MUTED = $HIDE = $SHOW = ''
}

function Fail([string]$m) { Write-Host ""; Write-Host "  ${BADC}ERROR$RESET $m"; exit 1 }
function Hr { Write-Host "  $MUTED--------------------------------------------$RESET" }

# Paint a short string letter by letter through a purple-to-pink ramp.
function Gradient([string]$t) {
    if (-not $UseColor) { return $t }
    $ramp = 99, 105, 141, 147, 183, 219, 213
    $sb = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $t.Length; $i++) { [void]$sb.Append("$ESC[1;38;5;$($ramp[$i % $ramp.Count])m$($t[$i])") }
    [void]$sb.Append($RESET); return $sb.ToString()
}

$script:BannerShown = $false
function Banner {
    if ($script:BannerShown) { return }; $script:BannerShown = $true
    Write-Host ""; Write-Host "  $(Gradient 'RITUAL SOVEREIGN AGENT')"
    Write-Host "  ${DIM}recurring keyless agent - Ritual testnet (1979)$RESET"
    Write-Host "  ${MUTED}built by Zun  ${ACCENT}https://x.com/Zun2025$RESET"; Hr
}
function Step([string]$m) { Write-Host ""; Write-Host "  $ACCENT>$RESET $BOLD$m$RESET" }
function Info([string]$m) { Write-Host "    $MUTED$m$RESET" }
function Ok([string]$m)   { Write-Host "  ${OKC}ok$RESET $m" }
function Warn([string]$m) { Write-Host "  $WARNC!$RESET  $m" }
function Kv([string]$k, [string]$v) { Write-Host ("  $MUTED{0,-11}$RESET {1}" -f $k, $v) }

# Run a process behind a spinner; output is captured and shown only on failure, and left in
# $script:SpinOut. $Retries re-runs the command that many times (for flaky network steps).
$script:SpinOut = ''
function Spin {
    param([string]$Msg, [string]$Exe, [string[]]$CmdArgs, [int]$Retries = 1)
    $errtxt = ''
    $frames = if ($script:Unicode) { [char[]](0x280B, 0x2819, 0x2839, 0x2838, 0x283C, 0x2834, 0x2826, 0x2827, 0x2807, 0x280F) }
              else { [char[]]('|', '/', '-', '\') }
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $resolved = Get-Command $Exe -ErrorAction SilentlyContinue
        $psi.FileName = if ($resolved) { $resolved.Source } else { $Exe }
        foreach ($a in $CmdArgs) { [void]$psi.ArgumentList.Add($a) }
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        # drain both pipes concurrently so a noisy installer cannot deadlock on a full buffer
        $outT = $p.StandardOutput.ReadToEndAsync(); $errT = $p.StandardError.ReadToEndAsync()
        if ($UseColor) {
            [Console]::Write($HIDE); $i = 0
            while (-not $p.HasExited) {
                [Console]::Write("`r  $ACCENT$($frames[$i % $frames.Length])$RESET $Msg")
                Start-Sleep -Milliseconds 80; $i++
            }
            [Console]::Write($SHOW)
        } else { Write-Host "  $Msg ..." -NoNewline }
        $p.WaitForExit()
        $script:SpinOut = $outT.Result; $errtxt = $errT.Result
        if ($p.ExitCode -eq 0) {
            if ($UseColor) { Write-Host "`r  ${OKC}ok$RESET $Msg$CLR" } else { Write-Host " ok" }
            return
        }
        if ($attempt -lt $Retries) {
            if ($UseColor) { Write-Host "`r  ${WARNC}~$RESET $Msg (retry $($attempt + 1)/$Retries)$CLR" } else { Write-Host " (retry $($attempt + 1)/$Retries)" }
            Start-Sleep -Seconds 1
        }
    }
    if ($UseColor) { Write-Host "`r  ${BADC}x$RESET $Msg$CLR" } else { Write-Host " failed" }
    (("$script:SpinOut`n$errtxt") -split "`n") | ForEach-Object { if ($_.Trim()) { Write-Host "      $_" } }
    Fail "step failed: $Msg"
}

function Show-Usage {
    Banner
    Write-Host "  ${BOLD}Usage$RESET  pwsh run.ps1 [command] [args]"
    Write-Host ""
    Write-Host "  ${ACCENT}deploy$RESET                    deploy + fund + arm (shows your agents, then asks before adding another)"
    Write-Host "  ${ACCENT}view$RESET [eoa]                list every agent an EOA deployed: live/dead + stuck RITUAL"
    Write-Host "  ${ACCENT}topup$RESET [address] [amount]  deposit more RITUAL into an agent's wallet"
    Write-Host "  ${ACCENT}help$RESET                      show this help"
    Write-Host ""
    Write-Host "  view defaults to your own wallet. topup with no address -> the agent for SALT in .env."
    Write-Host "  Amounts are in RITUAL. Lock duration: LOCK_BLOCKS (default 100000)."
    Write-Host ""
    Write-Host "  ${MUTED}Note: stop/restart/withdraw are not exposed - a bug in Ritual's proxy contract makes"
    Write-Host "  them revert today. They should work once the Ritual team upgrades the proxy.$RESET"
}

# command + optional positional arg (no param() block so leading '--' is not eaten)
$CMD = if ($args.Count -ge 1) { ([string]$args[0]) -replace '^--', '' } else { 'deploy' }
$ARG1 = if ($args.Count -ge 2) { [string]$args[1] } else { $null }
$ARG2 = if ($args.Count -ge 3) { [string]$args[2] } else { $null }
if ($CMD -in @('help', '-h', '')) { Show-Usage; exit 0 }

if (-not (Test-Path "$HERE\.env")) { Fail ".env not found. Run: copy .env.example .env  then edit it." }

# Load .env: skip blank lines and comments, strip surrounding quotes from values
Get-Content "$HERE\.env" | ForEach-Object {
    if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$' -and $_ -notmatch '^\s*#') {
        $val = $Matches[2] -replace '^[\"'']|[\"'']$'
        [System.Environment]::SetEnvironmentVariable($Matches[1], $val, 'Process')
    }
}

# Ritual testnet system contracts
$FACTORY       = "0x9dC4C054e53bCc4Ce0A0Ff09E890A7a8e817f304"
$RITUAL_WALLET = "0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948"
$SCHEDULER     = "0x56e776bae2dd60664b69bd5f865f1180ffb7d58b"
$env:REGISTRY  = "0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F"
$LOCK_BLOCKS   = if ($env:LOCK_BLOCKS) { $env:LOCK_BLOCKS } else { "100000" }
$env:LOCK_BLOCKS = $LOCK_BLOCKS

# A sovereign run costs ~0.5-1 RITUAL (varies by model, iterations, tool calls). Require at least
# 1 RITUAL per deploy so a wake can be funded; below that the job is under-funded and silently
# dropped. Enforced on deploy only - top-ups are additive, so any amount is fine.
$MIN_DEPOSIT_WEI = "1000000000000000000"   # 1 RITUAL
function Need-Deposit { if (-not $env:DEPOSIT) { Fail "DEPOSIT is required (in RITUAL, e.g. DEPOSIT=1)" } }
function Require-MinDeposit {
  if (-not $env:DEPOSIT_WEI) { Fail "DEPOSIT is required (in RITUAL, e.g. DEPOSIT=1)" }
  if ([bigint]$env:DEPOSIT_WEI -lt [bigint]$MIN_DEPOSIT_WEI) {
    Fail "DEPOSIT=$($env:DEPOSIT) RITUAL is below the 1 RITUAL minimum. A run costs ~0.5-1 RITUAL; fund at least 1 (5 recommended)."
  }
}
function Num([string]$s) { ($s -split ' ')[0] }  # strip cast's trailing "[1.5e16]" label

# wei -> RITUAL string, truncated to 6 decimals. String-only (no number parse), so it stays correct
# regardless of the locale's decimal separator; cast always emits a '.'-separated value.
function Format-Rit([string]$wei) {
    $p = (& cast to-unit $wei ether) -split '\.', 2
    $frac = "$($p[1])000000"
    "$($p[0]).$($frac.Substring(0, 6))"
}

# Run a read-only cast call, retrying on empty output (the public RPC can be flaky).
function Invoke-Rpc([string[]]$RpcArgs) {
    for ($i = 1; $i -le 3; $i++) {
        $out = (& cast @RpcArgs 2>$null)
        if ($out) { return (($out | Out-String).Trim()) }
        Start-Sleep -Seconds 1
    }
    return ''
}
function Test-Addr([string]$s) { return ($s -match '^0x[0-9a-fA-F]{40}$') }
function Get-Harness([string]$us) {
    ((Invoke-Rpc @('call', $FACTORY, 'predictHarness(address,bytes32)(address,bytes32)', $env:WALLET_ADDRESS, $us, '--rpc-url', $env:RPC_URL)) -split "`n")[0].Trim()
}

### ---------- keystore signer ----------
$script:KS_PASSWORD = ''

# Read a password showing one '*' per char (backspace supported).
function Read-Masked([string]$prompt) {
    Write-Host -NoNewline $prompt
    $sb = [System.Text.StringBuilder]::new()
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'Enter') { Write-Host ''; break }
        elseif ($k.Key -eq 'Backspace') { if ($sb.Length -gt 0) { $sb.Length--; Write-Host -NoNewline "`b `b" } }
        elseif ($k.KeyChar) { [void]$sb.Append($k.KeyChar); Write-Host -NoNewline '*' }
    }
    return $sb.ToString()
}

# Set or replace KEY=VALUE in .env so the name and address persist across runs.
function Set-EnvVar([string]$k, [string]$v) {
    $f = "$HERE\.env"
    $lines = if (Test-Path $f) { @(Get-Content $f) } else { @() }
    if ($lines -match "^$k=") {
        $lines = $lines | ForEach-Object { if ($_ -match "^$k=") { "$k=$v" } else { $_ } }
    } else { $lines = @($lines) + "$k=$v" }
    Write-Utf8NoBom $f (($lines -join "`r`n") + "`r`n")
}

# First run: ask name + key + password, create the encrypted keystore, save name + address.
function Import-Keystore {
    Banner
    Step "Set up your wallet keystore"
    $name = $env:KEYSTORE_ACCOUNT
    if (-not $name) { $name = Read-Host "  name for your keystore [ritual-deployer]"; if (-not $name) { $name = "ritual-deployer" } }
    if (Test-Path (Join-Path "$HOME\.foundry\keystores" $name)) {   # name already exists -> adopt it
        $env:KEYSTORE_ACCOUNT = $name; Set-EnvVar "KEYSTORE_ACCOUNT" $name
        Unlock
        $env:WALLET_ADDRESS = (& cast wallet address --account $name --password $script:KS_PASSWORD 2>$null)
        if (-not $env:WALLET_ADDRESS) { Fail "wrong keystore password" }
        Set-EnvVar "WALLET_ADDRESS" $env:WALLET_ADDRESS
        Ok "using existing keystore '$name' for $env:WALLET_ADDRESS"; return
    }
    $key = Read-Masked "  paste your wallet private key: "
    if (-not $key) { Fail "no private key entered" }
    if ($key -notmatch '^0x') { $key = "0x$key" }
    $p1 = ''
    for ($i = 1; $i -le 3; $i++) {
        $p1 = Read-Masked "  set a keystore password: "
        $p2 = Read-Masked "  confirm password: "
        if ($p1 -and $p1 -eq $p2) { break }
        if (-not $p1) { Warn "empty password ($i/3)" } else { Warn "passwords do not match ($i/3)" }
        $p1 = ''
    }
    if (-not $p1) { Fail "could not set a password after 3 tries" }
    Spin "creating encrypted keystore" "cast" @('wallet', 'import', $name, '--private-key', $key, '--unsafe-password', $p1)
    $env:WALLET_ADDRESS = (& cast wallet address --private-key $key 2>$null)
    if (-not $env:WALLET_ADDRESS) { Fail "invalid private key" }
    $env:KEYSTORE_ACCOUNT = $name; $script:KS_PASSWORD = $p1
    Set-EnvVar "KEYSTORE_ACCOUNT" $name
    Set-EnvVar "WALLET_ADDRESS" $env:WALLET_ADDRESS
    Ok "keystore '$name' ready for $env:WALLET_ADDRESS"
}

# Ensure a keystore + public address exist (import on first run). Reads never need the password.
function Resolve-Signer {
    $name = $env:KEYSTORE_ACCOUNT
    if (-not $name -or -not (Test-Path (Join-Path "$HOME\.foundry\keystores" $name))) { Import-Keystore; return }
    $env:KEYSTORE_ACCOUNT = $name
    if (-not $env:WALLET_ADDRESS) {
        Unlock
        $env:WALLET_ADDRESS = (& cast wallet address --account $name --password $script:KS_PASSWORD 2>$null)
        if (-not $env:WALLET_ADDRESS) { Fail "wrong keystore password" }
        Set-EnvVar "WALLET_ADDRESS" $env:WALLET_ADDRESS
    }
}

# Ask the keystore password once per run (masked) and verify it decrypts the keystore.
function Unlock {
    if ($script:KS_PASSWORD) { return }
    for ($i = 1; $i -le 3; $i++) {
        $pw = Read-Masked "  keystore password: "
        & cast wallet address --account $env:KEYSTORE_ACCOUNT --password $pw 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $script:KS_PASSWORD = $pw; return }
        Warn "wrong password ($i/3)"
    }
    Fail "wrong keystore password after 3 tries"
}

# Next salt for a fresh agent: bump a trailing number, else append -2 (agent-1 -> agent-2).
function Next-Salt([string]$s) {
    if ($s -match '^(.*[^0-9])([0-9]+)$') { return $Matches[1] + ([int]$Matches[2] + 1) }
    elseif ($s -match '^([0-9]+)$') { return [string]([int]$s + 1) }
    else { return "$s-2" }
}

# Fixed gas for configureFundAndStart. Ritual's estimateGas lies here (~192M for a call that really
# uses ~2.1M), so we ignore it - a real deploy went through on 3.5M. 5M leaves room and stays
# well under the 200M block limit. The cast call below still catches a genuinely bad request.
$SCHED_GAS = "5000000"

### ---------- prerequisites (auto-install, no prompts) ----------
# Foundry lands in ~/.foundry/bin, uv in ~/.local/bin. Put both on PATH for this run...
function Ensure-PathNow {
    foreach ($d in @("$HOME\.foundry\bin", "$HOME\.local\bin")) {
        if (($env:PATH -split ';') -notcontains $d) { $env:PATH = "$d;$env:PATH" }
    }
}
# ...and once in the User PATH so future shells see it too (idempotent).
function Persist-Path([string]$Dir) {
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if (($userPath -split ';') -notcontains $Dir) {
        [Environment]::SetEnvironmentVariable('PATH', "$Dir;$userPath", 'User')
    }
}

function Install-Foundry {
    Step "Installing Foundry (cast, forge)"
    # Download the official Windows binaries directly - no Git Bash / foundryup needed. The
    # win32_amd64 zip is flat (forge/cast/anvil/chisel .exe), extracted straight into ~/.foundry/bin.
    $ps = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { (Get-Command powershell).Source }
    # The "stable" tag has a fixed, version-less asset URL, so no GitHub API call is needed.
    $dl = @'
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$binDir = "$HOME\.foundry\bin"
New-Item -ItemType Directory -Force $binDir | Out-Null
$zip = Join-Path $env:TEMP "foundry_win_amd64.zip"
$url = "https://github.com/foundry-rs/foundry/releases/download/stable/foundry_stable_win32_amd64.zip"
Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
Expand-Archive -Path $zip -DestinationPath $binDir -Force
Remove-Item $zip -Force
'@
    Spin "download foundry binaries (forge, cast)" $ps @('-NoProfile', '-Command', $dl) 3
    Ensure-PathNow
    Persist-Path "$HOME\.foundry\bin"
}

function Install-Uv {
    Step "Installing uv"
    $ps = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { (Get-Command powershell).Source }
    # Pin UV_INSTALL_DIR so uv lands in the exact directory Ensure-PathNow / Persist-Path add to PATH.
    # The installer otherwise defaults there too, but pinning makes the two halves provably agree.
    $uvScript = @'
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$env:UV_INSTALL_DIR = "$HOME\.local\bin"
irm https://astral.sh/uv/install.ps1 | iex
'@
    Spin "fetch + install uv" $ps @('-NoProfile', '-Command', $uvScript) 3
    Ensure-PathNow
    Persist-Path "$HOME\.local\bin"
}

function Ensure-Tools {
    Ensure-PathNow
    if (-not (Get-Command cast -ErrorAction SilentlyContinue) -or -not (Get-Command forge -ErrorAction SilentlyContinue)) { Install-Foundry }
    if (-not (Get-Command uv -ErrorAction SilentlyContinue)) { Install-Uv }
    Ensure-PathNow
    foreach ($b in 'cast', 'forge', 'uv') {
        if (-not (Get-Command $b -ErrorAction SilentlyContinue)) { Fail "$b still missing after install - open a new shell and retry" }
    }
}

# install tools, then ensure a keystore + public address exist (imports your wallet on first run)
Ensure-Tools
Resolve-Signer

# DEPOSIT is given in whole RITUAL (DEPOSIT=1 -> 1 RITUAL, decimals like 0.5 ok). Convert to wei once
# cast is on PATH; everything downstream (min-check, deploy, value flags) works in wei.
if ($env:DEPOSIT) {
    $env:DEPOSIT_WEI = (& cast to-wei $env:DEPOSIT ether 2>$null)
    if (-not $env:DEPOSIT_WEI) { Fail "DEPOSIT=$($env:DEPOSIT) is not a valid RITUAL amount (use a number like 1 or 0.5)" }
}

# deterministic harness address (also the delivery target) - needed by every command
$SALT_VAL = if ($env:SALT) { $env:SALT } else { "ritual-agent-1" }
$USERSALT = (& cast keccak $SALT_VAL).Trim()
$env:HARNESS = Get-Harness $USERSALT

function Test-Deployed { (Invoke-Rpc @('code', $env:HARNESS, '--rpc-url', $env:RPC_URL)).Length -gt 2 }

# Alive = the Scheduler still holds a scheduled wake for this agent. The Scheduler's calls(callId)
# reverts once a call is gone, so a non-empty read on the agent's current or next callId means it is
# still armed. A dead agent has no callId left and cannot be revived, so a deposit would just be stuck.
function Test-Alive([string]$h) {
    foreach ($getter in @('0x618abb34', '0x61f32724')) {
        $w = (Invoke-Rpc @('call', $h, $getter, '--rpc-url', $env:RPC_URL)) -replace '^0x', ''
        if (-not $w -or $w -notmatch '[1-9a-fA-F]') { continue }   # missing / all-zero callId
        if (Invoke-Rpc @('call', $SCHEDULER, "0xd183ce14$w", '--rpc-url', $env:RPC_URL)) { return $true }
    }
    return $false
}

# Live = a contract is deployed at this harness AND it has already been configured.
function Test-Live([string]$h) {
    if ((Invoke-Rpc @('code', $h, '--rpc-url', $env:RPC_URL)).Length -le 2) { return $false }
    return ((Invoke-Rpc @('call', $h, 'configured()(bool)', '--rpc-url', $env:RPC_URL)) -eq "true")
}

# Embedded scanner (stdlib-only Python, run through uv): discovers EVERY sovereign agent an EOA
# deployed by walking the chain indexer, then marks each LIVE or DEAD and reads the RITUAL still
# stuck in its RitualWallet. Replaces the old salt-guessing enumeration.
$SCAN_PY = @'
import json, os, sys, urllib.request, urllib.error, datetime
RPC     = os.environ.get("RPC_URL", "https://rpc.ritualfoundation.org")
INDEXER = "https://explorer.ritualfoundation.org/api/indexer-proxy/api/v1"
FACTORY = "0x9dc4c054e53bcc4ce0a0ff09e890a7a8e817f304"
WALLET  = "0x532f0df0896f353d8c3dd8cc134e8129da2a3948"
SCHED   = "0x56e776bae2dd60664b69bd5f865f1180ffb7d58b"
SEL = {"wakeMode":"0x60db537d","configured":"0x8772a23a","currentSeriesId":"0xc9777451",
       "curCallId":"0x618abb34","nextCallId":"0x61f32724","balanceOf":"0x70a08231",
       "lockUntil":"0xeba74ee9","calls":"0xd183ce14","predictHarness":"0x78165f40"}
DEPLOY_SEL, CONFIG_SEL = "0x3293993b", "0xb1906702"
UA = "Mozilla/5.0 (RitualAgentExplorer)"
def _post(url, body):
    req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                 headers={"content-type":"application/json","user-agent":UA})
    with urllib.request.urlopen(req, timeout=40) as r: return json.loads(r.read())
def _get(url):
    req = urllib.request.Request(url, headers={"accept":"application/json","user-agent":UA})
    try:
        with urllib.request.urlopen(req, timeout=40) as r: return json.loads(r.read()), 200
    except urllib.error.HTTPError as e:
        try: return json.loads(e.read()), e.code
        except Exception: return None, e.code
    except Exception: return None, 0
def rpc(method, params):
    try: return _post(RPC, {"jsonrpc":"2.0","method":method,"params":params,"id":1}).get("result")
    except Exception: return None
def rpc_batch(reqs):
    body = [{"jsonrpc":"2.0","method":m,"params":p,"id":i} for i,(m,p) in enumerate(reqs)]
    out = [None]*len(reqs)
    try:
        for item in _post(RPC, body):
            if isinstance(item, dict) and "id" in item: out[item["id"]] = item.get("result")
    except Exception:
        for i,(m,p) in enumerate(reqs): out[i] = rpc(m,p)
    return out
def eth_call(to, data): return rpc("eth_call", [{"to":to,"data":data}, "latest"])
def pad(a): return a.lower().replace("0x","").rjust(64,"0")
def hint(h):
    if not h or h == "0x": return 0
    try: return int(h, 16)
    except Exception: return 0
def word_addr(res):
    if not res or len(res) < 66: return None
    return "0x" + res[2:][24:64]
def predict_harness(owner, salt32):
    return word_addr(eth_call(FACTORY, SEL["predictHarness"]+pad(owner)+salt32.replace("0x","").rjust(64,"0")))
def indexer_txs(eoa):
    eoa = eoa.lower(); txs = {}
    d, code = _get(f"{INDEXER}/addresses/{eoa}/transactions?limit=100")
    if code == 200 and d and "transactions" in d:
        for t in d["transactions"]: txs[t["tx_hash"]] = t
        off = 100
        while d.get("hasMore") and off < 1000:
            d, code = _get(f"{INDEXER}/addresses/{eoa}/transactions?limit=100&offset={off}")
            if not d or "transactions" not in d: break
            for t in d["transactions"]: txs[t["tx_hash"]] = t
            off += 100
        return list(txs.values())
    cur = datetime.date.today()
    for _ in range(24):
        start = cur.replace(day=1); fd, td = start.isoformat(), cur.isoformat(); off = 0
        while True:
            d, code = _get(f"{INDEXER}/addresses/{eoa}/transactions?limit=50&offset={off}&from_date={fd}&to_date={td}")
            if not d or "transactions" not in d: break
            for t in d["transactions"]: txs[t["tx_hash"]] = t
            if not d.get("hasMore"): break
            off += 50
        cur = start - datetime.timedelta(days=1)
    return list(txs.values())
def find_agents(txs, eoa):
    eoa = eoa.lower(); agents = {}
    for t in txs:
        if (t.get("from_address") or "").lower() != eoa: continue
        sel = (t.get("method_selector") or "")[:10]
        if sel == CONFIG_SEL:
            a = (t.get("to_address") or "").lower()
            if a: agents.setdefault(a, {}); agents[a]["configured"]=True
        elif sel == DEPLOY_SEL:
            inp = t.get("input_data")
            if not inp:
                td, _ = _get(f"{INDEXER}/transactions/{t['tx_hash']}"); inp = (td or {}).get("input_data")
            if inp and len(inp) >= 74:
                a = predict_harness(eoa, "0x"+inp[10:74])
                if a: a=a.lower(); agents.setdefault(a, {}); agents[a]["salt"]="0x"+inp[10:74]
    return agents
def agent_status(addr, block):
    addr = addr.lower()
    r = rpc_batch([
        ("eth_call",[{"to":addr,"data":SEL["wakeMode"]},"latest"]),
        ("eth_call",[{"to":addr,"data":SEL["configured"]},"latest"]),
        ("eth_call",[{"to":addr,"data":SEL["currentSeriesId"]},"latest"]),
        ("eth_call",[{"to":addr,"data":SEL["curCallId"]},"latest"]),
        ("eth_call",[{"to":addr,"data":SEL["nextCallId"]},"latest"]),
        ("eth_call",[{"to":WALLET,"data":SEL["balanceOf"]+pad(addr)},"latest"]),
        ("eth_call",[{"to":WALLET,"data":SEL["lockUntil"]+pad(addr)},"latest"]),
    ])
    c1, c4 = hint(r[3]), hint(r[4]); scheduled=False
    for cid in (c1, c4):
        if cid and eth_call(SCHED, SEL["calls"]+hex(cid)[2:].rjust(64,"0")) is not None:
            scheduled=True; break
    lock = hint(r[6])
    return {"wakeMode":hint(r[0]),"configured":hint(r[1])==1,"series":hint(r[2]),
            "balance_wei":hint(r[5]),"lockUntil":lock,"lockExpired":(block>=lock if lock else True),
            "live":scheduled}
def main():
    eoa = (sys.argv[1] if len(sys.argv)>1 else os.environ.get("WALLET_ADDRESS","")).strip()
    block = hint(rpc("eth_blockNumber", []))
    txs = indexer_txs(eoa); amap = find_agents(txs, eoa); rows = []
    for a, meta in amap.items():
        try:
            st = agent_status(a, block); st.update(meta); st["address"]=a; rows.append(st)
        except Exception as e:
            rows.append({"address":a,"error":str(e),"balance_wei":0})
    rows.sort(key=lambda x: x.get("series",0), reverse=True)
    live = sum(1 for x in rows if x.get("live")); total = sum(int(x.get("balance_wei",0)) for x in rows)
    print(f"BLOCK={block}")
    for x in rows:
        print("AGENT\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s" % (
            x["address"], 1 if x.get("live") else 0, 1 if x.get("configured") else 0,
            x.get("wakeMode",0), x.get("series",0), int(x.get("balance_wei",0)),
            x.get("lockUntil",0), 1 if x.get("lockExpired") else 0, x.get("salt","") or ""))
    print("SUMMARY\t%d\t%d\t%d\t%d" % (len(rows), live, len(rows)-live, total))
if __name__ == "__main__":
    main()
'@

# view [eoa] -> show every sovereign agent an EOA deployed (from the chain indexer, not by guessing
# salts): each LIVE or DEAD with the RITUAL stuck in its wallet, in a table. No address -> your wallet.
function Invoke-View([string]$arg) {
    $eoa = if ($arg) { $arg } else { $env:WALLET_ADDRESS }
    if (-not (Test-Addr $eoa)) { Fail "not a valid EOA address: $eoa" }
    Banner
    Kv "Owner" $eoa
    Kv "Chain" "$(& cast chain-id --rpc-url $env:RPC_URL)"
    Show-Agents $eoa
    if ([int]$script:SCAN_LIVE -gt 0) {
        Info "add funds to a live agent: pwsh run.ps1 topup <agent-address> [amount]  (in RITUAL)"
    } elseif ([int]$script:SCAN_DEAD -gt 0) {
        Info "dead agents cannot be revived and their balance is stuck; start fresh with: pwsh run.ps1 deploy"
    }
}

# Run the embedded indexer scanner for an EOA and print the LIVE/DEAD + stuck-RITUAL table. Sets
# $script:SCAN_COUNT / SCAN_LIVE / SCAN_DEAD / SCAN_TOTAL / SCAN_N for the caller.
function Show-Agents([string]$eoa) {
    Step "Scanning agents"
    Info "reading the indexer + chain - can take ~10-30s for busy wallets"

    $tmpPy = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "ritual_scan_$([System.IO.Path]::GetRandomFileName()).py")
    Write-Utf8NoBom $tmpPy $SCAN_PY
    try {
        Spin "discover agents, check live/dead, read balances" `
            "uv" @('run', '--quiet', '--python', '3.12', 'python', $tmpPy, $eoa) 3
    } finally {
        Remove-Item $tmpPy -ErrorAction SilentlyContinue
    }
    $out = $script:SpinOut

    Step "Your agents"
    $script:SCAN_COUNT = 0; $script:SCAN_LIVE = 0; $script:SCAN_DEAD = 0; $script:SCAN_TOTAL = [bigint]0; $script:SCAN_N = 0
    foreach ($line in ($out -split "`n")) {
        $f = ($line.TrimEnd("`r")) -split "`t"   # double-quoted "`t" is a real tab; the scanner is tab-delimited
        if ($f[0] -eq 'AGENT') {
            if ($script:SCAN_N -eq 0) {              # header row, printed once above the first agent
                Write-Host ("  $MUTED{0,-42}  {1,-4}  {2,12}  {3,6}  {4,-12}  {5}$RESET" -f 'AGENT', 'STATE', 'RITUAL', 'SERIES', 'CONFIG', 'LOCK')
            }
            $script:SCAN_N++
            $col     = if ($f[2] -eq '1') { $OKC } else { $BADC }
            $word    = if ($f[2] -eq '1') { 'live' } else { 'dead' }
            $cfgstr  = if ($f[3] -eq '1') { 'configured' } else { 'unconfigured' }
            $lockstr = if ($f[8] -eq '1') { 'unlocked' } else { "locked @ $($f[7])" }
            Write-Host ("  $BOLD{0,-42}$RESET  $col{1,-4}$RESET  {2,12}  {3,6}  {4,-12}  {5}" -f $f[1], $word, (Format-Rit $f[6]), $f[5], $cfgstr, $lockstr)
        } elseif ($f[0] -eq 'SUMMARY') {
            $script:SCAN_COUNT = $f[1]; $script:SCAN_LIVE = $f[2]; $script:SCAN_DEAD = $f[3]; $script:SCAN_TOTAL = [bigint]$f[4]
        }
    }
    if ($script:SCAN_N -eq 0) {
        Info "no sovereign agents found for this EOA"
    } else {
        Hr
        Kv "Agents"       "$($script:SCAN_COUNT)  (${OKC}$($script:SCAN_LIVE) live$RESET / ${BADC}$($script:SCAN_DEAD) dead$RESET)"
        Kv "Stuck RITUAL" "$(Format-Rit ($script:SCAN_TOTAL.ToString())) across all agents"
    }
}

function Invoke-Topup([string]$a1, [string]$a2) {
    if (Test-Addr $a1) { $env:HARNESS = $a1; $ritual = if ($a2) { $a2 } else { $env:DEPOSIT } }
    else { $ritual = if ($a1) { $a1 } else { $env:DEPOSIT } }
    if (-not $ritual) { Fail "amount required: pwsh run.ps1 topup <address> <amount>  (in RITUAL, or set DEPOSIT in .env)" }
    $amount = (& cast to-wei $ritual ether 2>$null)
    if (-not $amount) { Fail "amount '$ritual' is not a valid RITUAL number" }
    if (-not (Test-Deployed)) { Fail "harness not deployed yet - run: pwsh run.ps1 deploy" }
    if (-not (Test-Alive $env:HARNESS)) { Fail "agent $($env:HARNESS) is dead - it has no scheduled wake left, so a deposit cannot revive it and would be stuck. Deploy a fresh agent: pwsh run.ps1 deploy" }
    Banner
    Step "Deposit $ritual RITUAL"
    Kv "agent" $env:HARNESS
    Info "lock $LOCK_BLOCKS blocks"
    Unlock
    Spin "depositing" "cast" @('send', $RITUAL_WALLET, 'depositFor(address,uint256)', $env:HARNESS, $LOCK_BLOCKS, '--account', $env:KEYSTORE_ACCOUNT, '--password', $script:KS_PASSWORD, '--rpc-url', $env:RPC_URL, '--value', $amount)
    $bal = Invoke-Rpc @('call', $RITUAL_WALLET, 'balanceOf(address)(uint256)', $env:HARNESS, '--rpc-url', $env:RPC_URL)
    Ok "topped up. balance $(& cast to-unit (Num $bal) ether) RITUAL"
    Info "this deposit funds the agent's upcoming wakes"
}

function Invoke-Deploy {
    Need-Deposit
    Require-MinDeposit
    Banner
    Kv "Owner"   $env:WALLET_ADDRESS
    Kv "Chain"   "$(& cast chain-id --rpc-url $env:RPC_URL)"
    Kv "Balance" "$(& cast balance $env:WALLET_ADDRESS --ether --rpc-url $env:RPC_URL) RITUAL"

    # Resolve the agent address for SALT. If that slot already has a live agent, show the wallet's full
    # fleet from the indexer (the same table as `view`), then ask before bumping to the next free salt
    # (my-agent-1 -> my-agent-2 -> ...) and deploying there.
    Step "Select agent"
    $salt = if ($env:SALT) { $env:SALT } else { "ritual-agent-1" }
    $n = 0
    $USERSALT = (& cast keccak $salt).Trim()
    $env:HARNESS = Get-Harness $USERSALT
    if (Test-Live $env:HARNESS) {
        Show-Agents $env:WALLET_ADDRESS
        $reply = Read-Host "`n  Deploy another (new) agent? [y/N]"
        if ($reply -notmatch '^(y|Y|yes|YES)$') { Info "left it running - inspect with: pwsh run.ps1 view"; exit 0 }
        while (Test-Live $env:HARNESS) {
            $salt = Next-Salt $salt
            $USERSALT = (& cast keccak $salt).Trim()
            $env:HARNESS = Get-Harness $USERSALT
            $n++; if ($n -gt 200) { Fail "200+ live agents - set a fresh SALT in .env" }
        }
        Ok "new slot: $salt"
    }
    Kv "Salt"    $salt
    Kv "Deposit" "$($env:DEPOSIT) RITUAL"
    Kv "Harness" $env:HARNESS
    Unlock

    # build the encrypted, ABI-encoded configureFundAndStart payload (Python -> temp file)
    Step "Build request"
    $PY_SCRIPT = @'
import os
from ecies import encrypt as ecies_encrypt
from ecies.config import ECIES_CONFIG
from eth_abi.abi import encode
from web3 import Web3

ECIES_CONFIG.symmetric_nonce_length = 12
w3 = Web3(Web3.HTTPProvider(os.environ["RPC_URL"]))
reg_abi = [{"name": "getServicesByCapability", "type": "function", "stateMutability": "view",
            "inputs": [{"name": "c", "type": "uint8"}, {"name": "v", "type": "bool"}],
            "outputs": [{"name": "", "type": "tuple[]", "components": [
                {"name": "node", "type": "tuple", "components": [
                    {"name": "paymentAddress", "type": "address"}, {"name": "teeAddress", "type": "address"},
                    {"name": "teeType", "type": "uint8"}, {"name": "publicKey", "type": "bytes"},
                    {"name": "endpoint", "type": "string"}, {"name": "certPubKeyHash", "type": "bytes32"},
                    {"name": "capability", "type": "uint8"}]},
                {"name": "isValid", "type": "bool"}, {"name": "workloadId", "type": "bytes32"}]}]}]
reg = w3.eth.contract(address=Web3.to_checksum_address(os.environ["REGISTRY"]), abi=reg_abi)
svc = reg.functions.getServicesByCapability(0, True).call()
if not svc:
    raise SystemExit("no valid executors in TEEServiceRegistry")
node = svc[0][0]
executor = Web3.to_checksum_address(node[1])
pub = bytes(node[3])

harness = Web3.to_checksum_address(os.environ["HARNESS"])
enc = ecies_encrypt(pub.hex(), b'{"LLM_PROVIDER":"ritual"}')
delivery_selector = Web3.keccak(text="onSovereignAgentResult(bytes32,bytes)")[:4]
# maxPollBlock is a Phase-2 deadline OFFSET (relative to settlement), not an absolute block.
# The chain rejects the agent's async job unless ttl < maxPollBlock <= 70000; 6000 ~= 35 min.
max_poll_block = 6000

params = (
    executor, 500, b"", 5, max_poll_block, "SOVEREIGN_AGENT_TASK", harness, delivery_selector,
    3_000_000, 1_000_000_000, 100_000_000, int(os.environ["CLI_TYPE"]), os.environ["PROMPT"], enc,
    ("", "", ""), ("", "", ""), [], ("", "", ""), os.environ["MODEL"], [], 50, 8192, "",
)
# frequency 2000 blocks (~11.7 min) clears the 60-90s agent round-trip so a new wake does not
# hit the per-sender async lock; windowNumCalls 5 keeps 5*2000 within MAX_LIFESPAN (10000).
schedule = (800_000, 2000, 500, 1_000_000_000, 100_000_000, 0)
rolling = (5, 5000, 1)

PT = ("(address,uint256,bytes,uint64,uint64,string,address,bytes4,uint256,uint256,uint256,uint16,"
      "string,bytes,(string,string,string),(string,string,string),(string,string,string)[],"
      "(string,string,string),string,string[],uint16,uint32,string)")
ST = "(uint32,uint32,uint32,uint256,uint256,uint256)"
RT = "(uint32,uint16,uint16)"
selector = Web3.keccak(text=f"configureFundAndStart({PT},{ST},{RT},uint256)")[:4]
data = selector + encode([PT, ST, RT, "uint256"], [params, schedule, rolling, int(os.environ["LOCK_BLOCKS"])])
print("EXECUTOR=" + executor)
print("CONFIG_CALLDATA=0x" + data.hex())
'@
    $tmpPy = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "ritual_deploy_$([System.IO.Path]::GetRandomFileName()).py")
    Write-Utf8NoBom $tmpPy $PY_SCRIPT
    try {
        # Pin Python 3.12 + eciespy 0.4: coincurve (eciespy's secp256k1 dep) ships wheels only up to
        # cp313 so 3.14+ builds from source and fails, and eciespy's config/encrypt API changed at
        # 0.3 -> 0.4. uv fetches a managed 3.12 if the system lacks one.
        Spin "discover executor, encrypt secret, encode calldata" `
            "uv" @('run', '--quiet', '--python', '3.12', '--with', 'eciespy>=0.4,<0.5', '--with', 'eth-abi', '--with', 'web3', 'python', $tmpPy) 3
    } finally {
        Remove-Item $tmpPy -ErrorAction SilentlyContinue
    }
    $OUT = $script:SpinOut
    $EXECUTOR        = ($OUT -split "`n" | Where-Object { $_ -match '^EXECUTOR=' })        -replace '^EXECUTOR=', '' -replace '\s', ''
    $CONFIG_CALLDATA = ($OUT -split "`n" | Where-Object { $_ -match '^CONFIG_CALLDATA=' }) -replace '^CONFIG_CALLDATA=', '' -replace '\s', ''
    if (-not $CONFIG_CALLDATA) { Write-Host $OUT; Fail "failed to build request" }
    Ok "executor $EXECUTOR"

    # deploy the harness if it is not on-chain yet (CREATE3 needs ~2.5M gas)
    Step "Deploy harness"
    $CODE = (& cast code $env:HARNESS --rpc-url $env:RPC_URL).Trim()
    if ($CODE.Length -le 2) {
        Spin "deploying harness" "cast" @('send', $FACTORY, 'deployHarness(bytes32)', $USERSALT, '--account', $env:KEYSTORE_ACCOUNT, '--password', $script:KS_PASSWORD, '--rpc-url', $env:RPC_URL, '--gas-limit', '3500000')
        Ok "harness deployed"
    } else {
        Ok "already on-chain - skipping"
    }

    for ($i = 0; $i -lt 10; $i++) {
        $CODE = (& cast code $env:HARNESS --rpc-url $env:RPC_URL 2>$null).Trim()
        if ($CODE.Length -gt 2) { break }
    }
    if ($CODE.Length -le 2) { Fail "harness has no code after deploy" }

    # verify, simulate (no spend), then fund + arm
    Step "Fund and arm"
    Spin "simulate configureFundAndStart (no spend)" `
        "cast" @('call', $env:HARNESS, $CONFIG_CALLDATA, '--from', $env:WALLET_ADDRESS, '--value', $env:DEPOSIT_WEI, '--rpc-url', $env:RPC_URL) 3
    Spin "fund and arm (configureFundAndStart)" `
        "cast" @('send', $env:HARNESS, $CONFIG_CALLDATA, '--account', $env:KEYSTORE_ACCOUNT, '--password', $script:KS_PASSWORD, '--rpc-url', $env:RPC_URL, '--value', $env:DEPOSIT_WEI, '--gas-limit', $SCHED_GAS)
    Ok "funded and armed"

    Write-Host ""; Hr
    Write-Host "  ${BOLD}${OKC}Congratulations - your sovereign agent is live!$RESET`n"
    Write-Host "  ${MUTED}Your sovereign agent contract address:$RESET"
    Write-Host "  ${BOLD}${ACCENT}$env:HARNESS$RESET`n"
    Kv "configured" "$(Invoke-Rpc @('call', $env:HARNESS, 'configured()(bool)', '--rpc-url', $env:RPC_URL))"
    Kv "wakeMode"   "$(Num (Invoke-Rpc @('call', $env:HARNESS, 'wakeMode()(uint8)', '--rpc-url', $env:RPC_URL)))  (1 armed)"
    Hr
}

switch ($CMD) {
    'deploy'  { Invoke-Deploy }
    'view'    { Invoke-View $ARG1 }
    'status'  { Invoke-View $ARG1 }
    'topup'   { Invoke-Topup $ARG1 $ARG2 }
    'fund'    { Invoke-Topup $ARG1 $ARG2 }
    default   { Show-Usage; Fail "unknown command: $CMD" }
}
