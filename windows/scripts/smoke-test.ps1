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

$process = $null
try {
    $process = Start-Process -FilePath $exe -PassThru
    "Started process id: $($process.Id)" | Out-File -FilePath $smokeLog -Encoding utf8 -Append
    Start-Sleep -Seconds 20

    if ($process.HasExited) {
        throw "Paster.Windows exited during startup (exit code $($process.ExitCode)). Check $smokeLog."
    }
    if (-not (Test-Path $appLog)) {
        throw "Paster.Windows is running, but its app log was not created."
    }
    $log = Get-Content $appLog -Raw
    if ($log -notmatch 'Tray icon created\.') {
        throw "Paster.Windows did not complete initialization. Check $smokeLog."
    }
    if ($log -match 'Fatal startup failure|Unhandled WinUI exception') {
        throw "Paster.Windows reported a startup error. Check $smokeLog."
    }
    "Smoke test passed: startup completed and the process stayed alive for 20 seconds." |
        Out-File -FilePath $smokeLog -Encoding utf8 -Append
    Write-Host "Smoke test passed." -ForegroundColor Green
}
finally {
    if ($null -ne $process) {
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            $process.WaitForExit(5000) | Out-Null
        }
        $process.Dispose()
    }
    if (Test-Path $appLog) {
        Copy-Item $appLog (Join-Path $smokeLogDir "paster.log") -Force
        "Application log:" | Out-File -FilePath $smokeLog -Encoding utf8 -Append
        Get-Content $appLog | Out-File -FilePath $smokeLog -Encoding utf8 -Append
    }
    Write-Host "Log: $smokeLog"
}
