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

    var body: some View {
        ZStack(alignment: .topLeading) {
            GameWebView(url: url, token: token, username: username, auto: auto)

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
    var auto = true

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

        // The app already asked for the username: cover the launcher page with a plain splash, press the
        // page's own Play the moment it is ready, and lift the splash once the game canvas is up.
        let autoJS = #"""
        (function(){
          var t0=Date.now(),tc=0,clicked=false,gone=false;
          function splash(){
            if(gone||document.getElementById('nfsu2-splash')||!document.documentElement)return;
            var o=document.createElement('div');o.id='nfsu2-splash';
            o.style.cssText='position:fixed;left:0;top:0;right:0;bottom:0;z-index:2147483647;background:#000;color:#fff;display:flex;flex-direction:column;align-items:center;justify-content:center;font:italic 800 30px -apple-system,Helvetica,sans-serif;letter-spacing:1px';
            o.innerHTML='<div>NFSU2.CITY</div><div id="nfsu2-sp" style="margin-top:14px;font:500 14px -apple-system,Helvetica,sans-serif;color:#999;letter-spacing:0">Loading\u2026</div>';
            document.documentElement.appendChild(o);
          }
          function lift(){gone=true;clearInterval(iv);var o=document.getElementById('nfsu2-splash');if(o)o.remove();}
          splash();
          var iv=setInterval(function(){
            splash();
            var sp=document.getElementById('nfsu2-sp');
            if(sp&&document.body){var m=(document.body.innerText||'').match(/Loading the game:[^\n]*/);if(m)sp.textContent=m[0];else if(clicked)sp.textContent='Starting\u2026';}
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
        }

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
