import Foundation

/// 文字系统判断（R8.9）。
public enum TextScript {
    /// 是否包含中文（汉字），且不含日文假名和韩文。
    /// 日文、韩文中也可能出现汉字，含假名或韩文的行视为日文/韩文，仍需翻译。
    public static func containsChinese(_ text: String) -> Bool {
        var hasHan = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: // 平假名、片假名
                return false
            case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: // 韩文
                return false
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2EBEF:
                hasHan = true
            default:
                continue
            }
        }
        return hasHan
    }
}

extension Language {
    /// 简体或繁体中文。
    public var isChinese: Bool { code.lowercased().hasPrefix("zh") }
}
