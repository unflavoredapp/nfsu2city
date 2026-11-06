import SwiftUI
import WebKit
import AVFoundation
import UIKit

/// Proximity voice, native half: the push-to-talk button, who is talking, and the bridge to the page's voice.js
/// (which does the WebRTC and the 3D audio).
@MainActor
final class VoiceModel: ObservableObject {
    static let shared = VoiceModel()
    @Published var speaking: [String] = []
    @Published var selfTalking = false
    @Published var peers = 0
    @Published var status = ""
    @Published var muted = false
    weak var webView: WKWebView?

    private func js(_ s: String) { webView?.evaluateJavaScript(s, completionHandler: nil) }

    func ptt(_ down: Bool) { js("window.__voice&&window.__voice.ptt(\(down ? "true" : "false"))") }

    func toggleMute() {
        muted.toggle()
        js("window.__voice&&window.__voice.setMuted(\(muted ? "true" : "false"))")
    }

    func update(_ d: [String: Any]) {
        speaking = (d["speaking"] as? [String]) ?? []
        selfTalking = (d["self"] as? Bool) ?? false
        peers = (d["peers"] as? Int) ?? 0
        status = (d["status"] as? String) ?? ""
        muted = (d["muted"] as? Bool) ?? muted
    }

    func reset() {
        webView = nil; speaking = []; selfTalking = false; peers = 0; status = ""; muted = false
    }

    /// Speaker output with the microphone open (so the game's sound does not drop to the earpiece), mixing with other audio.
    static func configureAudio() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
        try? s.setActive(true)
    }

    static var enabled: Bool { (UserDefaults.standard.object(forKey: "voiceOn") as? Bool) ?? true }
    static var mode: String { UserDefaults.standard.string(forKey: "voiceMode") ?? "ptt" }
    static var flip: Bool { UserDefaults.standard.bool(forKey: "voiceFlip") }
}

/// Receives the page's `webkit.messageHandlers.voice.postMessage(...)`.
final class VoiceHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let d = m.body as? [String: Any] else { return }
        Task { @MainActor in VoiceModel.shared.update(d) }
    }
}

/// The in-game voice controls: PUSH (hold) or MUTE (tap, open-mic mode) on the left edge, and who is talking under the chat bubble.
struct VoiceOverlay: View {
    @ObservedObject private var v = VoiceModel.shared
    @AppStorage("voiceMode") private var mode = "ptt"
    @State private var held = false

    var body: some View {
        ZStack {
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(v.speaking.prefix(5), id: \.self) { n in
                    HStack(spacing: 6) {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Text(n).font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Color.black.opacity(0.6)).cornerRadius(10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 56).padding(.trailing, 52)
            .allowsHitTesting(false)

            VStack(spacing: 4) {
                ZStack {
                    Circle().fill(held || v.selfTalking ? Theme.orange : Color.black.opacity(0.6))
                        .frame(width: 58, height: 58)
                        .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1.5))
                    Image(systemName: mode == "ptt" ? "mic.fill" : (v.muted ? "mic.slash.fill" : "mic.fill"))
                        .font(.system(size: 22, weight: .bold)).foregroundColor(.white)
                }
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard mode == "ptt", !held else { return }
                            held = true
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            v.ptt(true)
                        }
                        .onEnded { _ in
                            if mode == "ptt" { held = false; v.ptt(false) }
                            else { v.toggleMute(); UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                        }
                )
                Text(v.status).font(.system(size: 10, weight: .semibold)).foregroundColor(.white.opacity(0.85))
                    .shadow(color: .black, radius: 2).allowsHitTesting(false)
                if v.peers > 0 {
                    Text("\(v.peers) nearby").font(.system(size: 9, weight: .medium)).foregroundColor(.white.opacity(0.6))
                        .shadow(color: .black, radius: 2).allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, 64)
        }
    }
}
