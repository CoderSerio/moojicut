param([string]$Action, [string]$FilePath)
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System.Runtime.InteropServices;
public static class MooncapClipboard {
  [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
}
'@
if ($Action -eq 'change-count') {
  [MooncapClipboard]::GetClipboardSequenceNumber()
} elseif ($Action -eq 'copy-file') {
  if (!(Test-Path -LiteralPath $FilePath -PathType Leaf)) { throw 'File does not exist' }
  $files = New-Object System.Collections.Specialized.StringCollection
  [void]$files.Add($FilePath)
  [System.Windows.Forms.Clipboard]::SetFileDropList($files)
  [MooncapClipboard]::GetClipboardSequenceNumber()
} else { throw 'Unknown clipboard command' }
