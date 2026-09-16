<#
Force-quit a running shell on Windows and report what it leaves behind.

app_check.sh ends by killing the shell with SIGKILL and checking that the server
went with it. On Windows that needs saying differently, and saying more
precisely, for three reasons:

  * Git Bash's `kill -9` acts on the MSYS process that started the shell, which
    is not necessarily the Windows process that owns the window. Stop-Process
    -Force is TerminateProcess on the shell itself, which is what Task Manager's
    End task does and what a crash looks like: no Rust code runs afterwards.
  * The server is not the shell's child. The shell runs the .cmd launcher, so
    the tree is shell -> cmd.exe -> ruby.exe, and ruby.exe only goes if
    something reaches it. The process tree is captured before the kill, so a
    survivor can be named rather than inferred from a port that still answers.
  * Whether a window exists at all is a question a log cannot answer. The
    shell's main window handle and title are printed, and a screenshot of the
    desktop is saved when asked for, so a run that passes shows what it saw.

Usage:
  kill_shell.ps1 -Shell C:\path\to\app.exe [-Screenshot C:\path\to\shot.png] [-Wait 15]

Exit status: 0 when the shell and everything it started are gone, 1 when
something outlived it (survivors are then stopped, so the job can continue),
2 when no running shell was found at that path.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Shell,
  [string]$Screenshot = "",
  [int]$Wait = 15
)

$ErrorActionPreference = "Stop"
$shellPath = (Resolve-Path -LiteralPath $Shell).Path

$all = @(Get-CimInstance Win32_Process)
$shells = @($all | Where-Object { $_.ExecutablePath -and $_.ExecutablePath -ieq $shellPath })
if ($shells.Count -eq 0) {
  Write-Host "FAIL  no running process is $shellPath"
  exit 2
}

# Descendants by parent id. A parent id outlives its process on Windows and ids
# are reused, so a candidate only counts when it started after its parent did.
function Get-Descendants($roots, $processes) {
  $found = @()
  $queue = [System.Collections.Queue]::new()
  foreach ($root in $roots) { $queue.Enqueue($root) }
  while ($queue.Count -gt 0) {
    $parent = $queue.Dequeue()
    foreach ($child in $processes) {
      if ($child.ParentProcessId -eq $parent.ProcessId -and
          $child.ProcessId -ne $parent.ProcessId -and
          $child.CreationDate -ge $parent.CreationDate) {
        $found += $child
        $queue.Enqueue($child)
      }
    }
  }
  return $found
}

$tree = @(Get-Descendants $shells $all)

foreach ($s in $shells) {
  $process = Get-Process -Id $s.ProcessId -ErrorAction SilentlyContinue
  $handle = if ($process) { $process.MainWindowHandle } else { 0 }
  $title = if ($process) { $process.MainWindowTitle } else { "" }
  Write-Host ("      shell pid {0}, main window handle {1}, title '{2}'" -f $s.ProcessId, $handle, $title)
}
Write-Host "      what it started:"
foreach ($p in $tree) {
  $line = if ($p.CommandLine) { $p.CommandLine } else { $p.Name }
  if ($line.Length -gt 140) { $line = $line.Substring(0, 140) + "..." }
  Write-Host ("        pid {0,-6} parent {1,-6} {2}" -f $p.ProcessId, $p.ParentProcessId, $line)
}

if ($Screenshot) {
  # The primary screen as the runner's interactive session sees it. Recorded,
  # not asserted: a window can exist behind another one.
  try {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $bitmap.Save($Screenshot, [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose(); $bitmap.Dispose()
    Write-Host "      screenshot: $Screenshot ($($bounds.Width)x$($bounds.Height))"
  } catch {
    Write-Host "      no screenshot: $($_.Exception.Message)"
  }
}

foreach ($s in $shells) { Stop-Process -Id $s.ProcessId -Force }

# WebView2's own processes are reported but not held against the shell: they
# belong to the Edge runtime, which reaps them itself once their browser process
# notices its host has gone. The server tree is what this is about.
$deadline = (Get-Date).AddSeconds($Wait)
do {
  $alive = @($tree | Where-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
  $serverAlive = @($alive | Where-Object { $_.Name -ine "msedgewebview2.exe" })
  if ($serverAlive.Count -eq 0) { break }
  Start-Sleep -Milliseconds 250
} while ((Get-Date) -lt $deadline)

$webviews = @($alive | Where-Object { $_.Name -ieq "msedgewebview2.exe" })
if ($webviews.Count -gt 0) {
  Write-Host "      $($webviews.Count) WebView2 process(es) still exiting; not the server's"
}

if ($serverAlive.Count -gt 0) {
  foreach ($p in $serverAlive) {
    Write-Host ("FAIL  pid {0} ({1}) outlived Stop-Process -Force on the shell by {2}s" -f $p.ProcessId, $p.Name, $Wait)
  }
  foreach ($p in $serverAlive) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
  exit 1
}

$count = @($tree | Where-Object { $_.Name -ine "msedgewebview2.exe" }).Count
Write-Host "OK    Stop-Process -Force on the shell took its $count server process(es) with it"
exit 0
