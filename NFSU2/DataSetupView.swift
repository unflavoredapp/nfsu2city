import SwiftUI

/// Getting the game data onto the phone: the background download, then moving it into the game's storage, then the
/// page's own check that finishes anything left.  Closing this screen does not stop the download.
struct DataSetupView: View {
    let token: String
    let onDone: () -> Void
    let onClose: () -> Void

    @ObservedObject private var dl = BGDownload.shared
    @StateObject private var job: BackupJob

    enum Phase { case planning, downloading, importing, finishing, failed(String) }
    @State private var phase: Phase = .planning

    init(token: String, onDone: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.token = token; self.onDone = onDone; self.onClose = onClose
        _job = StateObject(wrappedValue: BackupJob(token: token))
    }

    var body: some View {
        Group {
            if case .finishing = phase {
                InstallView(token: token, onDone: onDone, onClose: onClose)
            } else {
                setup
            }
        }
        .task { await begin() }
        .onChange(of: dl.complete) { c in
            if c, case .downloading = phase { startImport() }
        }
        .onChange(of: job.finished) { f in
            if f, case .importing = phase { phase = .finishing }
        }
        .onChange(of: job.failure) { f in
            if let f, case .importing = phase { phase = .failed(f) }
        }
    }

    private func begin() async {
        do {
            try await job.bridge.prepare()
            await dl.resumeIfNeeded(token: token)
            if dl.complete { startImport(); return }
            if dl.active { phase = .downloading; return }
            let entries = try await job.bridge.list()
            let skip = Set(entries.filter { $0.p.hasPrefix("cache/") && !$0.p.hasSuffix(".have") && $0.complete && $0.current }
                .map { String($0.p.dropFirst(6)) })
            let n = try await dl.start(token: token, skip: skip)
            phase = n == 0 ? .finishing : .downloading
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func startImport() {
        phase = .importing
        job.start(.stage)
    }

    private var pct: Double {
        dl.totalBytes > 0 ? min(100, Double(dl.doneBytes) / Double(dl.totalBytes) * 100) : 0
    }

    private var setup: some View {
        ZStack {
            Backdrop()
            BridgeHost(bridge: job.bridge).frame(width: 2, height: 2).opacity(0.02).position(x: 1, y: 1)
            DesignCanvas {
                VStack(spacing: 8) {
                    Image("Logo").resizable().scaledToFit().frame(height: 46)
                    HStack(spacing: 12) {
                        Slashes(height: 20)
                        BrandMark(size: 26, showSlashes: false)
                        Slashes(height: 20)
                    }
                    VStack(spacing: 10) {
                        HStack(spacing: 14) {
                            Rectangle().fill(Theme.orange).frame(height: 2).frame(maxWidth: 80)
                            Text("GAME  DATA").font(.system(size: 13, weight: .heavy)).tracking(5).foregroundColor(.white.opacity(0.85))
                            Rectangle().fill(Theme.orange).frame(height: 2).frame(maxWidth: 80)
                        }
                        content
                    }
                    .padding(.horizontal, 28).padding(.vertical, 16)
                    .frame(width: 480)
                    .glassCard()
                }
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .planning:
            ProgressView().tint(.white).padding(.vertical, 40)
            Text("Preparing\u{2026}").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
        case .downloading:
            big("\(Int(pct))%")
            OrangeBar(value: pct)
            Text("Downloading: \(formatBytes(dl.doneBytes)) of \(formatBytes(dl.totalBytes))")
                .font(.system(size: 13, weight: .bold)).foregroundColor(.white)
            Text("It keeps going in the background. You can close this, lock the phone or leave the app, and you will get a notification when it is done.")
                .font(.system(size: 12)).foregroundColor(.white.opacity(0.55)).multilineTextAlignment(.center).frame(maxWidth: 420)
            if let e = dl.error { Text(e).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.orange) }
            HStack(spacing: 10) {
                OutlineButton(title: "CLOSE", action: onClose)
                Button("Stop download") { dl.cancelAll(); onClose() }
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.6))
            }
        case .importing:
            big(job.finished ? "Done" : "\(Int(job.pct))%")
            OrangeBar(value: job.finished ? 100 : job.pct)
            Text(job.message).font(.system(size: 13, weight: .bold)).foregroundColor(.white).multilineTextAlignment(.center)
            Text("Moving the download into the game. Keep the app open for this part.")
                .font(.system(size: 12)).foregroundColor(.white.opacity(0.55)).multilineTextAlignment(.center)
        case .failed(let m):
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 30)).foregroundColor(Theme.orange)
            Text(m).font(.system(size: 13, weight: .bold)).foregroundColor(.white).multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack(spacing: 10) {
                OutlineButton(title: "TRY AGAIN") { phase = .planning; Task { await begin() } }
                OutlineButton(title: "CLOSE", action: onClose)
            }
        case .finishing:
            EmptyView()
        }
    }

    private func big(_ t: String) -> some View {
        Text(t).font(.system(size: 44, weight: .black, design: .rounded)).italic()
            .foregroundColor(.white).shadow(color: .white.opacity(0.5), radius: 8)
    }
}
