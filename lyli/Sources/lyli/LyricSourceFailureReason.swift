import Foundation

enum LyricSourceFailureReason {
    static func text(forCode code: String) -> String {
        switch code {
        case "dns_failed":
            return "域名解析失败（DNS）"
        case "connect_failed":

            return "连接失败或超时"
        case "server_error":
            return "服务器错误（HTTP 5xx）"
        case "upstream_unreachable":
            return "无法连接歌词源"

        case "local_cache_miss":
            return "当前歌曲尚无可匹配的 Apple Music 缓存歌词"
        case "local_cache_unreadable":
            return "Apple Music 本地缓存暂不可读"
        case "no_response":
            return "未返回歌词候选"
        case "network_down":
            return "网络请求全部失败"
        default:

            return code
        }
    }
}
