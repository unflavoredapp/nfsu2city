import SwiftUI

private let kTokenKey = "token"
private let kUserKey = "username"

enum Stage { case checking, login, launcher, playing, installing }

struct RootView: View {
    @State private var stage: Stage = .checking
    @State private var token: String = ""
    @State private var username: String = ""
    @State private var installed = UserDefaults.standard.bool(forKey: "dataInstalled")

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
                LauncherView(username: username, installed: installed,
                             onPlay: { stage = .playing },
                             onInstall: { stage = .installing },
                             onLogout: { logOut() })
            case .installing:
                InstallView(token: token,
                            onDone: { installed = true; UserDefaults.standard.set(true, forKey: "dataInstalled"); stage = .playing },
                            onClose: { stage = .launcher })
            case .playing:
                GameContainer(url: URL(string: kServer)!, token: token, username: username) { stage = .launcher }
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
    private func enter() { stage = installed ? .playing : .launcher }

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
