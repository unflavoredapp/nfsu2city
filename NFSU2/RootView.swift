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
                backdrop
                ProgressView().tint(.white)
            case .login:
                backdrop
                LoginForm { t, u in signedIn(t, u) }
            case .launcher:
                backdrop
                launcher
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

    /// Logged in: the game starts at once; on a fresh install the game data comes first, then the game.
    private func enter() { stage = installed ? .playing : .installing }

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

    // ----------------------------------------------------------- launcher --
    /// Cover art you supply: drop cover.jpg (or cover.png) into NFSU2/ and rebuild.
    private static let cover: UIImage? = {
        for ext in ["jpg", "jpeg", "png"] {
            if let p = Bundle.main.path(forResource: "cover", ofType: ext),
               let img = UIImage(contentsOfFile: p) { return img }
        }
        return nil
    }()

    private var backdrop: some View {
        ZStack {
            if let cover = Self.cover {
                Image(uiImage: cover).resizable().scaledToFill().ignoresSafeArea()
                LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .center, endPoint: .bottom)
                    .ignoresSafeArea()
            }
        }
    }

    private var launcher: some View {
        VStack(spacing: 14) {
            if Self.cover == nil {
                Text("NEED FOR SPEED UNDERGROUND 2")
                    .font(.system(size: 12, weight: .heavy, design: .monospaced))
                    .tracking(3).foregroundColor(.gray)
                Text("NFSU2.CITY")
                    .font(.system(size: 36, weight: .black, design: .rounded))
                    .italic()
                    .foregroundColor(.white)
            } else {
                Spacer()
            }
            Text(username)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            if installed {
                Button(action: { stage = .playing }) {
                    Text("PLAY").font(.system(size: 17, weight: .heavy)).tracking(2)
                        .padding(.horizontal, 64).padding(.vertical, 12)
                        .background(Color(red: 0.0, green: 0.55, blue: 1.0))
                        .cornerRadius(10).foregroundColor(.white)
                }
                Button("Check game data") { stage = .installing }
                    .font(.system(size: 14, weight: .semibold)).foregroundColor(.white.opacity(0.85))
            } else {
                // First launch: the game data comes onto the phone first, so play never waits on the network.
                Button(action: { stage = .installing }) {
                    Text("DOWNLOAD GAME DATA").font(.system(size: 16, weight: .heavy)).tracking(1.5)
                        .padding(.horizontal, 40).padding(.vertical, 12)
                        .background(Color(red: 0.0, green: 0.55, blue: 1.0))
                        .cornerRadius(10).foregroundColor(.white)
                }
                Text("One-time download, then the game runs from this phone.")
                    .font(.system(size: 12)).foregroundColor(.white.opacity(0.6))
            }
            Button("Log out", action: logOut)
                .font(.system(size: 13)).foregroundColor(.white.opacity(0.6))
        }
        .padding(24)
    }
}

// ---------------------------------------------------------------- login --
struct LoginForm: View {
    let onDone: (String, String) -> Void

    @State private var registering = false
    @State private var username = ""
    @State private var password = ""
    @State private var invite = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Picker("", selection: $registering) {
                    Text("Log in").tag(false)
                    Text("Register").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                field("Username", text: $username, secure: false)
                    .onChange(of: username) { v in
                        let c = String(v.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }.prefix(15))
                        if c != v { username = c }
                    }
                field("Password", text: $password, secure: true)
                if registering { field("Invite code", text: $invite, secure: false, caps: true) }

                if let error { Text(error).font(.footnote).foregroundColor(.red) }

                Button(action: submit) {
                    Group {
                        if busy { ProgressView().tint(.white) }
                        else { Text(registering ? "CREATE ACCOUNT" : "LOG IN").font(.system(size: 16, weight: .heavy)).tracking(1.5) }
                    }
                    .frame(maxWidth: 320).padding(.vertical, 12)
                    .background(Color(red: 0.0, green: 0.55, blue: 1.0).opacity(ready ? 1 : 0.4))
                    .cornerRadius(10).foregroundColor(.white)
                }
                .disabled(!ready || busy)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private var ready: Bool {
        username.count >= 3 && password.count >= (registering ? 8 : 1) && (!registering || invite.count >= 5)
    }

    @ViewBuilder
    private func field(_ title: String, text: Binding<String>, secure: Bool, caps: Bool = false) -> some View {
        Group {
            if secure { SecureField(title, text: text) }
            else { TextField(title, text: text) }
        }
        .textInputAutocapitalization(caps ? .characters : .never)
        .autocorrectionDisabled()
        .multilineTextAlignment(.center)
        .padding(12)
        .frame(maxWidth: 320)
        .background(Color.white.opacity(0.14))
        .cornerRadius(10)
        .foregroundColor(.white)
    }

    private func submit() {
        busy = true; error = nil
        Task {
            do {
                let r = registering
                    ? try await AuthAPI.register(username: username, password: password, invite: invite)
                    : try await AuthAPI.login(username: username, password: password)
                busy = false
                onDone(r.token, r.username)
            } catch {
                busy = false
                self.error = error.localizedDescription
            }
        }
    }
}
