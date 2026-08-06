param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug"
)

$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$solution = Join-Path $root "Paster.Windows.sln"
$localDotnet = Join-Path $root ".dotnet\dotnet.exe"

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue) -and (Test-Path $localDotnet)) {
    $env:DOTNET_ROOT = Split-Path $localDotnet
    $env:PATH = "$env:DOTNET_ROOT;$env:PATH"
}

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet was not found. Run .\scripts\install-dotnet-sdk.ps1 first, then reopen this PowerShell window or run this script again."
}

Push-Location $root
try {
    dotnet restore $solution
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet restore failed with exit code $LASTEXITCODE."
    }

    dotnet build $solution -c $Configuration -p:Platform=x64 --no-restore
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet build failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}
