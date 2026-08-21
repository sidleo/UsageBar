import Foundation
import Security

// ==========================================
// 配置存储
// - workspaceID / baseURL: UserDefaults（非敏感）
// - cookie: Keychain（完整用户会话，等同密码）
// ==========================================

enum Config {
    struct Stored: Codable, Equatable {
        var workspaceID: String = ""
        var baseURL: String = "https://opencode.ai"
        var cookie: String = ""
        var refreshIntervalSec: Int = 300  // 自动刷新间隔（秒）
        var menuBarDisplay: String = "auto"  // 菜单栏显示哪个窗口: auto/rolling/weekly/monthly
        var activeService: String = "opencode"  // 菜单栏当前显示的服务: opencode/commandcode

        var isComplete: Bool {
            !workspaceID.isEmpty && !cookie.isEmpty
        }

        init() {}

        init(workspaceID: String, baseURL: String, cookie: String,
             refreshIntervalSec: Int = 300, menuBarDisplay: String = "auto",
             activeService: String = "opencode") {
            self.workspaceID = workspaceID
            self.baseURL = baseURL
            self.cookie = cookie
            self.refreshIntervalSec = refreshIntervalSec
            self.menuBarDisplay = menuBarDisplay
            self.activeService = activeService
        }

        /// 容错 decode：历史/手写配置可能缺字段，缺失时用默认值
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            workspaceID = try c.decodeIfPresent(String.self, forKey: .workspaceID) ?? ""
            baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://opencode.ai"
            cookie = try c.decodeIfPresent(String.self, forKey: .cookie) ?? ""
            refreshIntervalSec = try c.decodeIfPresent(Int.self, forKey: .refreshIntervalSec) ?? 300
            menuBarDisplay = try c.decodeIfPresent(String.self, forKey: .menuBarDisplay) ?? "auto"
            activeService = try c.decodeIfPresent(String.self, forKey: .activeService) ?? "opencode"
        }
    }

    private static let defaultsKey = "config"
    private static let keychainService = "com.zhang3.usagebar"
    private static let keychainAccount = "opencode-go-cookie"

    static func load() -> Stored {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            var c = decoded
            c.cookie = keychainRead() ?? ""
            return c
        }
        return Stored()
    }

    static func save(_ c: Stored) {
        var toStore = c
        toStore.cookie = ""  // cookie 单独进 Keychain
        if let data = try? JSONEncoder().encode(toStore) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        if c.cookie.isEmpty {
            keychainDelete()
        } else {
            keychainWrite(c.cookie)
        }
    }

    // MARK: - Keychain

    static func keychainDelete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func keychainWrite(_ value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func keychainRead() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
