import SwiftUI

enum Theme {
    static let orange = Color(red: 1.0, green: 0.42, blue: 0.0)
    static let orangeLight = Color(red: 1.0, green: 0.56, blue: 0.16)
}

/// Full-bleed cover art with a darkening gradient.
struct Backdrop: View {
    var body: some View {
        GeometryReader { g in
            ZStack {
                Color.black
                Image("Cover").resizable().scaledToFill()
                    .frame(width: g.size.width, height: g.size.height).clipped()
                LinearGradient(colors: [Color.black.opacity(0.15), Color.black.opacity(0.5)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
    }
}

/// The screens are laid out on an 844x390 canvas and scaled to whatever device they run on.
struct DesignCanvas<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ c: () -> Content) { content = c() }
    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width / 844, g.size.height / 390)
            content
                .frame(width: 844, height: 390)
                .scaleEffect(s)
                .frame(width: g.size.width, height: g.size.height)
        }
    }
}

struct Parallelogram: Shape {
    func path(in r: CGRect) -> Path {
        let s = r.width * 0.55
        var p = Path()
        p.move(to: CGPoint(x: s, y: 0))
        p.addLine(to: CGPoint(x: r.width, y: 0))
        p.addLine(to: CGPoint(x: r.width - s, y: r.height))
        p.addLine(to: CGPoint(x: 0, y: r.height))
        p.closeSubpath()
        return p
    }
}

struct Slashes: View {
    var height: CGFloat = 22
    var body: some View {
        HStack(spacing: 3) {
            Parallelogram().fill(Theme.orange).frame(width: height * 0.42, height: height)
            Parallelogram().fill(Theme.orange).frame(width: height * 0.42, height: height)
        }
        .shadow(color: Theme.orange.opacity(0.7), radius: 6)
    }
}

/// "// NFSU2.CITY"
struct BrandMark: View {
    var size: CGFloat = 22
    var showSlashes = true
    var body: some View {
        HStack(spacing: 8) {
            if showSlashes { Slashes(height: size) }
            (Text("NFSU2").foregroundColor(.white) + Text(".CITY").foregroundColor(Theme.orange))
                .font(.system(size: size, weight: .black, design: .rounded))
                .italic()
        }
    }
}

struct GlassCard: ViewModifier {
    var radius: CGFloat = 26
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: radius).fill(Color.black.opacity(0.5)))
            )
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Color.white.opacity(0.16), lineWidth: 1))
    }
}

extension View {
    func glassCard(radius: CGFloat = 26) -> some View { modifier(GlassCard(radius: radius)) }
}

struct OrangeButton: View {
    let title: String
    var icon: String? = nil
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let icon { Image(systemName: icon).font(.system(size: 19, weight: .bold)) }
                Text(title).font(.system(size: 17, weight: .heavy)).tracking(2.5)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(colors: [Theme.orangeLight, Theme.orange], startPoint: .top, endPoint: .bottom))
            )
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.35), lineWidth: 1))
            .shadow(color: Theme.orange.opacity(0.55), radius: 12)
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Dark button with an orange outline and slashes either side (CLOSE, LOG OUT...).
struct OutlineButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Slashes(height: 18)
                Text(title).font(.system(size: 15, weight: .heavy)).tracking(3).foregroundColor(.white)
                    .padding(.horizontal, 28).padding(.vertical, 11)
                    .background(Color.black.opacity(0.7))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.orange, lineWidth: 2))
                    .cornerRadius(16)
                    .shadow(color: Theme.orange.opacity(0.6), radius: 10)
                Slashes(height: 18)
            }
        }
        .buttonStyle(.plain)
    }
}

struct Chip: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundColor(Theme.orange)
            Text(text).font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.black.opacity(0.55))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.2), lineWidth: 1))
        .cornerRadius(12)
    }
}

struct OrangeBar: View {
    let value: Double          // 0...100
    var body: some View {
        GeometryReader { g in
            let f = CGFloat(min(max(value, 0), 100) / 100)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.75))
                Capsule().stroke(Theme.orange.opacity(0.85), lineWidth: 1.5)
                Capsule()
                    .fill(LinearGradient(colors: [Theme.orangeLight, Theme.orange], startPoint: .top, endPoint: .bottom))
                    .frame(width: max(14, g.size.width * f))
            }
        }
        .frame(height: 14)
        .shadow(color: Theme.orange.opacity(0.55), radius: 8)
    }
}
