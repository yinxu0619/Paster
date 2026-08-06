param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$project = Join-Path $root "src\Paster.Windows\Paster.Windows.csproj"
$publishDir = Join-Path $root "artifacts\publish\Paster.Windows-win-x64"
$logDir = Join-Path $root "artifacts\logs"
$logPath = Join-Path $logDir "publish.log"
$localDotnet = Join-Path $root ".dotnet\dotnet.exe"

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue) -and (Test-Path $localDotnet)) {
    $env:DOTNET_ROOT = Split-Path $localDotnet
    $env:PATH = "$env:DOTNET_ROOT;$env:PATH"
}

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet was not found. Run .\scripts\install-dotnet-sdk.ps1 first."
}

Push-Location $root
try {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    "Publish started: $(Get-Date -Format o)" | Out-File -FilePath $logPath -Encoding utf8

    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "scripts\generate-icon.ps1")
    if ($LASTEXITCODE -ne 0) {
        throw "Icon generation failed with exit code $LASTEXITCODE."
    }

    if (Test-Path $publishDir) {
        Remove-Item $publishDir -Recurse -Force
    }

    dotnet publish $project `
        -c $Configuration `
        -r win-x64 `
        --self-contained true `
        -p:Platform=x64 `
        -p:WindowsPackageType=None `
        -p:WindowsAppSDKSelfContained=true `
        -p:PublishSingleFile=false `
        -o $publishDir 2>&1 | Tee-Object -FilePath $logPath -Append

    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed with exit code $LASTEXITCODE."
    }

    $exe = Join-Path $publishDir "Paster.Windows.exe"
    if (-not (Test-Path $exe)) {
        throw "Publish completed but $exe was not found."
    }

    Write-Host "Published unpackaged executable:" -ForegroundColor Green
    Write-Host $exe
    "Publish succeeded: $exe" | Out-File -FilePath $logPath -Encoding utf8 -Append
}
finally {
    Pop-Location
}
