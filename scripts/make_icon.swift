import AppKit

// 将一张铺满画面的方形图，裁成 macOS 标准的 squircle 圆角图标（带透明边距与 alpha）。
// 用法: swift make_icon.swift <input.png> <output.png> [canvas=1024]

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: make_icon <input> <output> [canvas]\n".data(using: .utf8)!)
    exit(1)
}
let inputPath = args[1]
let outputPath = args[2]
let canvas = args.count >= 4 ? (Double(args[3]) ?? 1024) : 1024

guard let src = NSImage(contentsOfFile: inputPath) else {
    FileHandle.standardError.write("无法读取输入图片: \(inputPath)\n".data(using: .utf8)!)
    exit(1)
}

// 先把源图居中裁成正方形。
let srcSize = src.size
let side = min(srcSize.width, srcSize.height)
let cropOrigin = NSPoint(x: (srcSize.width - side) / 2, y: (srcSize.height - side) / 2)
let cropRect = NSRect(origin: cropOrigin, size: NSSize(width: side, height: side))

// macOS 图标网格：1024 画布中圆角矩形约 824，约 100px 透明边距。
let margin = canvas * 0.0977            // ≈100/1024
let contentSize = canvas - margin * 2
let cornerRadius = contentSize * 0.2245 // 接近 macOS squircle 视觉半径
let contentRect = NSRect(x: margin, y: margin, width: contentSize, height: contentSize)

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: Int(canvas),
                                 pixelsHigh: Int(canvas),
                                 bitsPerSample: 8,
                                 samplesPerPixel: 4,
                                 hasAlpha: true,
                                 isPlanar: false,
                                 colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0,
                                 bitsPerPixel: 0) else {
    exit(1)
}
rep.size = NSSize(width: canvas, height: canvas)

guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
ctx.imageInterpolation = .high

// 透明背景
NSColor.clear.set()
NSRect(x: 0, y: 0, width: canvas, height: canvas).fill()

// squircle 裁剪区域
let clip = NSBezierPath(roundedRect: contentRect, xRadius: cornerRadius, yRadius: cornerRadius)
clip.addClip()

// 把（裁方后的）源图铺满圆角区域
src.draw(in: contentRect,
         from: cropRect,
         operation: .copy,
         fraction: 1.0,
         respectFlipped: true,
         hints: [.interpolation: NSImageInterpolation.high])

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
do {
    try data.write(to: URL(fileURLWithPath: outputPath))
    print("已写入: \(outputPath) (\(Int(canvas))x\(Int(canvas)), 带 alpha)")
} catch {
    FileHandle.standardError.write("写入失败: \(error)\n".data(using: .utf8)!)
    exit(1)
}
