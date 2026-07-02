import Foundation

// 手工组装 .icns（绕过本机损坏的 iconutil 打包路径）。
// 将多张 PNG 按 ICNS OSType 槽位写入。
// 用法: swift make_icns.swift <pngDir> <output.icns>

guard CommandLine.arguments.count >= 3 else {
    FileHandle.standardError.write("usage: make_icns <pngDir> <output.icns>\n".data(using: .utf8)!)
    exit(1)
}
let dir = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]

// OSType -> 对应 PNG 像素尺寸（文件名 icon_<size>.png）
// 注意：不要使用 icp4(16)/icp5(32) 承载 PNG —— 本机 macOS 对这两个槽位的
// PNG 解码存在问题，会导致列表/侧栏里的小图标花屏。改由 ic11/ic12 等
// 现代 PNG 槽位提供小尺寸，NSImage/Finder 会据此正确缩放渲染。
let slots: [(type: String, size: Int)] = [
    ("ic11", 32),   // 16x16@2x
    ("ic12", 64),   // 32x32@2x
    ("ic07", 128),  // 128x128
    ("ic13", 256),  // 128x128@2x
    ("ic08", 256),  // 256x256
    ("ic14", 512),  // 256x256@2x
    ("ic09", 512),  // 512x512
    ("ic10", 1024), // 512x512@2x / 1024
]

func beUInt32(_ value: Int) -> Data {
    var v = UInt32(value).bigEndian
    return Data(bytes: &v, count: 4)
}

var body = Data()
for slot in slots {
    let path = "\(dir)/icon_\(slot.size).png"
    guard let png = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        FileHandle.standardError.write("缺少文件: \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    body.append(slot.type.data(using: .ascii)!)
    body.append(beUInt32(png.count + 8)) // 块长度含 8 字节头
    body.append(png)
}

var file = Data()
file.append("icns".data(using: .ascii)!)
file.append(beUInt32(body.count + 8))
file.append(body)

do {
    try file.write(to: URL(fileURLWithPath: outPath))
    print("已写入 \(outPath): \(file.count) 字节，\(slots.count) 个槽位")
} catch {
    FileHandle.standardError.write("写入失败: \(error)\n".data(using: .utf8)!)
    exit(1)
}
