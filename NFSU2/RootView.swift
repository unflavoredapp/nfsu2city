import SwiftUI

private let kTokenKey = "token"
private let kUserKey = "username"

enum Stage { case checking, login, launcher, playing, installing, offer, backup, restore, panel }

struct RootView: View {
    @State private var stage: Stage = .checking
    @State private var token: String = ""
    @State private var username: String = ""
    @State private var installed = UserDefaults.standard.bool(forKey: "dataInstalled")
    @State private var returnTo: Stage = .launcher

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch stage {
            case .checking:
                Backdrop()
                ProgressView().tint(.white)
            case .login:
                Backdrop()
                LoginForm { t, u in signedIn(t, u) }
            case .launcher:
                LauncherView(username: username, token: token, installed: installed,
                             go: { stage = $0 },
                             onLogout: { logOut() })
            case .installing:
                InstallView(token: token, onDone: { installDone() }, onClose: { stage = .launcher })
            case .offer:
                BackupView(token: token, mode: .offer) { _ in stage = .playing }
            case .backup:
                BackupView(token: token, mode: .backup) { _ in stage = returnTo; returnTo = .launcher }
            case .restore:
                BackupView(token: token, mode: .restore) { complete in
                    if complete { markInstalled() }
                    stage = .launcher
                }
            case .playing:
                GameContainer(url: URL(string: kServer)!, token: token, username: username) { stage = .launcher }
                    .ignoresSafeArea()
            case .panel:
                GameContainer(url: URL(string: kServer)!, token: token, username: username, auto: false) { stage = .launcher }
                    .ignoresSafeArea()
            }
        }
        .task { await bootstrap() }
    }

    // ------------------------------------------------------------ session --
    private func bootstrap() async {
        guard let t = Keychain.get(kTokenKey), let u = Keychain.get(kUserKey) else { stage = .login; return }
        token = t; username = u
        switch await AuthAPI.check(token: t) {
        case .some(false): clear(); stage = .login
        default: enter()                    // valid, or offline: straight into the game
        }
    }

    private func signedIn(_ t: String, _ u: String) {
        Keychain.set(t, for: kTokenKey); Keychain.set(u, for: kUserKey)
        token = t; username = u
        enter()
    }

    /// Logged in: with the game data on the phone the game starts at once; on a fresh install the home
    /// screen offers the one-time game data download first.
    private func enter() {
        guard installed else { stage = .launcher; return }
        stage = .checking
        let t = token
        Task {
            // the update gate: new server packs are downloaded first, so everyone plays with the same cars and parts
            stage = await ModsGate.outOfDate(token: t) ? .installing : .playing
        }
    }

    private func markInstalled() {
        installed = true
        UserDefaults.standard.set(true, forKey: "dataInstalled")
    }

    /// The game data is on the phone: remember which server packs it has, then offer (or run) the backup.
    private func installDone() {
        markInstalled()
        let t = token
        Task {
            if let r = await ServerAPI.mods(token: t) { UserDefaults.standard.set(r.version, forKey: "modsVersion") }
        }
        if BackupStore.hasFolder { returnTo = .playing; stage = .backup }
        else if !BackupStore.skipped { stage = .offer }
        else { stage = .playing }
    }

    private func clear() {
        Keychain.delete(kTokenKey); Keychain.delete(kUserKey)
        token = ""; username = ""
    }

    private func logOut() {
        let t = token
        Task { await AuthAPI.logout(token: t) }
        clear()
        stage = .login
    }
}
