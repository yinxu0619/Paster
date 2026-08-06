$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$publishDir = Join-Path $root "artifacts\publish\Paster.Windows-win-x64"
$exe = Join-Path $publishDir "Paster.Windows.exe"
$appLog = Join-Path $env:LOCALAPPDATA "Paster.Windows\paster.log"
$smokeLogDir = Join-Path $root "artifacts\logs"
$smokeLog = Join-Path $smokeLogDir "smoke-test.log"

New-Item -ItemType Directory -Force -Path $smokeLogDir | Out-Null
"Smoke test started: $(Get-Date -Format o)" | Out-File -FilePath $smokeLog -Encoding utf8

if (-not (Test-Path $exe)) {
    throw "Executable not found: $exe. Run .\scripts\publish-unpackaged.ps1 -Configuration Release first."
}

$icon = Join-Path $root "src\Paster.Windows\Assets\Paster.ico"
if (-not (Test-Path $icon)) {
    throw "Icon not found: $icon"
}

if (Test-Path $appLog) {
    Remove-Item $appLog -Force
}

$process = Start-Process -FilePath $exe -PassThru
"Started process id: $($process.Id)" | Out-File -FilePath $smokeLog -Encoding utf8 -Append
Start-Sleep -Seconds 20

$running = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
if (-not $running) {
    throw "Paster.Windows exited during startup. Check Windows Event Viewer and $appLog."
}

if (Test-Path $appLog) {
    "Application log:" | Out-File -FilePath $smokeLog -Encoding utf8 -Append
    Get-Content $appLog | Out-File -FilePath $smokeLog -Encoding utf8 -Append
}
else {
    throw "Paster.Windows is running, but app log was not created: $appLog"
}

try {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    "Stopped process id: $($process.Id)" | Out-File -FilePath $smokeLog -Encoding utf8 -Append
}
catch {
    "Failed to stop process id: $($process.Id) - $($_.Exception.Message)" | Out-File -FilePath $smokeLog -Encoding utf8 -Append
}

Write-Host "Smoke test passed. Process is running: $($process.Id)" -ForegroundColor Green
Write-Host "Log: $smokeLog"
