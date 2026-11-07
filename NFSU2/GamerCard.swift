import SwiftUI

/// The NFSU2 loading-screen art (same picture the game shows while it loads), darkened a little so
/// text stays readable on top of it.
struct LoadingBackdrop: View {
    var body: some View {
        GeometryReader { g in
            ZStack {
                Color.black
                Image("LoadingBG").resizable().scaledToFill()
                    .frame(width: g.size.width, height: g.size.height).clipped()
                LinearGradient(colors: [Color.black.opacity(0.35), Color.black.opacity(0.08), Color.black.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
    }
}

// ------------------------------------------------------------------ gamer card --
/// Shown when the app opens with the game ready: the player's card and a Continue button.
/// Nothing of the game is on screen until Continue is tapped (no frozen game frame).
struct GamerCardView: View {
    let username: String
    let token: String
    let onContinue: () -> Void
    @State private var players: PlayerCount?

    var body: some View {
        ZStack {
            LoadingBackdrop()
            DesignCanvas {
                VStack(spacing: 14) {
                    BrandMark(size: 24)
                    card
                    OrangeButton(title: "CONTINUE", icon: "play.fill", action: onContinue)
                        .frame(width: 330)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                players = await ServerAPI.players(token: token)
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    private var card: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.black.opacity(0.6))
                Circle().stroke(Theme.orange, lineWidth: 3)
                Text(String(username.prefix(1)).uppercased())
                    .font(.system(size: 34, weight: .black, design: .rounded)).italic()
                    .foregroundColor(.white)
            }
            .frame(width: 76, height: 76)
            .shadow(color: Theme.orange.opacity(0.6), radius: 10)

            VStack(alignment: .leading, spacing: 5) {
                Text("GAMER CARD")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced)).tracking(3)
                    .foregroundColor(Theme.orange)
                Text(username)
                    .font(.system(size: 26, weight: .black, design: .rounded)).italic()
                    .foregroundColor(.white).lineLimit(1).minimumScaleFactor(0.6)
                HStack(spacing: 6) {
                    Circle().fill(players != nil ? Color.green : Color.gray).frame(width: 7, height: 7)
                    Text(players.map { "\($0.inRoam) in free roam" } ?? "NFSU2.CITY")
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.8))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(width: 400)
        .glassCard()
    }
}

// ------------------------------------------------------------- starting / loading --
/// What the page reports while it loads ("Loading the game: 9.2 MB of 37.4 MB.", then "Starting…").
final class SplashModel: ObservableObject {
    @Published var text = "Loading\u{2026}"
    @Published var progress: Double? = nil      // 0...1 once the page reports megabytes
    @Published var done = false

    func update(_ t: String) {
        text = t
        progress = nil
        guard let re = try? NSRegularExpression(pattern: "([0-9.]+) MB of ([0-9.]+) MB") else { return }
        let ns = t as NSString
        if let m = re.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)),
           let a = Double(ns.substring(with: m.range(at: 1))),
           let b = Double(ns.substring(with: m.range(at: 2))), b > 0 {
            progress = min(max(a / b, 0), 1)
        }
    }

    func finish() { withAnimation(.easeOut(duration: 0.4)) { done = true } }

    func reset() { text = "Loading\u{2026}"; progress = nil; done = false }
}

/// "NFSU2.CITY / Starting…" and "Loading the game…" on the loading-screen art.
struct GameLoadingView: View {
    @ObservedObject var model: SplashModel

    var body: some View {
        ZStack {
            LoadingBackdrop()
            // a dark band across the middle, like the game's own loading strip
            Rectangle().fill(Color.black.opacity(0.6)).frame(height: 150).frame(maxWidth: .infinity)
            VStack(spacing: 12) {
                Text("NFSU2.CITY")
                    .font(.system(size: 30, weight: .heavy)).italic().tracking(1)
                    .foregroundColor(.white)
                Text(model.text)
                    .font(.system(size: 17, weight: .bold)).italic()
                    .foregroundColor(.white.opacity(0.9))
                if let p = model.progress {
                    OrangeBar(value: p * 100).frame(width: 300)
                } else {
                    ProgressView().tint(Theme.orange)
                }
            }
            .shadow(color: .black.opacity(0.7), radius: 4)
        }
    }
}
