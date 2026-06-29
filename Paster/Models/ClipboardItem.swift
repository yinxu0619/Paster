import Foundation
import SwiftData

/// 单条剪贴板历史记录的持久化模型（SwiftData）。
///
/// 设计原则：所有非主键字段尽量带默认值或为可选，方便后续轮次通过「新增字段」
/// 进行轻量级迁移（lightweight migration），而不破坏已存在的数据。
///
/// 第 2 轮在第 1 轮基础上「新增」富文本/图片/文件/URL 与来源应用相关字段。
@Model
final class ClipboardItem {
    /// 稳定唯一标识。
    var id: UUID = UUID()

    /// 类型标签（存储 `ClipboardItemType` 的 rawValue）。
    var typeRaw: String = ClipboardItemType.text.rawValue

    /// 文本 / 富文本的纯文本表示，亦用于搜索与预览。
    var text: String?

    /// 富文本原始 RTF 数据（仅富文本类型）。
    var rtfData: Data? = nil

    /// 图片原图数据（PNG，仅图片类型）。
    var imageData: Data? = nil

    /// 图片缩略图数据（PNG，用于列表快速预览，避免加载原图）。
    var thumbnailData: Data? = nil

    /// 文件 URL 字符串（file://...，可为多文件换行拼接的首个）。
    var fileURLString: String? = nil

    /// 网页链接字符串（仅 URL 类型）。
    var urlString: String? = nil

    /// 来源应用名称。
    var sourceAppName: String? = nil

    /// 来源应用 Bundle ID（用于获取应用图标）。
    var sourceBundleID: String? = nil

    /// 是否被固定到 Pinboard（第 3 轮新增）。
    var isPinned: Bool = false

    /// 固定时间（用于 Pinboard 内排序，未固定为 nil）。
    var pinnedAt: Date? = nil

    /// 复制时间戳。
    var createdAt: Date = Date()

    /// 类型的便捷访问器。
    var type: ClipboardItemType {
        get { ClipboardItemType(rawValue: typeRaw) ?? .text }
        set { typeRaw = newValue.rawValue }
    }

    /// 第 1 轮保留的纯文本便捷初始化器（增量兼容，不删除）。
    init(text: String, type: ClipboardItemType = .text, createdAt: Date = Date()) {
        self.id = UUID()
        self.text = text
        self.typeRaw = type.rawValue
        self.createdAt = createdAt
    }

    /// 第 2 轮新增的全字段初始化器。
    init(type: ClipboardItemType,
         text: String? = nil,
         rtfData: Data? = nil,
         imageData: Data? = nil,
         thumbnailData: Data? = nil,
         fileURLString: String? = nil,
         urlString: String? = nil,
         sourceAppName: String? = nil,
         sourceBundleID: String? = nil,
         createdAt: Date = Date()) {
        self.id = UUID()
        self.typeRaw = type.rawValue
        self.text = text
        self.rtfData = rtfData
        self.imageData = imageData
        self.thumbnailData = thumbnailData
        self.fileURLString = fileURLString
        self.urlString = urlString
        self.sourceAppName = sourceAppName
        self.sourceBundleID = sourceBundleID
        self.createdAt = createdAt
    }
}

extension ClipboardItem {
    /// 列表中展示的内容预览（去除首尾空白）。
    var previewText: String {
        switch type {
        case .text, .richText:
            return (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        case .url:
            return urlString ?? (text ?? "")
        case .file:
            return fileDisplayNames
        case .image:
            return "图片"
        }
    }

    /// 文件类型的展示名称（取路径最后一段，多文件换行展示）。
    var fileDisplayNames: String {
        guard let raw = fileURLString ?? text else { return "文件" }
        return raw
            .split(separator: "\n")
            .map { line -> String in
                let s = String(line)
                let url = URL(string: s) ?? URL(fileURLWithPath: s)
                return url.lastPathComponent
            }
            .joined(separator: "\n")
    }

    /// 纯文本粘贴时使用的内容（剥离所有富格式）。
    var plainTextRepresentation: String {
        if let text, !text.isEmpty { return text }
        if let urlString { return urlString }
        if let fileURLString { return fileURLString }
        return previewText
    }

    /// 用于与最近一条做去重比较的键。
    var deduplicationKey: String {
        switch type {
        case .image:
            return "image:\(imageData?.count ?? 0)"
        case .file:
            return "file:\(fileURLString ?? text ?? "")"
        default:
            return "\(typeRaw):\(text ?? urlString ?? "")"
        }
    }
}
