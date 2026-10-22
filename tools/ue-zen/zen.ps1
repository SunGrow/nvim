# zenserver for Unreal Editors started from Neovim (lua/ue/zen.lua).
#
# An editor that launches zenserver itself waits 20 s for it and then stops on a modal "Wait for
# ZenServer?" dialog (hard-coded, ZenServerInterface.cpp in 5.6 and 5.8); loading its ~1000 persisted
# sessions took 44 s once. Editors from different engines (5.6, 5.8) also pass different arguments
# and shut each other's server down (run context mismatch). So Neovim starts the server (the shared
# install the editors use, with UE 5.8's arguments, loopback only) and waits as long as it takes; the
# editor then gets -NoZenAutoLaunch and only connects to [::1]:8558.
#
# Lifetime: a server started with --owner-pid exits when its sponsor processes are gone. It is started
# with a placeholder owner (a hidden sleeping PowerShell); -Mode Attach adds the editors as sponsors
# (zen.exe attach) and ends the placeholder, so the server lives exactly as long as the editors.
#
# -Mode Start prints "READY <placeholder pid or 0>" (exit 0), "WAIT <seconds>" lines while it starts,
# "NOZEN" (exit 4: no install), "TIMEOUT" (exit 5), "EXITED" (exit 6: the server quit while starting).
# -Mode Attach prints "ATTACHED <pids>" (exit 0) or "NOEDITOR" (exit 7) after up to -TimeoutS seconds.
param(
  [Parameter(Mandatory = $true)][ValidateSet('Start', 'Attach')][string]$Mode,
  [int]$Keeper = 0,
  [int]$TimeoutS = 180
)

$zen = Join-Path $env:LOCALAPPDATA 'UnrealEngine\Common\Zen'
$install = Join-Path $zen 'Install'
$data = Join-Path $zen 'Data'
$url = 'http://[::1]:8558/health/ready'

function Test-Ready {
  $code = & curl.exe -s -o NUL -w '%{http_code}' -m 1 $url 2>$null
  return $code -eq '200'
}

function Write-Line([string]$text) { [Console]::Out.WriteLine($text); [Console]::Out.Flush() }

if ($Mode -eq 'Start') {
  $exe = Join-Path $install 'zenserver.exe'
  if (-not (Test-Path $exe)) { Write-Line 'NOZEN'; exit 4 }
  if (Test-Ready) { Write-Line 'READY 0'; exit 0 }
  $server = Get-Process zenserver -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $server) {
    $placeholder = Start-Process -FilePath powershell.exe -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 86400' -WindowStyle Hidden -PassThru
    $Keeper = $placeholder.Id
    # UE 5.8's [Zen.AutoLaunch] arguments (BaseEngine.ini, as its editor logs them), plus loopback only
    $argv = @('--port', '8558', '--data-dir', "`"$data`"", '--http', 'asio', '--gc-cache-duration-seconds', '1209600',
      '--gc-interval-seconds', '21600', '--gc-low-diskspace-threshold', '2147483648', '--cache-bucket-limit-overwrites',
      '--quiet', '--http-forceloopback', '--restrict-content-types', '--allow-external-oidctoken-exe=false')
    foreach ($opt in @(@('--plugins-config', 'zen_plugins_v1.json'), @('--security-config-path', 'security-config.json'))) {
      $file = Join-Path $install $opt[1]
      if (Test-Path $file) { $argv += @($opt[0], "`"$file`"") }
    }
    $argv += @('--owner-pid', "$Keeper")
    $server = Start-Process -FilePath $exe -ArgumentList $argv -WorkingDirectory $install -WindowStyle Hidden -PassThru
  }
  $start = Get-Date
  $last = -1
  while ($true) {
    if (Test-Ready) { Write-Line "READY $Keeper"; exit 0 }
    if ($server.HasExited) {
      if ($Keeper) { Stop-Process -Id $Keeper -Force -ErrorAction SilentlyContinue }
      Write-Line 'EXITED'; exit 6
    }
    $s = [int]((Get-Date) - $start).TotalSeconds
    if ($s -ge $TimeoutS) { Write-Line 'TIMEOUT'; exit 5 }
    if ($s -ne $last) { Write-Line "WAIT $s"; $last = $s }
    Start-Sleep -Milliseconds 250
  }
}

# Attach: every running editor becomes a sponsor; then the placeholder owner can go
$client = Join-Path $install 'zen.exe'
$start = Get-Date
$attached = @{}
while (((Get-Date) - $start).TotalSeconds -lt $TimeoutS) {
  foreach ($p in Get-Process -Name 'UnrealEditor*' -ErrorAction SilentlyContinue) {
    if ($attached.ContainsKey($p.Id)) { continue }
    & $client attach --owner-pid $p.Id *> $null
    if ($LASTEXITCODE -eq 0) { $attached[$p.Id] = $true }
  }
  if ($attached.Count -gt 0) { break }
  Start-Sleep -Milliseconds 500
}
if ($Keeper) { Stop-Process -Id $Keeper -Force -ErrorAction SilentlyContinue }
if ($attached.Count -eq 0) { Write-Line 'NOEDITOR'; exit 7 }
Write-Line ('ATTACHED ' + (($attached.Keys | Sort-Object) -join ','))
