import SwiftUI

struct LoginForm: View {
    let onDone: (String, String) -> Void

    @State private var registering = false
    @State private var username = ""
    @State private var password = ""
    @State private var invite = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image("Logo").resizable().scaledToFit().frame(height: 44)
                BrandMark(size: 26)
                    .padding(.bottom, 4)
                Picker("", selection: $registering) {
                    Text("Log in").tag(false)
                    Text("Register").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                field("Username", text: $username, secure: false)
                    .onChange(of: username) { v in
                        let c = String(v.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }.prefix(15))
                        if c != v { username = c }
                    }
                field("Password", text: $password, secure: true)
                if registering { field("Invite code", text: $invite, secure: false, caps: true) }

                if let error { Text(error).font(.footnote).foregroundColor(.red) }

                Button(action: submit) {
                    Group {
                        if busy { ProgressView().tint(.white) }
                        else { Text(registering ? "CREATE ACCOUNT" : "LOG IN").font(.system(size: 16, weight: .heavy)).tracking(1.5) }
                    }
                    .frame(maxWidth: 320).padding(.vertical, 12)
                    .background(LinearGradient(colors: [Theme.orangeLight, Theme.orange], startPoint: .top, endPoint: .bottom).opacity(ready ? 1 : 0.4))
                    .cornerRadius(14).foregroundColor(.white)
                    .shadow(color: Theme.orange.opacity(ready ? 0.5 : 0), radius: 10)
                }
                .disabled(!ready || busy)
            }
            .padding(24)
            .frame(maxWidth: 380)
            .glassCard()
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
    }

    private var ready: Bool {
        username.count >= 3 && password.count >= (registering ? 8 : 1) && (!registering || invite.count >= 5)
    }

    @ViewBuilder
    private func field(_ title: String, text: Binding<String>, secure: Bool, caps: Bool = false) -> some View {
        Group {
            if secure { SecureField(title, text: text) }
            else { TextField(title, text: text) }
        }
        .textInputAutocapitalization(caps ? .characters : .never)
        .autocorrectionDisabled()
        .multilineTextAlignment(.center)
        .padding(12)
        .frame(maxWidth: 320)
        .background(Color.black.opacity(0.5))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.18), lineWidth: 1))
        .cornerRadius(12)
        .foregroundColor(.white)
    }

    private func submit() {
        busy = true; error = nil
        Task {
            do {
                let r = registering
                    ? try await AuthAPI.register(username: username, password: password, invite: invite)
                    : try await AuthAPI.login(username: username, password: password)
                busy = false
                onDone(r.token, r.username)
            } catch {
                busy = false
                self.error = error.localizedDescription
            }
        }
    }
}
