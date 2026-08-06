$ErrorActionPreference = "Stop"

$projectDir = Resolve-Path (Join-Path $PSScriptRoot "..\src\Paster.Windows")
$assetsDir = Join-Path $projectDir "Assets"
New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null

Add-Type -AssemblyName System.Drawing

function New-RoundedRectanglePath {
    param(
        [System.Drawing.RectangleF]$Rect,
        [float]$Radius
    )

    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $diameter = $Radius * 2
    $path.AddArc($Rect.X, $Rect.Y, $diameter, $diameter, 180, 90)
    $path.AddArc($Rect.Right - $diameter, $Rect.Y, $diameter, $diameter, 270, 90)
    $path.AddArc($Rect.Right - $diameter, $Rect.Bottom - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc($Rect.X, $Rect.Bottom - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    return $path
}

function New-PasterPng {
    param(
        [string]$Path,
        [int]$Size
    )

    $bitmap = [System.Drawing.Bitmap]::new($Size, $Size)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)

    $bg = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
        [System.Drawing.RectangleF]::new(0, 0, $Size, $Size),
        [System.Drawing.Color]::FromArgb(255, 44, 118, 255),
        [System.Drawing.Color]::FromArgb(255, 94, 92, 230),
        45
    )
    $bgPath = New-RoundedRectanglePath -Rect ([System.Drawing.RectangleF]::new(2, 2, $Size - 4, $Size - 4)) -Radius ([float]($Size * 0.20))
    $graphics.FillPath($bg, $bgPath)

    $paperBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(245, 255, 255, 255))
    $clipBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 32, 58, 124))
    $pen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(220, 255, 255, 255), [float]([Math]::Max(2, $Size / 32)))

    $paperPath = New-RoundedRectanglePath -Rect ([System.Drawing.RectangleF]::new($Size * 0.27, $Size * 0.22, $Size * 0.46, $Size * 0.58)) -Radius ([float]($Size * 0.06))
    $graphics.FillPath($paperBrush, $paperPath)
    $graphics.DrawLine($pen, $Size * 0.36, $Size * 0.42, $Size * 0.64, $Size * 0.42)
    $graphics.DrawLine($pen, $Size * 0.36, $Size * 0.54, $Size * 0.64, $Size * 0.54)
    $graphics.DrawLine($pen, $Size * 0.36, $Size * 0.66, $Size * 0.56, $Size * 0.66)
    $clipPath = New-RoundedRectanglePath -Rect ([System.Drawing.RectangleF]::new($Size * 0.38, $Size * 0.12, $Size * 0.24, $Size * 0.18)) -Radius ([float]($Size * 0.05))
    $graphics.FillPath($clipBrush, $clipPath)

    $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bgPath.Dispose()
    $paperPath.Dispose()
    $clipPath.Dispose()
    $graphics.Dispose()
    $bg.Dispose()
    $paperBrush.Dispose()
    $clipBrush.Dispose()
    $pen.Dispose()
    $bitmap.Dispose()
}

function Convert-PngToIco {
    param(
        [string]$PngPath,
        [string]$IcoPath
    )

    [byte[]]$png = [System.IO.File]::ReadAllBytes($PngPath)
    $stream = [System.IO.File]::Create($IcoPath)
    $writer = New-Object System.IO.BinaryWriter $stream
    try {
        $writer.Write([UInt16]0)
        $writer.Write([UInt16]1)
        $writer.Write([UInt16]1)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([UInt16]1)
        $writer.Write([UInt16]32)
        $writer.Write([UInt32]$png.Length)
        $writer.Write([UInt32]22)
        $writer.Write($png)
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

$png256 = Join-Path $assetsDir "Paster-256.png"
New-PasterPng -Path $png256 -Size 256
Convert-PngToIco -PngPath $png256 -IcoPath (Join-Path $assetsDir "Paster.ico")

New-PasterPng -Path (Join-Path $assetsDir "Square150x150Logo.png") -Size 150
New-PasterPng -Path (Join-Path $assetsDir "Square44x44Logo.png") -Size 44
New-PasterPng -Path (Join-Path $assetsDir "StoreLogo.png") -Size 50

# Donation QR codes are real payment artifacts and cannot be generated. Drop the genuine
# donate_wechat.png / donate_alipay.png into Assets\Donate to have the About page show them.
$donateDir = Join-Path $assetsDir "Donate"
New-Item -ItemType Directory -Force -Path $donateDir | Out-Null

Write-Host "Generated Paster icon assets." -ForegroundColor Green

$missingDonate = @("donate_wechat.png", "donate_alipay.png") |
    Where-Object { -not (Test-Path (Join-Path $donateDir $_)) }
if ($missingDonate.Count -gt 0) {
    Write-Host "Donation QR codes not found ($($missingDonate -join ', ')). The About page will hide them until you add the real images to $donateDir." -ForegroundColor Yellow
}
