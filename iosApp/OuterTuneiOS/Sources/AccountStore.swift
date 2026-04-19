import Foundation
import Combine

struct YouTubeAccountInfo: Codable, Equatable {
    var name: String
    var email: String?
    var channelHandle: String?
    var avatarURL: String?
}

/// 儲存 YouTube Music 登入所需的認證資訊（cookie / VISITOR_DATA / DATASYNC_ID）
/// 以及目前登入的使用者基本資料。對應 Android 版的 InnerTubeCookieKey / VisitorDataKey /
/// DataSyncIdKey / AccountNameKey 等 preference。
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published private(set) var cookie: String = ""
    @Published private(set) var visitorData: String = ""
    @Published private(set) var dataSyncId: String = ""
    @Published private(set) var accountInfo: YouTubeAccountInfo?

    private let cookieKey = "ios.account.cookie.v1"
    private let visitorDataKey = "ios.account.visitorData.v1"
    private let dataSyncIdKey = "ios.account.dataSyncId.v1"
    private let accountInfoKey = "ios.account.info.v1"

    private init() {
        restore()
    }

    var isLoggedIn: Bool {
        !cookie.isEmpty && cookie.contains("SAPISID")
    }

    func updateCookie(_ value: String) {
        cookie = value
        UserDefaults.standard.set(value, forKey: cookieKey)
    }

    func updateVisitorData(_ value: String) {
        guard !value.isEmpty else { return }
        visitorData = value
        UserDefaults.standard.set(value, forKey: visitorDataKey)
    }

    func updateDataSyncId(_ value: String) {
        guard !value.isEmpty else { return }
        let normalized = value.components(separatedBy: "||").first ?? value
        dataSyncId = normalized
        UserDefaults.standard.set(normalized, forKey: dataSyncIdKey)
    }

    func updateAccountInfo(_ info: YouTubeAccountInfo?) {
        accountInfo = info
        if let info, let data = try? JSONEncoder().encode(info) {
            UserDefaults.standard.set(data, forKey: accountInfoKey)
        } else {
            UserDefaults.standard.removeObject(forKey: accountInfoKey)
        }
    }

    func logout() {
        cookie = ""
        visitorData = ""
        dataSyncId = ""
        accountInfo = nil
        UserDefaults.standard.removeObject(forKey: cookieKey)
        UserDefaults.standard.removeObject(forKey: visitorDataKey)
        UserDefaults.standard.removeObject(forKey: dataSyncIdKey)
        UserDefaults.standard.removeObject(forKey: accountInfoKey)
        // 清除 WKWebView / HTTPCookieStorage 中的 google / youtube cookies
        let storage = HTTPCookieStorage.shared
        if let cookies = storage.cookies {
            for cookie in cookies where cookie.domain.contains("google") || cookie.domain.contains("youtube") {
                storage.deleteCookie(cookie)
            }
        }
    }

    private func restore() {
        if let value = UserDefaults.standard.string(forKey: cookieKey) {
            cookie = value
        }
        if let value = UserDefaults.standard.string(forKey: visitorDataKey) {
            visitorData = value
        }
        if let value = UserDefaults.standard.string(forKey: dataSyncIdKey) {
            dataSyncId = value
        }
        if let data = UserDefaults.standard.data(forKey: accountInfoKey),
           let restored = try? JSONDecoder().decode(YouTubeAccountInfo.self, from: data) {
            accountInfo = restored
        }
    }

    /// 取 cookie 字串中的 SAPISID 值，用來計算 Authorization SAPISIDHASH header。
    func sapisidValue() -> String? {
        guard !cookie.isEmpty else { return nil }
        for entry in cookie.split(separator: ";") {
            let pair = entry.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let name = String(pair[0])
            let value = String(pair[1])
            if name == "SAPISID" || name == "__Secure-3PAPISID" {
                return value
            }
        }
        return nil
    }
}
