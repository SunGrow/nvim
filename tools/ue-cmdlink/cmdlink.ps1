# Runs one console command in an Unreal Editor started with -cmdlink and prints the editor's reply.
#
# The editor side is Epic's CmdLinkServer plugin (Engine/Plugins/CmdLinkServer, enabled by default,
# Win64 editor): with -cmdlink it serves \\.\pipe\UnrealEngine-CLI, or UnrealEngine-CLI-<key> when the
# console variable console.CmdLink.key is set. Request: int32 argc, then per argument int32 length and
# the ANSI bytes with their NUL; argument 0 is ignored and the others are joined with spaces. Reply:
# int32 length, ANSI bytes with NUL (CmdLinkServer.cpp, UE 5.6 / 5.8).
#
# Exit codes: 0 reply printed, 2 no editor on that pipe, 3 the editor closed the pipe without a reply.
param(
  [Parameter(Mandatory = $true)][string]$Pipe,
  [Parameter(Mandatory = $true)][string]$Command,
  [int]$TimeoutMs = 1000
)

$enc = [System.Text.Encoding]::ASCII
$client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $Pipe, [System.IO.Pipes.PipeDirection]::InOut)
try { $client.Connect($TimeoutMs) } catch { [Console]::Error.WriteLine("no editor on \\.\pipe\$Pipe"); exit 2 }
try {
  $writer = New-Object System.IO.BinaryWriter($client)
  $argv = @('cmdlink', $Command)
  $writer.Write([int32]$argv.Count)
  foreach ($a in $argv) {
    $bytes = $enc.GetBytes($a + [char]0)
    $writer.Write([int32]$bytes.Length)
    $writer.Write($bytes)
  }
  $writer.Flush()
  $reader = New-Object System.IO.BinaryReader($client)
  $size = $reader.ReadInt32()
  $reply = $reader.ReadBytes($size)
  [Console]::Out.Write($enc.GetString($reply, 0, [Math]::Max(0, $reply.Length - 1)))
} catch {
  [Console]::Error.WriteLine("the editor closed \\.\pipe\$Pipe without a reply: $_")
  exit 3
} finally {
  $client.Dispose()
}
