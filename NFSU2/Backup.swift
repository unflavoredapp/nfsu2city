import SwiftUI
import UniformTypeIdentifiers

/// Where the copy of the game data lives: a folder the player picked in Files, outside the app, so it stays when the
/// app is deleted.  The app remembers it as a bookmark; after a reinstall the player picks the same folder again.
enum BackupStore {
    static let dirName = "NFSU2 Backup"
    private static let kBookmark = "backupFolderBookmark"
    private static let kName = "backupFolderName"
    private static let kDate = "backupDate"
    private static let kBytes = "backupBytes"
    private static let kSkip = "backupSkipped"

    static var hasFolder: Bool { UserDefaults.standard.data(forKey: kBookmark) != nil }
    static var folderName: String? { UserDefaults.standard.string(forKey: kName) }
    static var lastDate: Date? { UserDefaults.standard.object(forKey: kDate) as? Date }
    static var lastBytes: Int64 { Int64(UserDefaults.standard.double(forKey: kBytes)) }
    static var skipped: Bool {
        get { UserDefaults.standard.bool(forKey: kSkip) }
        set { UserDefaults.standard.set(newValue, forKey: kSkip) }
    }

    static func remember(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        if let d = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(d, forKey: kBookmark)
            UserDefaults.standard.set(url.lastPathComponent, forKey: kName)
        }
    }

    static func noteBackup(bytes: Int64) {
        UserDefaults.standard.set(Date(), forKey: kDate)
        UserDefaults.standard.set(Double(bytes), forKey: kBytes)
    }

    /// The folder, opened for use; call stopAccessingSecurityScopedResource() on it when done.
    static func open() -> URL? {
        guard let d = UserDefaults.standard.data(forKey: kBookmark) else { return nil }
        var stale = false
        guard let u = try? URL(resolvingBookmarkData: d, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = u.startAccessingSecurityScopedResource()
        return u
    }
}

struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let p = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        p.allowsMultipleSelection = false
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let u = urls.first { onPick(u) }
        }
    }
}

/// Copies the game data and the saves between the game's storage and the backup folder.
@MainActor
final class BackupJob: ObservableObject {
    enum Kind { case backup, restore }

    let bridge: OPFSBridge
    @Published var pct = 0.0
    @Published var message = "Preparing\u{2026}"
    @Published var running = false
    @Published var finished = false
    @Published var failure: String?
    @Published var dataComplete = false
    private var task: Task<Void, Never>?
    private let chunk: Int64 = 6 * 1024 * 1024

    init(token: String) { bridge = OPFSBridge(token: token) }

    func start(_ kind: Kind) {
        guard !running else { return }
        running = true; finished = false; failure = nil; pct = 0
        task = Task { await run(kind) }
    }

    func cancel() { task?.cancel() }

    private func run(_ kind: Kind) async {
        guard let folder = BackupStore.open() else { failure = "No backup folder is chosen."; running = false; return }
        defer { folder.stopAccessingSecurityScopedResource(); running = false }
        do {
            try await bridge.prepare()
            if kind == .backup { try await backup(folder) } else { try await restore(folder) }
            finished = true
        } catch is CancellationError {
            message = "Stopped. Start it again and it carries on."
            failure = "Stopped."
        } catch {
            failure = error.localizedDescription
        }
    }

    // ---------------------------------------------------------------- backup --
    private func backup(_ folder: URL) async throws {
        let fm = FileManager.default
        let root = folder.appendingPathComponent(BackupStore.dirName, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        message = "Looking at what is on this phone\u{2026}"
        let all = try await bridge.list()
        let byPath = Dictionary(all.map { ($0.p, $0) }, uniquingKeysWith: { a, _ in a })

        var todo: [OPFSEntry] = []
        for e in all {
            if e.p.hasPrefix("cache/") {
                if !e.current { continue }
                if e.p.hasSuffix(".have") {
                    guard let d = byPath[String(e.p.dropLast(5))], d.complete else { continue }
                } else if !e.complete { continue }
            }
            todo.append(e)
        }
        if todo.isEmpty { throw BridgeError("There is nothing to back up yet. Download the game data first.") }
        todo.sort { $0.p < $1.p }

        let total = max(1, todo.reduce(Int64(0)) { $0 + $1.s })
        if let free = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < total + 200_000_000 {
            throw BridgeError("Not enough space in that folder's storage: it needs \(formatBytes(total)), \(formatBytes(free)) is free.")
        }

        var done: Int64 = 0
        for e in todo {
            try Task.checkCancellation()
            let dest = root.appendingPathComponent(e.p)
            let isCacheData = e.p.hasPrefix("cache/") && !e.p.hasSuffix(".have")
            if isCacheData, let a = try? fm.attributesOfItem(atPath: dest.path), (a[.size] as? NSNumber)?.int64Value == e.s {
                done += e.s; pct = Double(done) / Double(total) * 100; continue      // already there
            }
            if e.s > 1_000_000 { message = "Backing up " + (e.p as NSString).lastPathComponent }
            try await copyOut(e, to: dest) { n in
                done += n; self.pct = Double(done) / Double(total) * 100
            }
        }
        let info: [String: Any] = ["version": 1, "date": ISO8601DateFormatter().string(from: Date()), "bytes": total, "files": todo.count]
        try JSONSerialization.data(withJSONObject: info).write(to: root.appendingPathComponent("info.json"), options: .atomic)
        BackupStore.noteBackup(bytes: total)
        pct = 100
        message = "Backed up: \(formatBytes(total)) in \u{201C}\(BackupStore.folderName ?? "your folder")\u{201D}."
    }

    private func copyOut(_ e: OPFSEntry, to dest: URL, progress: (Int64) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = dest.appendingPathExtension("part")
        fm.createFile(atPath: part.path, contents: nil)
        let fh = try FileHandle(forWritingTo: part)
        do {
            var off: Int64 = 0
            while off < e.s {
                try Task.checkCancellation()
                let n = min(chunk, e.s - off)
                let b64 = try await bridge.read(e.p, offset: off, length: n)
                guard let data = Data(base64Encoded: b64), Int64(data.count) == n else { throw BridgeError("Couldn't read \(e.p).") }
                try fh.write(contentsOf: data)
                off += n; progress(n)
            }
            try fh.close()
        } catch {
            try? fh.close()
            try? fm.removeItem(at: part)
            throw error
        }
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: part, to: dest)
    }

    // --------------------------------------------------------------- restore --
    private func restore(_ folder: URL) async throws {
        let fm = FileManager.default
        let root = folder.appendingPathComponent(BackupStore.dirName, isDirectory: true)
        guard fm.fileExists(atPath: root.appendingPathComponent("info.json").path) else {
            throw BridgeError("There is no NFSU2 backup in that folder.")
        }
        message = "Reading the backup\u{2026}"
        var files: [(rel: String, url: URL, size: Int64)] = []
        let base = root.pathComponents.count
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
            for case let u as URL in en {
                let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard v?.isRegularFile == true else { continue }
                let rel = u.pathComponents.dropFirst(base).joined(separator: "/")
                if rel == "info.json" || rel.hasSuffix(".part") { continue }
                files.append((rel, u, Int64(v?.fileSize ?? 0)))
            }
        }
        files.sort { $0.rel < $1.rel }
        try await bridge.prepare()
        let existing = try await bridge.list()
        let have = Dictionary(existing.map { ($0.p, $0) }, uniquingKeysWith: { a, _ in a })

        var todo: [(rel: String, url: URL, size: Int64)] = []
        var restoredData = Set<String>()
        for f in files {
            if f.rel.hasPrefix("cache/") {
                if f.rel.hasSuffix(".have") {
                    if restoredData.contains(String(f.rel.dropLast(5))) { todo.append(f) }
                } else if have[f.rel]?.complete != true {
                    todo.append(f); restoredData.insert(f.rel)
                }
            } else if have[f.rel] == nil {
                todo.append(f)                     // saves: never over a save that is already here
            }
        }
        let total = max(1, todo.reduce(Int64(0)) { $0 + $1.size })
        if let free = Device.freeBytes(), !todo.isEmpty, free < total + 700_000_000 {
            throw BridgeError("Not enough space on this phone: it needs about \(formatBytes(total + 700_000_000)), \(formatBytes(free)) is free.")
        }

        var done: Int64 = 0
        for f in todo {
            try Task.checkCancellation()
            if f.size > 1_000_000 { message = "Restoring " + (f.rel as NSString).lastPathComponent }
            try await bridge.beginWrite(f.rel)
            do {
                let fh = try FileHandle(forReadingFrom: f.url)
                defer { try? fh.close() }
                while true {
                    try Task.checkCancellation()
                    guard let data = try fh.read(upToCount: Int(chunk)), !data.isEmpty else { break }
                    try await bridge.write(data.base64EncodedString())
                    done += Int64(data.count); pct = Double(done) / Double(total) * 100
                }
                try await bridge.endWrite()
            } catch {
                await bridge.abortWrite()
                throw error
            }
        }
        message = "Checking the game data\u{2026}"
        let r = try await bridge.verify(deleteOrphans: false)
        dataComplete = r.complete
        pct = 100
        message = r.complete ? "Restored. All the game data is back on this phone."
                             : "Restored what the backup had. The rest downloads next."
    }
}
