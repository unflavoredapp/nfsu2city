import SwiftUI
import WebKit

/// Full-screen game with a small auto-hiding exit button.
struct GameContainer: View {
    let url: URL
    let token: String
    let username: String
    var auto = true                 // false: the page's own start screen (cloud saves, settings), no auto-play
    let onExit: () -> Void
    @State private var showExit = false
    @State private var revealCount = 0
    @AppStorage("chatOn") private var chatOn = true
    @AppStorage("voiceOn") private var voiceOn = true
    @StateObject private var splash = SplashModel()

    var body: some View {
        ZStack(alignment: .topLeading) {
            GameWebView(url: url, token: token, username: username, auto: auto, splash: auto ? splash : nil)

            // Starting / loading screen on the loading-screen art, over the page until the game canvas is up.
            if auto && !splash.done {
                GameLoadingView(model: splash).transition(.opacity)
            }

            if auto && chatOn { ChatOverlay(token: token, username: username) }
            if auto && voiceOn { VoiceOverlay() }

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
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            if auto && voiceOn { VoiceModel.configureAudio() }
        }
        .task {
            // safety net: never leave the loading screen up for good if the page never reports back
            try? await Task.sleep(nanoseconds: 100_000_000_000)
            splash.finish()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            VoiceModel.shared.reset()
        }
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
    var auto = true
    var splash: SplashModel? = nil      // the native starting/loading screen the page reports to

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

        // The app already asked for the username: the app's own starting/loading screen (SwiftUI, on the
        // loading-screen art) covers the page. This script reports the page's progress to it, presses the
        // page's own Play the moment it is ready, and tells the app to lift the screen once the game canvas is up.
        let autoJS = #"""
        (function(){
          var t0=Date.now(),tc=0,clicked=false,last='';
          function post(t,d){try{window.webkit.messageHandlers.splash.postMessage({t:t,d:!!d})}catch(e){}}
          function lift(){clearInterval(iv);post('',true);}
          post('Loading\u2026',false);
          var iv=setInterval(function(){
            if(document.body){
              var m=(document.body.innerText||'').match(/Loading the game:[^\n]*/);
              var t=m?m[0]:(clicked?'Starting\u2026':'Loading\u2026');
              if(t!==last){last=t;post(t,false);}
            }
            if(!clicked){
              var b=document.getElementById('play');
              if(b&&!b.disabled){clicked=true;tc=Date.now();b.click();}
              else if(Date.now()-t0>90000){lift();}
            }else{
              var c=document.querySelector('canvas'),age=Date.now()-tc;
              if((c&&c.offsetWidth>0&&age>1500)||age>12000)lift();
            }
          },250);
        })();
        """#
        if self.auto {
            cfg.userContentController.addUserScript(
                WKUserScript(source: autoJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            if let splash { cfg.userContentController.add(SplashHandler(splash), name: "splash") }
        }

        // Proximity voice: the page-side script, and the channel it reports who is talking on.
        if auto && VoiceModel.enabled {
            let boot = "window.NFSU2_VOICE={mode:\(jsString(VoiceModel.mode)),flip:\(VoiceModel.flip ? "true" : "false")};"
            cfg.userContentController.addUserScript(
                WKUserScript(source: boot + VoiceScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            cfg.userContentController.add(VoiceHandler(), name: "voice")
        }

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        if auto && VoiceModel.enabled { Task { @MainActor in VoiceModel.shared.webView = wv } }
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
        context.coordinator.splash = splash

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

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let url: URL
        weak var webView: WKWebView?
        weak var splash: SplashModel?
        private var retries = 0

        init(url: URL) { self.url = url }

        // The page's microphone (proximity voice): granted for our own site only.
        @available(iOS 15.0, *)
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            let ok = type == .microphone && (origin.host == "nfsu2.city" || origin.host.hasSuffix(".nfsu2.city"))
            decisionHandler(ok ? .grant : .deny)
        }

        // iOS killed the web content process (memory): bring the page straight back.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            splash?.reset()                 // the loading screen covers the reload, like at first start
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

/// Receives the page's loading progress / "game is up" message for the native loading screen.
final class SplashHandler: NSObject, WKScriptMessageHandler {
    private weak var model: SplashModel?
    init(_ model: SplashModel) { self.model = model }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let d = message.body as? [String: Any] else { return }
        if (d["d"] as? Bool) == true { model?.finish() }
        else if let t = d["t"] as? String { model?.update(t) }
    }
}
