import SwiftUI

/// One screen for the three backup moments: the offer after the game data came down, a backup, and a restore.
struct BackupView: View {
    enum Mode { case offer, backup, restore }

    let mode: Mode
    let onClose: (_ dataComplete: Bool) -> Void
    @StateObject private var job: BackupJob
    @State private var picking = false
    @State private var pickedFor: BackupJob.Kind = .backup
    @State private var started = false

    init(token: String, mode: Mode, onClose: @escaping (Bool) -> Void) {
        self.mode = mode
        self.onClose = onClose
        _job = StateObject(wrappedValue: BackupJob(token: token))
    }

    var body: some View {
        ZStack {
            Backdrop()
            BridgeHost(bridge: job.bridge)
                .frame(width: 2, height: 2).opacity(0.02).position(x: 1, y: 1)

            DesignCanvas {
                VStack(spacing: 8) {
                    Image("Logo").resizable().scaledToFit().frame(height: 46)
                    HStack(spacing: 12) {
                        Slashes(height: 20)
                        BrandMark(size: 26, showSlashes: false)
                        Slashes(height: 20)
                    }
                    card
                        .padding(.horizontal, 28).padding(.vertical, 16)
                        .frame(width: 480)
                        .glassCard()
                }
            }
        }
        .sheet(isPresented: $picking) {
            FolderPicker { url in
                picking = false
                BackupStore.remember(url)
                job.start(pickedFor)
                started = true
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            guard !started else { return }
            switch mode {
            case .offer: break
            case .backup: begin(.backup)
            case .restore: begin(.restore)
            }
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func begin(_ kind: BackupJob.Kind) {
        pickedFor = kind
        if BackupStore.hasFolder { started = true; job.start(kind) } else { picking = true }
    }

    private var heading: some View {
        HStack(spacing: 14) {
            Rectangle().fill(Theme.orange).frame(height: 2).frame(maxWidth: 80)
            Text(mode == .restore ? "RESTORE" : "BACKUP").font(.system(size: 13, weight: .heavy)).tracking(5)
                .foregroundColor(.white.opacity(0.85))
            Rectangle().fill(Theme.orange).frame(height: 2).frame(maxWidth: 80)
        }
    }

    @ViewBuilder private var card: some View {
        if mode == .offer && !started && !job.running && !job.finished {
            VStack(spacing: 10) {
                heading
                Image(systemName: "externaldrive.badge.checkmark").font(.system(size: 34)).foregroundColor(Theme.orange)
                Text("Keep a copy that survives deleting the app")
                    .font(.system(size: 15, weight: .bold)).foregroundColor(.white).multilineTextAlignment(.center)
                Text("Pick a folder in Files (for example On My iPhone). The game data and your saves are copied there, and after a reinstall they come back from it with no new download.")
                    .font(.system(size: 12)).foregroundColor(.white.opacity(0.6)).multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                OrangeButton(title: "CHOOSE FOLDER", icon: "folder.badge.plus") { begin(.backup) }
                Button("Not now") { BackupStore.skipped = true; onClose(true) }
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(.white.opacity(0.7))
            }
        } else if let f = job.failure, !job.running {
            VStack(spacing: 10) {
                heading
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 30)).foregroundColor(Theme.orange)
                Text(f).font(.system(size: 13, weight: .bold)).foregroundColor(.white).multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                HStack(spacing: 10) {
                    OutlineButton(title: "TRY AGAIN") { job.start(pickedFor) }
                    OutlineButton(title: "CLOSE") { onClose(job.dataComplete) }
                }
            }
        } else {
            VStack(spacing: 10) {
                heading
                Text(job.finished ? "Done" : "\(Int(job.pct))%")
                    .font(.system(size: 44, weight: .black, design: .rounded)).italic()
                    .foregroundColor(.white).shadow(color: .white.opacity(0.5), radius: 8)
                OrangeBar(value: job.finished ? 100 : job.pct)
                Text(job.message).font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
                Text(job.finished ? "Everything is in the folder you chose." : "Keep the app open. If it stops, start it again: it carries on.")
                    .font(.system(size: 12)).foregroundColor(.white.opacity(0.5)).multilineTextAlignment(.center)
                if job.finished {
                    OutlineButton(title: "DONE") { onClose(job.dataComplete) }
                } else {
                    OutlineButton(title: "STOP") { job.cancel() }
                }
            }
        }
    }
}
