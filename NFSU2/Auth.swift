import Foundation
import Security
import WebKit

/// The game server. Fixed: the app connects straight to it.
let kServer = "https://nfsu2.city/"
let kSessionCookie = "nfsu2_session"

enum Keychain {
    private static let service = "party.mrvek.nfsu2"

    static func set(_ value: String, for key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(add as CFDictionary, nil) != errSecSuccess {
            UserDefaults.standard.set(value, forKey: "kc_" + key)      // fallback where the keychain is unavailable
        }
    }

    static func get(_ key: String) -> String? {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
           let d = out as? Data, let s = String(data: d, encoding: .utf8) { return s }
        q.removeAll()
        return UserDefaults.standard.string(forKey: "kc_" + key)
    }

    static func delete(_ key: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(q as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "kc_" + key)
    }
}

struct AuthResult: Decodable { let token: String; let username: String }
private struct APIError: Decodable { let error: String }

enum AuthError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

enum AuthAPI {
    private static func url(_ path: String) -> URL { URL(string: kServer + path)! }

    static func login(username: String, password: String) async throws -> AuthResult {
        try await post("auth/login", ["username": username, "password": password])
    }

    static func register(username: String, password: String, invite: String) async throws -> AuthResult {
        try await post("auth/register", ["username": username, "password": password, "invite": invite])
    }

    /// true: token still valid, false: rejected, nil: could not reach the server
    static func check(token: String) async -> Bool? {
        var req = URLRequest(url: url("auth/me"), timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }
        if http.statusCode == 200 { return true }
        if http.statusCode == 401 { return false }
        return nil
    }

    static func logout(token: String) async {
        var req = URLRequest(url: url("auth/logout"), timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: req)
    }

    private static func post(_ path: String, _ body: [String: String]) async throws -> AuthResult {
        var req = URLRequest(url: url(path), timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw AuthError.message("Can't reach the server") }
        guard let http = resp as? HTTPURLResponse else { throw AuthError.message("Bad response") }
        if http.statusCode == 200, let r = try? JSONDecoder().decode(AuthResult.self, from: data) { return r }
        if let e = try? JSONDecoder().decode(APIError.self, from: data) { throw AuthError.message(e.error) }
        throw AuthError.message("Failed (\(http.statusCode))")
    }
}

/// Puts the login's session in the web view as the cookie the gate checks, then calls done.
func installSessionCookie(on store: WKHTTPCookieStore, token: String, done: @escaping () -> Void) {
    guard let host = URL(string: kServer)?.host, let cookie = HTTPCookie(properties: [
        .domain: host, .path: "/", .name: kSessionCookie, .value: token,
        .secure: "TRUE", .expires: Date().addingTimeInterval(90 * 86400),
    ]) else { done(); return }
    store.setCookie(cookie) { done() }
}
