import SwiftUI

struct ChatMsg: Identifiable, Decodable, Equatable {
    let id: Int
    let u: String
    let m: String
}

/// The server's global chat: a long poll for new messages, and a POST to send.
@MainActor
final class ChatModel: ObservableObject {
    @Published var msgs: [ChatMsg] = []
    @Published var unread = 0
    @Published var toast: ChatMsg?
    @Published var error: String?
    var panelOpen = false { didSet { if panelOpen { unread = 0; toast = nil } } }

    private let token: String
    private let me: String
    private var task: Task<Void, Never>?
    private var after = 0
    private var first = true
    private var toastTick = 0

    init(token: String, me: String) { self.token = token; self.me = me }

    func start() {
        guard task == nil else { return }
        task = Task { await loop() }
    }

    func stop() { task?.cancel(); task = nil }

    private func request(_ path: String, body: Data? = nil, timeout: TimeInterval) -> URLRequest {
        var r = URLRequest(url: URL(string: kServer + path)!, timeoutInterval: timeout)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            r.httpMethod = "POST"
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private struct Poll: Decodable { let msgs: [ChatMsg]; let last: Int }

    private func loop() async {
        while !Task.isCancelled {
            do {
                let (d, r) = try await URLSession.shared.data(for: request("app/chat?after=\(after)", timeout: 40))
                guard (r as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let j = try JSONDecoder().decode(Poll.self, from: d)
                if j.last < after { after = 0; msgs.removeAll(); first = true; continue }     // the server restarted
                for m in j.msgs { add(m) }
                if let l = j.msgs.last { after = l.id } else { after = max(after, j.last) }
                first = false
                error = nil
            } catch {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func add(_ m: ChatMsg) {
        if msgs.contains(where: { $0.id == m.id }) { return }
        msgs.append(m)
        if msgs.count > 100 { msgs.removeFirst(msgs.count - 100) }
        guard !first, m.u != me, !panelOpen else { return }
        unread += 1
        toast = m
        toastTick += 1
        let t = toastTick
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.toastTick == t { self?.toast = nil }
        }
    }

    func send(_ text: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let body = try? JSONSerialization.data(withJSONObject: ["m": t]) else { return }
        do {
            let (d, r) = try await URLSession.shared.data(for: request("app/chat/send", body: body, timeout: 10))
            if (r as? HTTPURLResponse)?.statusCode != 200 {
                error = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["error"] as? String ?? "Couldn't send"
            } else { error = nil }
        } catch { self.error = "Couldn't send" }
    }
}

/// A small chat button over the game; it opens a compact panel at the top right (clear of the keyboard).
struct ChatOverlay: View {
    let username: String
    @StateObject private var chat: ChatModel
    @State private var open = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    init(token: String, username: String) {
        self.username = username
        _chat = StateObject(wrappedValue: ChatModel(token: token, me: username))
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if open {
                panel
            } else {
                button
                if let t = chat.toast {
                    (Text(t.u).bold().foregroundColor(Theme.orange) + Text("  " + t.m).foregroundColor(.white))
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: 240, alignment: .leading)
                        .background(Color.black.opacity(0.7)).cornerRadius(10)
                        .transition(.opacity)
                }
            }
        }
        .padding(.top, 10).padding(.trailing, 52)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .animation(.easeOut(duration: 0.15), value: open)
        .onAppear { chat.start() }
        .onDisappear { chat.stop() }
        .onChange(of: open) { chat.panelOpen = $0 }
    }

    private var button: some View {
        Button { open = true } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.black.opacity(0.55)).clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                if chat.unread > 0 {
                    Text("\(min(chat.unread, 99))").font(.system(size: 10, weight: .heavy)).foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Theme.orange).clipShape(Capsule()).offset(x: 6, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var panel: some View {
        VStack(spacing: 6) {
            HStack {
                Text("CHAT").font(.system(size: 11, weight: .heavy)).tracking(3).foregroundColor(.white.opacity(0.8))
                Spacer()
                Button { focused = false; open = false } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundColor(.white.opacity(0.8))
                        .frame(width: 24, height: 24)
                }
            }
            ScrollViewReader { sp in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(chat.msgs) { m in
                            (Text(m.u).bold().foregroundColor(m.u == username ? Theme.orange : Color(white: 0.85)) + Text("  " + m.m).foregroundColor(.white))
                                .font(.system(size: 12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(m.id)
                        }
                    }
                }
                .onChange(of: chat.msgs.count) { _ in
                    if let l = chat.msgs.last { sp.scrollTo(l.id, anchor: .bottom) }
                }
                .onAppear { if let l = chat.msgs.last { sp.scrollTo(l.id, anchor: .bottom) } }
            }
            if let e = chat.error { Text(e).font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.orange) }
            HStack(spacing: 6) {
                TextField("Say something", text: $draft)
                    .font(.system(size: 13)).foregroundColor(.white)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit { send() }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.white.opacity(0.12)).cornerRadius(10)
                    .onChange(of: draft) { if $0.count > 200 { draft = String($0.prefix(200)) } }
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 26)).foregroundColor(Theme.orange)
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10)
        .frame(width: 300, height: 180)
        .background(Color.black.opacity(0.78))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.orange.opacity(0.7), lineWidth: 1))
        .cornerRadius(16)
    }

    private func send() {
        let t = draft
        draft = ""
        Task { await chat.send(t) }
    }
}
