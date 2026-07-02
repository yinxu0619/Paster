import AppKit

// 用 NSImage（Finder/图标服务同一套渲染管线）把 .icns 在指定点尺寸下光栅化，
// 保存 PNG，用于人工核验小图标是否正常。
// 用法: swift probe_render.swift <icns> <outDir>

guard CommandLine.arguments.count >= 3 else {
    FileHandle.standardError.write("usage: probe_render <icns> <outDir>\n".data(using: .utf8)!)
    exit(1)
}
let icnsPath = CommandLine.arguments[1]
let outDir = CommandLine.arguments[2]

guard let img = NSImage(contentsOfFile: icnsPath) else {
    FileHandle.standardError.write("无法加载 \(icnsPath)\n".data(using: .utf8)!)
    exit(1)
}

func render(_ points: Int) {
    let px = points // 1x 渲染
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
             from: .zero, operation: .sourceOver, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    if let data = rep.representation(using: .png, properties: [:]) {
        let out = "\(outDir)/render_\(points).png"
        try? data.write(to: URL(fileURLWithPath: out))
        print("rendered \(out)")
    }
}

for s in [16, 32, 64, 128] { render(s) }
