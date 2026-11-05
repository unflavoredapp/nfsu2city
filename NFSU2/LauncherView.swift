import SwiftUI

enum LauncherTab: CaseIterable {
    case home, files, settings, about
    var title: String {
        switch self {
        case .home: return "Home"
        case .files: return "Game Files"
        case .settings: return "Settings"
        case .about: return "About"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house"
        case .files: return "folder"
        case .settings: return "gearshape"
        case .about: return "info.circle"
        }
    }
}

struct LauncherView: View {
    let username: String
    let installed: Bool
    let onPlay: () -> Void
    let onInstall: () -> Void
    let onLogout: () -> Void
    @State private var tab = LauncherTab.home

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
                        case .files: files
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
            Text(username).font(.system(size: 14, weight: .semibold)).foregroundColor(.white.opacity(0.7))
            HStack(spacing: 8) {
                Chip(icon: "gamecontroller.fill", text: "Mobile Port")
                Chip(icon: "cylinder.split.1x2.fill", text: "Local Game Data")
                Chip(icon: "wifi.slash", text: "Offline Play")
            }
            if installed {
                OrangeButton(title: "PLAY", icon: "play.fill", action: onPlay)
                Text("Game data is on this phone.").font(.system(size: 12)).foregroundColor(.white.opacity(0.65))
            } else {
                OrangeButton(title: "DOWNLOAD GAME DATA", icon: "arrow.down.to.line", action: onInstall)
                Text("One-time download, then the game runs from this phone.")
                    .font(.system(size: 12)).foregroundColor(.white.opacity(0.65))
            }
            stats
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
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
    private var files: some View {
        VStack(spacing: 12) {
            title("GAME FILES")
            Image(systemName: installed ? "checkmark.seal.fill" : "arrow.down.circle")
                .font(.system(size: 40)).foregroundColor(Theme.orange)
            Text(installed ? "All game data is on this device." : "The game data is not on this device yet.")
                .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
            Text("~2.8 GB · v1.2 North America. Opening this again resumes where it stopped.")
                .font(.system(size: 12)).foregroundColor(.white.opacity(0.6)).multilineTextAlignment(.center)
            OrangeButton(title: installed ? "CHECK GAME DATA" : "DOWNLOAD GAME DATA",
                         icon: "arrow.down.to.line", action: onInstall)
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .glassCard()
    }

    private var settings: some View {
        VStack(spacing: 12) {
            title("SETTINGS")
            row("Signed in as", username)
            row("Server", "nfsu2.city")
            row("Free-roam name", username)
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
