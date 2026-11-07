import SwiftUI

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
