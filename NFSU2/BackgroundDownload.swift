import Foundation
import UIKit
import UserNotifications

struct PlanFile: Codable {
    let k: String      // the game's cache name for the file: path.size.mtime
    let p: String      // path on the server
    let s: Int64
}

/// Downloads the game data with iOS's own background transfer service, so it carries on with the app closed or the
/// phone locked.  Each file lands in a staging folder laid out like the game's cache (cache/<name>, cache/<name>.have);
/// when the app is next open the files are moved into the game's storage (BackupJob .stage) and the page's own
/// preload mops up anything left (BackgroundDownload never has to match its file choice exactly).
final class BGDownload: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = BGDownload()
    static let sessionID = "party.mrvek.nfsu2.data"
    private static let block: Int64 = 1 << 20

    @Published var doneBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var active = false         // files still coming down
    @Published var complete = false       // every planned file is in staging
    @Published var error: String?

    /// handed over by the app delegate when iOS relaunches the app for a finished transfer
    var backgroundCompletion: (() -> Void)?

    private var session: URLSession!
    private var plan: [PlanFile] = []
    private var byKey: [String: PlanFile] = [:]
    private var doneSet = Set<String>()
    private var doneSum: Int64 = 0
    private var inflight: [Int: Int64] = [:]
    private var attempts: [String: Int] = [:]
    private var live = Set<String>()          // files with a transfer running (never two for one file)
    private var high: Int64 = 0               // the figure shown only goes up

    static var stageDir: URL {
        let fm = FileManager.default
        var base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NFSU2Stage", isDirectory: true)
        try? fm.createDirectory(at: base.appendingPathComponent("cache", isDirectory: true), withIntermediateDirectories: true)
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        try? base.setResourceValues(rv)
        return base
    }
    private static var planURL: URL { stageDir.appendingPathComponent("plan.json") }

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        cfg.sessionSendsLaunchEvents = true
        cfg.isDiscretionary = false
        cfg.waitsForConnectivity = true
        cfg.httpMaximumConnectionsPerHost = 3
        cfg.timeoutIntervalForResource = 7 * 24 * 3600
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
        loadPlan()
    }

    // ------------------------------------------------------------------ plan --
    private func loadPlan() {
        guard let d = try? Data(contentsOf: Self.planURL), let p = try? JSONDecoder().decode([PlanFile].self, from: d) else { return }
        setPlan(p)
        session.getAllTasks { tasks in
            DispatchQueue.main.async { self.active = !self.complete && !self.plan.isEmpty && (!tasks.isEmpty || self.doneSet.count < self.plan.count) }
        }
    }

    private func haveURL(_ k: String) -> URL { Self.stageDir.appendingPathComponent("cache/\(k).have") }

    private func setPlan(_ p: [PlanFile]) {
        plan = p
        byKey = Dictionary(p.map { ($0.k, $0) }, uniquingKeysWith: { a, _ in a })
        doneSet = Set(p.filter { FileManager.default.fileExists(atPath: haveURL($0.k).path) }.map { $0.k })
        doneSum = p.filter { doneSet.contains($0.k) }.reduce(0) { $0 + $1.s }
        totalBytes = p.reduce(0) { $0 + $1.s }
        high = 0
        publish()
        complete = !p.isEmpty && doneSet.count == p.count
        active = !p.isEmpty && !complete
    }

    private func publish() {
        let v = min(totalBytes, doneSum + inflight.values.reduce(0, +))
        high = max(high, v)
        if doneBytes != high { doneBytes = high }
    }

    /// Files of the server's list this download takes: the game's core data (not the movies, texture and language
    /// packs, or the alternate songs, which the page fetches itself when they are wanted).
    private static func wanted(_ path: String) -> Bool {
        let p = path.lowercased().split(separator: "/").map(String.init)
        guard let top = p.first else { return false }
        if ["movies", "texpacks", "langpacks"].contains(top) { return false }
        if top == "pfdata", p.count == 3, p[1] == "original" { return false }
        return true
    }

    private static func cacheKey(_ p: String, _ s: Int64, _ m: Int64) -> String {
        var out = ""
        for u in p.unicodeScalars {
            let c = Character(u)
            out.append(("A"..."Z" ~= c || "a"..."z" ~= c || "0"..."9" ~= c || c == "." || c == "_" || c == "-") ? c : "_")
        }
        return "\(out).\(s).\(m)"
    }

    private static let uriSafe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    private func url(for f: PlanFile) -> URL? {
        let path = f.p.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: Self.uriSafe) ?? String($0) }.joined(separator: "/")
        return URL(string: kServer + "data/" + path)
    }

    // ----------------------------------------------------------------- start --
    /// Plans and starts the download of everything the game's storage does not have yet (skip: names it has whole);
    /// returns how many files there are to fetch.
    @MainActor
    func start(token: String, skip: Set<String>) async throws -> Int {
        error = nil
        guard let mURL = URL(string: kServer + "data-manifest") else { return 0 }
        var req = URLRequest(url: mURL, timeoutInterval: 30)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = j["files"] as? [[String: Any]] else { throw BridgeError("The server did not send its file list.") }

        var p: [PlanFile] = []
        for f in files {
            guard let path = f["p"] as? String, ((f["d"] as? NSNumber)?.intValue ?? 0) == 0, Self.wanted(path) else { continue }
            let s = (f["s"] as? NSNumber)?.int64Value ?? 0, m = (f["m"] as? NSNumber)?.int64Value ?? 0
            if s <= 0 { continue }
            let k = Self.cacheKey(path, s, m)
            if skip.contains(k) { continue }
            p.append(PlanFile(k: k, p: path, s: s))
        }
        if !plan.isEmpty, Set(plan.map { $0.k }) == Set(p.map { $0.k }) {          // the same download, already going: leave it
            Self.askNotifications()
            let pending: [URLSessionTask] = await withCheckedContinuation { c in session.getAllTasks { c.resume(returning: $0) } }
            live = Set(pending.compactMap { $0.taskDescription })
            enqueueMissing(token: token)
            return p.count - doneSet.count
        }
        session.getAllTasks { $0.forEach { $0.cancel() } }
        inflight.removeAll(); attempts.removeAll(); live.removeAll()
        try? JSONEncoder().encode(p).write(to: Self.planURL, options: .atomic)
        setPlan(p)
        if p.isEmpty { return 0 }
        Self.askNotifications()
        enqueueMissing(token: token)
        return p.count - doneSet.count
    }

    /// After the app was force-quit (which stops transfers): put the missing files back in the queue.
    @MainActor
    func resumeIfNeeded(token: String) async {
        guard !plan.isEmpty, !complete else { return }
        let pending: [URLSessionTask] = await withCheckedContinuation { c in session.getAllTasks { c.resume(returning: $0) } }
        let have = Set(pending.compactMap { $0.taskDescription })
        live = have
        enqueueMissing(token: token, except: have)
    }

    private func enqueueMissing(token: String, except: Set<String> = []) {
        for f in plan where !doneSet.contains(f.k) && !except.contains(f.k) { enqueue(f, token: token) }
    }

    private func enqueue(_ f: PlanFile, token: String) {
        guard !live.contains(f.k), !doneSet.contains(f.k), let u = url(for: f) else { return }
        live.insert(f.k)
        var r = URLRequest(url: u)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let t = session.downloadTask(with: r)
        t.taskDescription = f.k
        t.countOfBytesClientExpectsToReceive = f.s
        t.resume()
    }

    func cancelAll() {
        session.getAllTasks { $0.forEach { $0.cancel() } }
        reset()
    }

    /// Staging is emptied (after its files went into the game's storage, or a cancel).
    func reset() {
        try? FileManager.default.removeItem(at: Self.stageDir)
        plan = []; byKey = [:]; doneSet = []; doneSum = 0; inflight = [:]; attempts = [:]; live = []; high = 0
        doneBytes = 0; totalBytes = 0; active = false; complete = false
    }

    private static func askNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyDone() {
        let c = UNMutableNotificationContent()
        c.title = "NFSU2.City"
        c.body = "The game data is downloaded. Open the app to finish setup."
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "dataDone", content: c, trigger: nil))
    }

    // -------------------------------------------------------------- delegate --
    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let k = t.taskDescription, let f = byKey[k], !doneSet.contains(k) else { return }
        inflight[t.taskIdentifier] = min(totalBytesWritten, f.s)
        publish()
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let k = t.taskDescription, let f = byKey[k] else { return }
        let code = (t.response as? HTTPURLResponse)?.statusCode ?? 0
        let fm = FileManager.default
        let size = ((try? fm.attributesOfItem(atPath: location.path))?[.size] as? NSNumber)?.int64Value ?? -1
        guard code == 200, size == f.s else { return }                 // didCompleteWithError retries it
        let dest = Self.stageDir.appendingPathComponent("cache/\(k)")
        try? fm.removeItem(at: dest)
        do {
            try fm.moveItem(at: location, to: dest)
            let nb = Int((f.s + Self.block - 1) / Self.block)
            try Data(repeating: 1, count: nb).write(to: haveURL(k), options: .atomic)      // the map: every block is there
        } catch { return }
        if doneSet.insert(k).inserted { doneSum += f.s }
        inflight[t.taskIdentifier] = nil
        publish()
    }

    func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError e: Error?) {
        inflight[t.taskIdentifier] = nil
        if let k = t.taskDescription { live.remove(k) }
        if let k = t.taskDescription, !doneSet.contains(k), (e as NSError?)?.code != NSURLErrorCancelled, byKey[k] != nil {
            let n = (attempts[k] ?? 0) + 1
            attempts[k] = n
            if n <= 6, let f = byKey[k], let token = Keychain.get("token") {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(n) * 5) { [weak self] in self?.enqueue(f, token: token) }
            } else {
                error = "Some files would not download. Open Game Files and choose Repair."
            }
        }
        publish()
        if !plan.isEmpty, doneSet.count == plan.count, !complete {
            complete = true; active = false
            notifyDone()
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}
