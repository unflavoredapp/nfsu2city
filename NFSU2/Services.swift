import Foundation
import Network

func formatBytes(_ b: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: b)
}

// ------------------------------------------------------------- preflight --
enum Preflight {
    case ok
    case lowSpace(free: Int64, need: Int64)
    case cellular
}

enum Device {
    static let fullDownload: Int64 = 3_100_000_000
    static let update: Int64 = 400_000_000

    static func freeBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }

    /// True on a cellular or personal-hotspot connection.
    static func onExpensiveNetwork() async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let m = NWPathMonitor()
            let lock = NSLock()
            var done = false
            m.pathUpdateHandler = { p in
                lock.lock(); defer { lock.unlock() }
                if done { return }
                done = true
                m.cancel()
                c.resume(returning: p.isExpensive)
            }
            m.start(queue: DispatchQueue.global())
        }
    }

    static func preflight(need: Int64) async -> Preflight {
        if let free = freeBytes(), free < need { return .lowSpace(free: free, need: need) }
        if await onExpensiveNetwork() { return .cellular }
        return .ok
    }
}

// ----------------------------------------------------------- server data --
struct PlayerCount {
    var inRoam: Int
    var online: Int
}

struct Profile {
    var name: String?
    var level: Int?
    var xp: Int?
    var xpNext: Int?        // XP needed for the next level
    var country: String?    // 2-letter code (shown as a flag) or a name
    var avatar: String?     // GIPHY id / link, another image URL (absolute or relative to the server), or a data: URI
}

enum ServerAPI {
    private static func get(_ path: String, token: String) async -> Data? {
        guard let url = URL(string: kServer + path) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (d, r) = try? await URLSession.shared.data(for: req),
              (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return d
    }

    /// Players in free roam now, from the game server's /players.
    static func players(token: String) async -> PlayerCount? {
        guard let d = await get("players", token: token),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        let n = (j["players"] as? NSNumber)?.intValue ?? 0
        let roam = (j["roam"] as? NSNumber)?.intValue
        return PlayerCount(inRoam: roam ?? n, online: (j["online"] as? NSNumber)?.intValue ?? n)
    }

    /// The player's gamer-card data, read from the account response (auth/me). Field names are matched loosely
    /// (level/lvl, xp/exp, country/countryCode, avatar/picture...), top level or inside user/profile/stats.
    static func profile(token: String) async -> Profile? {
        guard let d = await get("auth/me", token: token),
              let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        var flat: [String: Any] = [:]
        for k in ["data", "stats", "profile", "player", "user"] {
            if let sub = root[k] as? [String: Any] { for (a, b) in sub { flat[a.lowercased()] = b } }
        }
        for (a, b) in root { flat[a.lowercased()] = b }          // top level wins
        func num(_ keys: [String]) -> Int? {
            for k in keys {
                if let v = flat[k] {
                    if let n = v as? NSNumber { return n.intValue }
                    if let s = v as? String, let n = Double(s) { return Int(n) }
                }
            }
            return nil
        }
        func str(_ keys: [String]) -> String? {
            for k in keys { if let s = flat[k] as? String, !s.isEmpty { return s } }
            return nil
        }
        return Profile(
            name: str(["username", "name", "displayname"]),
            level: num(["level", "lvl"]),
            xp: num(["xp", "exp", "experience", "currentxp"]),
            xpNext: num(["xpnext", "nextxp", "xpmax", "nextlevelxp", "xpfornext", "xpneeded", "levelxp"]),
            country: str(["country", "countrycode", "cc", "flag"]),
            avatar: str(["giphy", "giphyurl", "giphyid", "gif", "gifurl", "avatargif", "avatar", "avatarurl", "picture", "photo", "image", "pfp", "icon"]))
    }

    struct Mod: Identifiable {
        let id = UUID()
        let name: String
        let date: String
        let files: Int
    }

    /// The extra game data packs (parts, cars) installed on the server, and a version that changes with them.
    static func mods(token: String) async -> (version: String, mods: [Mod])? {
        guard let d = await get("app/mods", token: token),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        let v = (j["version"] as? String) ?? ""
        let list = (j["mods"] as? [[String: Any]] ?? []).map {
            Mod(name: ($0["name"] as? String) ?? "Pack",
                date: ($0["date"] as? String) ?? "",
                files: ($0["files"] as? NSNumber)?.intValue ?? 0)
        }
        return (v, list)
    }
}

/// The update gate: play only with the same extra game data (server packs) as the server has.
enum ModsGate {
    /// True when the server has packs this phone has not downloaded yet.  False when it is current, has none, or
    /// cannot be reached (offline play stays possible).
    static func outOfDate(token: String) async -> Bool {
        guard let r = await ServerAPI.mods(token: token), !r.mods.isEmpty else { return false }
        return r.version != (UserDefaults.standard.string(forKey: "modsVersion") ?? "")
    }
}
