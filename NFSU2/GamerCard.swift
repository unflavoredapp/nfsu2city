import SwiftUI
import ImageIO

/// The game's own loading screen as the page: full screenshot (logo, side buttons and all, only the "LOADING"
/// text taken out), shown whole on black like the game is. Content is placed in the image's own space, so the
/// card and the status text land exactly where "LOADING" was on every screen size.
struct LoadingScene<Content: View>: View {
    var anchor = CGPoint(x: 0.5, y: 0.42)       // where the content's centre goes, as a fraction of the picture
    let content: Content
    init(anchor: CGPoint = CGPoint(x: 0.5, y: 0.42), @ViewBuilder _ c: () -> Content) {
        self.anchor = anchor; content = c()
    }

    var body: some View {
        GeometryReader { g in
            let aspect: CGFloat = 2532.0 / 1170.0
            let h = min(g.size.height, g.size.width / aspect)
            let w = h * aspect
            ZStack {
                Color.black
                ZStack {
                    Image("LoadingBG").resizable().frame(width: w, height: h)
                    content.scaleEffect(h / 390).position(x: w * anchor.x, y: h * anchor.y)   // laid out on a 390pt-tall canvas
                }
                .frame(width: w, height: h)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .ignoresSafeArea()
    }
}

// ------------------------------------------------------------------ gamer card --
/// Shown when the app opens with the game ready: the player's card and a Continue button.
/// Nothing of the game is on screen until Continue is tapped (no frozen game frame).
/// Card: picture with country flag, name, level, XP bar. Anything the server doesn't send is left out.
struct GamerCardView: View {
    let username: String
    let token: String
    let onContinue: () -> Void
    @State private var players: PlayerCount?
    @State private var profile: Profile?

    var body: some View {
        LoadingScene {
            VStack(spacing: 10) {
                card
                OrangeButton(title: "CONTINUE", icon: "play.fill", action: onContinue)
                    .frame(width: 300)
            }
        }
        .task { profile = await ServerAPI.profile(token: token) }
        .task {
            while !Task.isCancelled {
                players = await ServerAPI.players(token: token)
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    private var name: String { profile?.name ?? username }

    private var flag: String? {
        guard let c = profile?.country, c.count == 2 else { return nil }
        var s = ""
        for u in c.uppercased().unicodeScalars {
            guard u.value >= 65, u.value <= 90, let f = Unicode.Scalar(127397 + u.value) else { return nil }
            s.unicodeScalars.append(f)
        }
        return s
    }

    private func grouped(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private var card: some View {
        HStack(spacing: 18) {
            RemoteAvatar(source: profile?.avatar, token: token, fallback: String(name.prefix(1)).uppercased(), size: 80)
                .frame(width: 80, height: 80)
                .overlay(alignment: .bottomTrailing) {
                    if let flag {
                        Text(flag).font(.system(size: 20))
                            .padding(4)
                            .background(Circle().fill(Color.black.opacity(0.8)))
                            .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
                            .offset(x: 6, y: 6)
                    }
                }
                .shadow(color: Theme.orange.opacity(0.6), radius: 10)

            VStack(alignment: .leading, spacing: 6) {
                Text("GAMER CARD")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced)).tracking(3)
                    .foregroundColor(Theme.orange)
                HStack(spacing: 10) {
                    Text(name)
                        .font(.system(size: 26, weight: .black, design: .rounded)).italic()
                        .foregroundColor(.white).lineLimit(1).minimumScaleFactor(0.6)
                    if let lv = profile?.level {
                        Text("LVL \(lv)")
                            .font(.system(size: 12, weight: .heavy)).tracking(1)
                            .foregroundColor(.white)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(Theme.orange))
                    }
                }
                if let xp = profile?.xp {
                    VStack(alignment: .leading, spacing: 3) {
                        if let next = profile?.xpNext, next > 0 {
                            OrangeBar(value: Double(xp) / Double(next) * 100)
                            Text("\(grouped(xp)) / \(grouped(next)) XP")
                        } else {
                            Text("\(grouped(xp)) XP")
                        }
                    }
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                }
                HStack(spacing: 6) {
                    Circle().fill(players != nil ? Color.green : Color.gray).frame(width: 7, height: 7)
                    Text(players.map { "\($0.inRoam) in free roam" } ?? "NFSU2.CITY")
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.8))
                    if let c = profile?.country, c.count > 2 {
                        Text("\u{00B7} \(c)").font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.8))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .frame(width: 440)
        .glassCard()
    }
}

/// The player's picture: their GIPHY pick (animated), another image URL, a data: URI, or the first letter of the name.
/// The session token is only ever sent to our own server, never to GIPHY or any other host.
private struct RemoteAvatar: View {
    let source: String?
    let token: String
    let fallback: String
    var size: CGFloat = 88
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.6))
            if let image {
                AnimatedImageView(image: image).frame(width: size, height: size)
            } else {
                Text(fallback)
                    .font(.system(size: 38, weight: .black, design: .rounded)).italic()
                    .foregroundColor(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Theme.orange, lineWidth: 3))
        .task(id: source) { image = await load() }
    }

    /// A bare GIPHY id, a giphy.com/gifs/... or /embed/... page link, or any other URL -> the image URL to fetch.
    private func resolve(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        func media(_ id: String) -> URL? { URL(string: "https://media.giphy.com/media/\(id)/200w.gif") }   // 200px-wide rendition
        if !s.isEmpty, s.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil { return media(s) }
        guard let url = URL(string: s, relativeTo: URL(string: kServer))?.absoluteURL else { return nil }
        if let host = url.host, host.hasSuffix("giphy.com") {
            let parts = url.path.split(separator: "/").map(String.init)
            if parts.count >= 2, parts[0] == "gifs" || parts[0] == "embed",
               let id = parts[1].split(separator: "-").last { return media(String(id)) }
        }
        return url
    }

    private func load() async -> UIImage? {
        guard let s = source else { return nil }
        if s.hasPrefix("data:") {
            guard let comma = s.firstIndex(of: ","),
                  let d = Data(base64Encoded: String(s[s.index(after: comma)...])) else { return nil }
            return GIF.image(from: d)
        }
        guard let url = resolve(s) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        if let host = url.host, host == "nfsu2.city" || host.hasSuffix(".nfsu2.city") {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard let (d, r) = try? await URLSession.shared.data(for: req),
              (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return GIF.image(from: d)
    }
}

/// Animated GIF support: UIImage(data:) only keeps the first frame. Frames are downscaled and capped so a big GIF stays light.
enum GIF {
    static func image(from data: Data, maxPixel: CGFloat = 240, maxFrames: Int = 80) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let n = CGImageSourceGetCount(src)
        if n <= 1 { return UIImage(data: data) }
        let step = max(1, Int((Double(n) / Double(maxFrames)).rounded(.up)))
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        var frames: [UIImage] = []
        var total = 0.0
        var i = 0
        while i < n {
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary) {
                frames.append(UIImage(cgImage: cg))
                var d = 0.1
                if let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
                   let g = p[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                    d = (g[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                        ?? (g[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
                    if d < 0.02 { d = 0.1 }
                }
                total += d * Double(step)
            }
            i += step
        }
        guard !frames.isEmpty else { return UIImage(data: data) }
        return UIImage.animatedImage(with: frames, duration: max(total, 0.1))
    }
}

/// UIImageView so an animated UIImage actually plays.
private struct AnimatedImageView: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        v.image = image
        return v
    }
    func updateUIView(_ v: UIImageView, context: Context) { v.image = image }
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

/// "Starting…" / "Loading…" where the game's own "LOADING" sat, on the same picture as the card screen.
struct GameLoadingView: View {
    @ObservedObject var model: SplashModel
    private let lime = Color(red: 0.78, green: 0.94, blue: 0.36)

    private var title: String {
        if let p = model.progress { return "Loading \(Int((p * 100).rounded()))%" }
        return model.text
    }

    var body: some View {
        // block starts at the left edge of the old "LOADING" text (29% across), vertically on the strip
        LoadingScene(anchor: CGPoint(x: 0.44, y: 0.42)) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    Text(title)
                        .font(.system(size: 22, weight: .bold)).italic()
                        .foregroundColor(lime).lineLimit(1)
                    if let p = model.progress {
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.black.opacity(0.6))
                            Capsule().fill(lime).frame(width: max(8, 110 * CGFloat(p)))
                        }
                        .frame(width: 110, height: 9)
                    } else {
                        ProgressView().tint(lime)
                    }
                }
                if model.progress != nil {
                    Text(model.text).font(.system(size: 10, weight: .semibold)).italic()
                        .foregroundColor(.white.opacity(0.7)).lineLimit(1)
                }
            }
            .frame(width: 260, alignment: .leading)
            .shadow(color: .black.opacity(0.8), radius: 3)
        }
    }
}
