# Starts a local anvil fork of Robinhood Chain mainnet on 127.0.0.1:$Port (chain id 31337) and returns once it is
# listening. The fork keeps running in the background after this script exits; stop it with -Stop.
#
#   powershell -ExecutionPolicy Bypass -File scripts/fork/start-fork.ps1            # start (port 18546)
#   powershell -ExecutionPolicy Bypass -File scripts/fork/start-fork.ps1 -Stop      # stop
#
# Notes (why it looks like this):
#  * The public RPC is not an archive node: state at the fork block is pruned after a few hours, so restart the
#    fork (and re-run deploy-fork.sh) for each session instead of keeping one alive for days.
#  * --hardfork cancun avoids the Prague EIP-2935 blockhash system call, which needs historical state.
#  * anvil runs from a renamed copy (swapline-fork.exe) launched via WMI so that tooling which kills `anvil.exe`
#    processes by name (or tears down its own process tree) does not take this fork down.
param(
  [int]$Port = 18546,
  [string]$RpcUrl = $(if ($env:RH_RPC_URL) { $env:RH_RPC_URL } else { "https://rpc.mainnet.chain.robinhood.com" }),
  [int]$Attempts = 10,
  [switch]$Stop
)
$bin = Join-Path $PSScriptRoot ".bin"
$logDir = Join-Path $PSScriptRoot ".logs"
$exe = Join-Path $bin "swapline-fork.exe"

if ($Stop) {
  Get-CimInstance Win32_Process -Filter "Name='swapline-fork.exe'" | ForEach-Object {
    if ($_.CommandLine -match "--port $Port") { Stop-Process -Id $_.ProcessId -Force; "stopped fork pid $($_.ProcessId)" }
  }
  exit 0
}

if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
  Write-Error "port $Port is already in use"; exit 1
}
New-Item -ItemType Directory -Force $bin, $logDir | Out-Null
$anvil = (Get-Command anvil -ErrorAction SilentlyContinue).Source
if (-not $anvil) { $anvil = Join-Path $env:USERPROFILE ".foundry\bin\anvil.exe" }
Copy-Item $anvil $exe -Force

$cmdline = "cmd.exe /c `"`"$exe`" --silent --fork-url $RpcUrl --chain-id 31337 --port $Port --hardfork cancun " +
           "--retries 20 --timeout 60000 --fork-retry-backoff 2000 --compute-units-per-second 40 " +
           "> `"$logDir\anvil.log`" 2>&1`""

for ($i = 1; $i -le $Attempts; $i++) {
  $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmdline; CurrentDirectory = $logDir }
  for ($w = 0; $w -lt 45; $w++) {
    Start-Sleep -Seconds 2
    if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
      Write-Output "fork listening on http://127.0.0.1:$Port (chain id 31337)"
      exit 0
    }
    if (-not (Get-Process -Id $r.ProcessId -ErrorAction SilentlyContinue)) { break }
  }
  Write-Output "attempt $i failed: $(Get-Content "$logDir\anvil.log" -Tail 1 -ErrorAction SilentlyContinue)"
}
Write-Error "could not start the fork after $Attempts attempts"
exit 1
