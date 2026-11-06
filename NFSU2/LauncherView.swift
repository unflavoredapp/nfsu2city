import SwiftUI

enum LauncherTab: CaseIterable {
    case home, files, mods, settings, about
    var title: String {
        switch self {
        case .home: return "Home"
        case .files: return "Game Files"
        case .mods: return "Mods"
        case .settings: return "Settings"
        case .about: return "About"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house"
        case .files: return "folder"
        case .mods: return "puzzlepiece.extension"
        case .settings: return "gearshape"
        case .about: return "info.circle"
        }
    }
}

enum PreAlert: Identifiable {
    case lowSpace(free: Int64, need: Int64)
    case cellular
    var id: Int { switch self { case .lowSpace: return 0; case .cellular: return 1 } }
}

struct LauncherView: View {
    let username: String
    let token: String
    let installed: Bool
    let go: (Stage) -> Void
    let onLogout: () -> Void
    @State private var tab = LauncherTab.home
    @State private var alert: PreAlert?
    @State private var players: PlayerCount?
    @ObservedObject private var dl = BGDownload.shared
    @AppStorage("chatOn") private var chatOn = true

    /// Space and connection checks first, then the game data download.
    private func startInstall(update: Bool = false) {
        Task {
            switch await Device.preflight(need: (installed || update) ? Device.update : Device.fullDownload) {
            case .ok: go(.installing)
            case .lowSpace(let free, let need): alert = .lowSpace(free: free, need: need)
            case .cellular: alert = .cellular
            }
        }
    }

    /// Play, after the update gate: new server packs come down first.
    private func play() {
        Task { go(await ModsGate.outOfDate(token: token) ? .installing : .playing) }
    }

    var body: some View {
        ZStack {
            Backdrop()
            DesignCanvas {
                VStack(spacing: 0) {
                    topBar.frame(height: 46)
                    Spacer(minLength: 4)
                    Group {
                        switch tab {
                        case .home: home
                        case .files: FilesTab(token: token, installed: installed, go: go, startInstall: { startInstall() })
                        case .mods: ModsTab(token: token, startUpdate: { startInstall(update: true) })
                        case .settings: settings
                        case .about: about
                        }
                    }
                    .frame(width: 470)
                    Spacer(minLength: 4)
                    tabBar.frame(width: 470, height: 46)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
            }
        }
        .alert(item: $alert) { a in
            switch a {
            case .lowSpace(let free, let need):
                return Alert(title: Text("Not enough space"),
                             message: Text("The game data needs about \(formatBytes(need)) free and this phone has \(formatBytes(free)). Free some space and try again."),
                             dismissButton: .default(Text("OK")))
            case .cellular:
                return Alert(title: Text("You are on mobile data"),
                             message: Text("The game data is large (about 2.8 GB). Wi-Fi is better."),
                             primaryButton: .default(Text("Download anyway")) { go(.installing) },
                             secondaryButton: .cancel())
            }
        }
        .task {
            while !Task.isCancelled {
                players = await ServerAPI.players(token: token)
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    // ------------------------------------------------------------ top bar --
    private var topBar: some View {
        ZStack {
            HStack {
                BrandMark(size: 21)
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "person").font(.system(size: 17, weight: .medium)).foregroundColor(.white.opacity(0.85))
                        .frame(width: 30, height: 30)
                        .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 1))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(username).font(.system(size: 12, weight: .bold)).foregroundColor(.white).lineLimit(1)
                        HStack(spacing: 3) {
                            Image(systemName: "crown.fill").font(.system(size: 8)).foregroundColor(Theme.orange)
                            Text("Premium").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.orange)
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glassCard(radius: 18)
            }
            Image("Logo").resizable().scaledToFit().frame(height: 40)
        }
    }

    // --------------------------------------------------------------- home --
    private var home: some View {
        VStack(spacing: 7) {
            Text("NEED FOR SPEED UNDERGROUND 2")
                .font(.system(size: 10, weight: .heavy, design: .monospaced)).tracking(3)
                .foregroundColor(.white.opacity(0.6))
            BrandMark(size: 42, showSlashes: false)
                .shadow(color: .black.opacity(0.6), radius: 6)
            HStack(spacing: 8) {
                Text(username).font(.system(size: 14, weight: .semibold)).foregroundColor(.white.opacity(0.7))
                if let p = players {
                    HStack(spacing: 5) {
                        Circle().fill(Color.green).frame(width: 7, height: 7)
                        Text("\(p.inRoam) in free roam").font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.8))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.black.opacity(0.45)).cornerRadius(10)
                }
            }
            HStack(spacing: 8) {
                Chip(icon: "gamecontroller.fill", text: "Mobile Port")
                Chip(icon: "cylinder.split.1x2.fill", text: "Local Game Data")
                Chip(icon: "wifi.slash", text: "Offline Play")
            }
            if dl.active || dl.complete {
                OrangeButton(title: dl.complete ? "FINISH SETUP" : "DOWNLOADING \(dl.totalBytes > 0 ? Int(Double(dl.doneBytes) / Double(dl.totalBytes) * 100) : 0)%",
                             icon: dl.complete ? "checkmark.circle" : "arrow.down.circle") { go(.installing) }
                Text(dl.complete ? "The game data is downloaded. Tap to finish." : "Downloading in the background. You can leave the app.")
                    .font(.system(size: 12)).foregroundColor(.white.opacity(0.65))
            } else if installed {
                OrangeButton(title: "PLAY", icon: "play.fill") { play() }
                Text("Game data is on this phone.").font(.system(size: 12)).foregroundColor(.white.opacity(0.65))
            } else {
                OrangeButton(title: "DOWNLOAD GAME DATA", icon: "arrow.down.to.line") { startInstall() }
                HStack(spacing: 6) {
                    Text("One-time download, then the game runs from this phone.")
                        .font(.system(size: 12)).foregroundColor(.white.opacity(0.65))
                    Text("\u{00B7}").foregroundColor(.white.opacity(0.4))
                    Button("Restore from backup") { go(.restore) }
                        .font(.system(size: 12, weight: .bold)).foregroundColor(Theme.orange)
                }
            }
            stats
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .glassCard()
    }

    private var stats: some View {
        HStack(spacing: 0) {
            stat("cylinder.split.1x2", "~2.8 GB", "Game Data")
            Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 28)
            stat("tag", "v1.2", "North America")
            Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 28)
            stat("checkmark.circle", "iOS Port", "Optimized")
        }
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.35))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.14), lineWidth: 1))
        .cornerRadius(14)
    }

    private func stat(_ icon: String, _ big: String, _ small: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 18)).foregroundColor(.white.opacity(0.8))
            VStack(alignment: .leading, spacing: 1) {
                Text(big).font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                Text(small).font(.system(size: 10)).foregroundColor(.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity)
    }

    // -------------------------------------------------------------- tabs --
    private var settings: some View {
        VStack(spacing: 12) {
            title("SETTINGS")
            row("Signed in as", username)
            row("Free-roam name", username)
            Toggle(isOn: $chatOn) {
                HStack {
                    Image(systemName: "bubble.left.and.bubble.right").foregroundColor(Theme.orange)
                    Text("In-game chat").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                }
            }
            .tint(Theme.orange)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Color.black.opacity(0.35)).cornerRadius(12)
            Button(action: { go(.panel) }) {
                HStack {
                    Image(systemName: "icloud").foregroundColor(Theme.orange)
                    Text("Cloud saves & game settings").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundColor(.white.opacity(0.5))
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color.black.opacity(0.35)).cornerRadius(12)
            }
            .buttonStyle(.plain)
            OutlineButton(title: "LOG OUT", action: onLogout)
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .glassCard()
    }

    private var about: some View {
        VStack(spacing: 10) {
            title("ABOUT")
            BrandMark(size: 30, showSlashes: false)
            Text("Need for Speed Underground 2, running on your phone and online at nfsu2.city.")
                .font(.system(size: 13)).foregroundColor(.white.opacity(0.8)).multilineTextAlignment(.center)
            Text("Fan project. Not affiliated with or endorsed by Electronic Arts.")
                .font(.system(size: 12)).foregroundColor(.white.opacity(0.55)).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .glassCard()
    }

    private func title(_ t: String) -> some View {
        HStack(spacing: 14) {
            Rectangle().fill(Theme.orange).frame(height: 2).frame(maxWidth: 70)
            Text(t).font(.system(size: 13, weight: .heavy, design: .monospaced)).tracking(5).foregroundColor(.white.opacity(0.85))
            Rectangle().fill(Theme.orange).frame(height: 2).frame(maxWidth: 70)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 13)).foregroundColor(.white.opacity(0.6))
            Spacer()
            Text(v).font(.system(size: 13, weight: .bold)).foregroundColor(.white)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Color.black.opacity(0.35)).cornerRadius(12)
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(LauncherTab.allCases, id: \.self) { t in
                Button(action: { tab = t }) {
                    VStack(spacing: 2) {
                        Image(systemName: t == tab ? t.icon + ".fill" : t.icon).font(.system(size: 17))
                        Text(t.title).font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(t == tab ? Theme.orange : .white.opacity(0.85))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(t == tab ? 0.7 : 0.45))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .stroke(t == tab ? Theme.orange : Color.white.opacity(0.14), lineWidth: t == tab ? 2 : 1))
                    .cornerRadius(14)
                    .shadow(color: t == tab ? Theme.orange.opacity(0.5) : .clear, radius: 8)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// ------------------------------------------------------------ small pieces --
private struct SmallButton: View {
    let title: String
    let icon: String
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13, weight: .bold)).foregroundColor(Theme.orange)
                Text(title).font(.system(size: 12, weight: .bold)).foregroundColor(.white)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(Color.black.opacity(0.5))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.2), lineWidth: 1))
            .cornerRadius(12)
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private func sectionTitle(_ t: String) -> some View {
    HStack(spacing: 14) {
        Rectangle().fill(Theme.orange).frame(height: 2).frame(maxWidth: 70)
        Text(t).font(.system(size: 13, weight: .heavy, design: .monospaced)).tracking(5).foregroundColor(.white.opacity(0.85))
        Rectangle().fill(Theme.orange).frame(height: 2).frame(maxWidth: 70)
    }
}

private func infoRow(_ k: String, _ v: String) -> some View {
    HStack {
        Text(k).font(.system(size: 12)).foregroundColor(.white.opacity(0.6))
        Spacer()
        Text(v).font(.system(size: 12, weight: .bold)).foregroundColor(.white).lineLimit(1)
    }
    .padding(.horizontal, 14).padding(.vertical, 8)
    .background(Color.black.opacity(0.35)).cornerRadius(12)
}

// -------------------------------------------------------------- game files --
struct FilesTab: View {
    let token: String
    let installed: Bool
    let go: (Stage) -> Void
    let startInstall: () -> Void
    @StateObject private var bridge: OPFSBridge
    @State private var status = "Checking\u{2026}"
    @State private var busy = false
    @State private var note: String?
    @State private var pickFolder = false
    @State private var confirmWipe = false
    @State private var refresh = 0

    init(token: String, installed: Bool, go: @escaping (Stage) -> Void, startInstall: @escaping () -> Void) {
        self.token = token; self.installed = installed; self.go = go; self.startInstall = startInstall
        _bridge = StateObject(wrappedValue: OPFSBridge(token: token))
    }

    private var backupLine: String {
        guard let name = BackupStore.folderName, BackupStore.hasFolder else { return "Not set up" }
        if let d = BackupStore.lastDate {
            let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
            return "\(name) \u{00B7} \(f.localizedString(for: d, relativeTo: Date()))"
        }
        return "\(name) \u{00B7} no backup yet"
    }

    var body: some View {
        VStack(spacing: 8) {
            sectionTitle("GAME FILES")
            BridgeHost(bridge: bridge).frame(width: 2, height: 2).opacity(0.02)
            infoRow("On this phone", status)
            HStack(spacing: 8) {
                infoRow("Backup folder", backupLine)
                SmallButton(title: BackupStore.hasFolder ? "Change" : "Choose", icon: "folder.badge.plus") { pickFolder = true }
                    .frame(width: 96)
            }
            if let note { Text(note).font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.orange).multilineTextAlignment(.center) }
            if !installed {
                OrangeButton(title: "DOWNLOAD GAME DATA", icon: "arrow.down.to.line", action: startInstall)
            }
            HStack(spacing: 8) {
                SmallButton(title: "Back up now", icon: "externaldrive.badge.plus", enabled: installed && !busy) {
                    go(.backup)
                }
                SmallButton(title: "Restore", icon: "arrow.counterclockwise", enabled: !busy) { go(.restore) }
            }
            HStack(spacing: 8) {
                SmallButton(title: "Repair", icon: "wrench.and.screwdriver", enabled: !busy) { repair() }
                SmallButton(title: "Re-download all", icon: "arrow.down.circle", enabled: !busy) { confirmWipe = true }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .glassCard()
        .task(id: refresh) { await check() }
        .sheet(isPresented: $pickFolder) {
            FolderPicker { url in
                pickFolder = false
                BackupStore.remember(url)
                refresh += 1
            }
        }
        .alert(isPresented: $confirmWipe) {
            Alert(title: Text("Download everything again?"),
                  message: Text("This deletes the game data on this phone (your saves stay) and downloads it fresh."),
                  primaryButton: .destructive(Text("Delete and re-download")) { wipe() },
                  secondaryButton: .cancel())
        }
    }

    private func check() async {
        do {
            try await bridge.prepare()
            let r = try await bridge.verify(deleteOrphans: false)
            if r.complete { status = "Complete" }
            else if r.missing + r.partial + r.bad == 0 { status = "Complete" }
            else { status = "\(r.missing + r.partial + r.bad) files to fetch" }
        } catch { status = "Can't check right now" }
    }

    private func repair() {
        busy = true; note = "Checking every file\u{2026}"
        Task {
            defer { busy = false }
            do {
                try await bridge.prepare()
                let r = try await bridge.verify(deleteOrphans: true)
                if r.complete {
                    note = r.orphans > 0 ? "All good. Freed \(formatBytes(r.freed)) of old files." : "All good. Nothing to repair."
                    status = "Complete"
                } else {
                    note = nil
                    startInstall()          // fetches only what is missing
                }
            } catch { note = "Couldn't check: \(error.localizedDescription)" }
        }
    }

    private func wipe() {
        busy = true; note = "Deleting\u{2026}"
        Task {
            defer { busy = false }
            do {
                try await bridge.prepare()
                try await bridge.clearCache()
                UserDefaults.standard.set(false, forKey: "dataInstalled")
                note = nil
                go(.installing)
            } catch { note = "Couldn't delete: \(error.localizedDescription)" }
        }
    }
}

// -------------------------------------------------------------------- mods --
struct ModsTab: View {
    let token: String
    let startUpdate: () -> Void
    @State private var loaded = false
    @State private var version = ""
    @State private var mods: [ServerAPI.Mod] = []
    @State private var failed = false

    private var updateAvailable: Bool {
        !mods.isEmpty && version != (UserDefaults.standard.string(forKey: "modsVersion") ?? "")
    }

    var body: some View {
        VStack(spacing: 8) {
            sectionTitle("MODS")
            if !loaded {
                ProgressView().tint(.white).padding(.vertical, 30)
            } else if failed {
                Text("Can't reach the server right now.").font(.system(size: 13)).foregroundColor(.white.opacity(0.7))
                    .padding(.vertical, 24)
            } else if mods.isEmpty {
                Image(systemName: "puzzlepiece.extension").font(.system(size: 30)).foregroundColor(Theme.orange)
                Text("No extra packs yet").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                Text("Extra parts and cars are added on the server for every player, so everyone sees the same cars online. They show up here when they arrive.")
                    .font(.system(size: 12)).foregroundColor(.white.opacity(0.6)).multilineTextAlignment(.center)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(mods) { m in
                            HStack {
                                Image(systemName: "checkmark.seal.fill").foregroundColor(Theme.orange)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(m.name).font(.system(size: 13, weight: .bold)).foregroundColor(.white).lineLimit(1)
                                    Text("\(m.files) files \u{00B7} \(m.date)").font(.system(size: 10)).foregroundColor(.white.opacity(0.55))
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Color.black.opacity(0.35)).cornerRadius(12)
                        }
                    }
                }
                .frame(maxHeight: 110)
                if updateAvailable {
                    Text("New game data is on the server.").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.orange)
                    OrangeButton(title: "UPDATE GAME DATA", icon: "arrow.down.to.line", action: startUpdate)
                } else {
                    Text("Up to date.").font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.7))
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .glassCard()
        .task {
            if let r = await ServerAPI.mods(token: token) { version = r.version; mods = r.mods; failed = false }
            else { failed = true }
            loaded = true
        }
    }
}
