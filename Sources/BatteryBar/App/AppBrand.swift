import Foundation

/// 用户可见品牌与内部兼容标识分离。
///
/// 产品名称统一使用 BatteryArchive，不使用中文名或简称。
/// 功能说明保持中文。版本 1.0.0 / build 1。
///
/// 兼容边界不变：可执行文件、bundle 文件名、Bundle ID、Helper/XPC/launchd、
/// 数据目录与 UserDefaults 继续沿用 BatteryBar。全部记录仅保存在本机。
enum AppBrand {
    static let displayName = "BatteryArchive"
    static let tagline = "电池健康与功耗记录"
    static let version = "1.0.0"
    static let build = "1"

}
