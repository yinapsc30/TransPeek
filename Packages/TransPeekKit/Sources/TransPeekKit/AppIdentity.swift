/// 全局标识。日志 subsystem 和钥匙串 service 统一使用这个值（design.md「错误处理」「TranslationService」）。
public enum AppIdentity {
    public static let subsystem = "com.transpeek.app"
}
