import SwiftUI
import WebKit

/// Full-screen game with a small auto-hiding exit button.
struct GameContainer: View {
    let url: URL
    let token: String
    let username: String
    let onExit: () -> Void
    @State private var showExit = false
    @State private var revealCount = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            GameWebView(url: url, token: token, username: username)

            // Tap the top-left corner to reveal the exit button.
            Color.clear
                .frame(width: 56, height: 56)
                .contentShape(Rectangle())
                .onTapGesture { reveal() }

            if showExit {
                Button(action: onExit) {
                    Text("✕ Exit").font(.system(size: 14, weight: .bold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.black.opacity(0.7))
                        .foregroundColor(.white).cornerRadius(8)
                }
                .padding(.leading, 20).padding(.top, 12)
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func reveal() {
        showExit = true
        revealCount += 1
        let t = revealCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if t == revealCount { showExit = false }
        }
    }
}

struct GameWebView: UIViewRepresentable {
    let url: URL
    let token: String
    let username: String

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()               // persistent storage (OPFS saves, cloud-save passphrase)
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.isElementFullscreenEnabled = true
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        cfg.limitsNavigationsToAppBoundDomains = true    // lets the page's service worker (offline start) run

        // Expose the username to the page before any script runs.
        let js = "window.NFSU2_USERNAME=\(jsString(username));try{localStorage.setItem('nfsu2_username',window.NFSU2_USERNAME)}catch(e){}"
        cfg.userContentController.addUserScript(
            WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        // The app already asked for the username: press the page's own Play for the player once it is ready.
        let auto = "(function(){var n=0,t=setInterval(function(){var b=document.getElementById('play');if(b&&!b.disabled){clearInterval(t);b.click()}else if(++n>240){clearInterval(t)}},250)})();"
        cfg.userContentController.addUserScript(
            WKUserScript(source: auto, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = false
        wv.isOpaque = false
        wv.backgroundColor = .black
        wv.underPageBackgroundColor = .black
        wv.scrollView.backgroundColor = .black
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.bounces = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.scrollView.pinchGestureRecognizer?.isEnabled = false
        if #available(iOS 16.4, *) { wv.isInspectable = true }

        context.coordinator.webView = wv

        // The login's session goes in as the cookie the gate checks, then the game loads.
        installSessionCookie(on: cfg.websiteDataStore.httpCookieStore, token: token) {
            _ = wv.load(URLRequest(url: self.url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    private func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let arr = String(data: data ?? Data("[\"\"]".utf8), encoding: .utf8) ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let url: URL
        weak var webView: WKWebView?
        private var retries = 0

        init(url: URL) { self.url = url }

        // iOS killed the web content process (memory): bring the page straight back.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.load(URLRequest(url: url))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { retries = 0 }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            retry()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            retry()
        }

        private func retry() {
            guard retries < 5 else { return }
            retries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, let wv = self.webView else { return }
                wv.load(URLRequest(url: self.url))
            }
        }
    }
}
