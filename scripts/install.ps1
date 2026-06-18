$ErrorActionPreference = "Stop"

$Version = $env:LOAM_VERSION
if ([string]::IsNullOrWhiteSpace($Version)) {
  $release = Invoke-RestMethod -Uri "https://api.github.com/repos/darkhorseprojects/loam/releases/latest"
  $Version = $release.tag_name
}
$Version = $Version.TrimStart("v")

$arch = switch ($env:PROCESSOR_ARCHITECTURE) {
  "AMD64" { "x86_64" }
  default { throw "unsupported Windows architecture: $env:PROCESSOR_ARCHITECTURE" }
}

$installDir = if ($env:LOAM_INSTALL_DIR) { $env:LOAM_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA "loam\bin" }
$dataDir = if ($env:LOAM_DATA_DIR) { $env:LOAM_DATA_DIR } else { Join-Path $env:APPDATA "loam" }
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "loam-install-$PID"
$asset = "loam-$Version-windows-$arch.zip"
$url = "https://github.com/darkhorseprojects/loam/releases/download/v$Version/$asset"

New-Item -ItemType Directory -Force -Path $tmp, $installDir, $dataDir | Out-Null
try {
  $zip = Join-Path $tmp $asset
  Invoke-WebRequest -Uri $url -OutFile $zip
  Expand-Archive -Path $zip -DestinationPath $tmp -Force

  Copy-Item -Force (Join-Path $tmp "loam.exe") (Join-Path $installDir "loam.exe")
  Copy-Item -Force (Join-Path $tmp "loam-mcp.exe") (Join-Path $installDir "loam-mcp.exe")

  $brushSource = Join-Path $tmp "brushes"
  if (Test-Path $brushSource) {
    $brushTarget = Join-Path $dataDir "brushes"
    if (Test-Path $brushTarget) { Remove-Item -Recurse -Force $brushTarget }
    Copy-Item -Recurse $brushSource $brushTarget
  }

  Write-Host "installed loam $Version to $(Join-Path $installDir 'loam.exe')"
  Write-Host "installed loam-mcp $Version to $(Join-Path $installDir 'loam-mcp.exe')"
  Write-Host "installed bundled brushes to $(Join-Path $dataDir 'brushes')"
  Write-Host "add $installDir to PATH if it is not already there"
} finally {
  if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
}
