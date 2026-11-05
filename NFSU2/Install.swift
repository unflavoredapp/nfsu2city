import SwiftUI
import WebKit

struct InstallStatus {
    var info = "Connecting…"
    var pct = 0.0
    var running = false
    var done = false
}

/// Downloads all the game data onto the device through the page's own resumable preload
/// (the "Preload the game data" button), with a native progress screen. Closing it keeps what's done;
/// opening it again continues from there.
struct InstallView: View {
    let token: String
    let onDone: () -> Void          // all the game data is on the device
    let onClose: () -> Void
    @State private var st = InstallStatus()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // The page has to stay in the view tree for its download worker to keep running.
            InstallWebView(token: token) { st = $0 }
                .frame(width: 2, height: 2).opacity(0.02)
                .position(x: 1, y: 1)

            VStack(spacing: 14) {
                Text("GAME DATA")
                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
                    .tracking(4).foregroundColor(.gray)
                Text(st.done ? "Installed" : (st.running ? "\(Int(st.pct))%" : "Preparing…"))
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                ProgressView(value: st.done ? 100 : st.pct, total: 100)
                    .tint(Color(red: 0.0, green: 0.55, blue: 1.0))
                    .frame(maxWidth: 380)
                Text(st.info)
                    .font(.system(size: 13)).foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
                Text(st.done ? "Everything is on this device." : "Keep the app open. If it stops, open this again: it continues where it left off.")
                    .font(.system(size: 12)).foregroundColor(.white.opacity(0.45))
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
                Button(action: onClose) {
                    Text(st.done ? "DONE" : "CLOSE").font(.system(size: 15, weight: .heavy)).tracking(2)
                        .padding(.horizontal, 40).padding(.vertical, 10)
                        .background(Color.white.opacity(0.14)).cornerRadius(10).foregroundColor(.white)
                }
            }
            .padding(24)
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: st.done) { d in if d { onDone() } }
    }
}

struct InstallWebView: UIViewRepresentable {
    let token: String
    let onStatus: (InstallStatus) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onStatus: onStatus) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()               // the same storage the game reads its cache from
        cfg.limitsNavigationsToAppBoundDomains = true
        let wv = WKWebView(frame: .zero, configuration: cfg)
        context.coordinator.webView = wv
        installSessionCookie(on: cfg.websiteDataStore.httpCookieStore, token: token) {
            _ = wv.load(URLRequest(url: URL(string: kServer)!))
            context.coordinator.start()
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        let onStatus: (InstallStatus) -> Void
        weak var webView: WKWebView?
        private var timer: Timer?

        init(onStatus: @escaping (InstallStatus) -> Void) { self.onStatus = onStatus }

        // Reads the page's preload panel once a second; starts the preload (once) when it offers it.
        private static let js = """
        (function(){
          var b=document.getElementById('fetch-all'), i=document.getElementById('cache-info'), bar=document.getElementById('data-bar');
          if(!b||!i) return null;
          var txt=(b.textContent||'').trim(), running=!!(bar&&!bar.hidden);
          var pct=bar?parseFloat(bar.getAttribute('aria-valuenow')||'0'):0;
          if(!b.hidden&&!b.disabled&&!window.__nfsu2Started&&/^Preload/.test(txt)){window.__nfsu2Started=true;b.click();}
          var info=(i.textContent||'').trim();
          return {info:info,pct:pct,running:running,done:/^All game data/.test(info)&&!running};
        })()
        """

        func start() {
            DispatchQueue.main.async {
                self.timer?.invalidate()
                self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
            }
        }

        func stop() { timer?.invalidate(); timer = nil }

        private func poll() {
            webView?.evaluateJavaScript(Self.js) { [weak self] result, _ in
                guard let self, let d = result as? [String: Any] else { return }
                var s = InstallStatus()
                s.info = (d["info"] as? String) ?? ""
                s.pct = (d["pct"] as? Double) ?? 0
                s.running = (d["running"] as? Bool) ?? false
                s.done = (d["done"] as? Bool) ?? false
                self.onStatus(s)
            }
        }
    }
}
