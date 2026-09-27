import SwiftUI

struct LoginView: View {
    @StateObject private var auth = AuthService.shared
    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) var colorScheme
    @State private var showSuccess = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Spacer().frame(height: 20)

                    Image("logo")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundColor(colorScheme == .dark ? .white : .black)
                        .frame(height: 64)

                    Text("Connectez-vous pour accéder à toutes les recettes 180°C")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    VStack(spacing: 16) {
                        TextField("Nom d'utilisateur ou email", text: $username)
                            .textContentType(.username)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)

                        SecureField("Mot de passe", text: $password)
                            .textContentType(.password)
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                    }
                    .padding(.horizontal)

                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    Button {
                        Task { await performLogin() }
                    } label: {
                        if isLoading {
                            ProgressView()
                                .tint(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                        } else {
                            Text("Se connecter")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .padding()
                        }
                    }
                    .background(Color.accent180)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                    .padding(.horizontal)
                    .disabled(username.isEmpty || password.isEmpty || isLoading)
                    .opacity(username.isEmpty || password.isEmpty ? 0.6 : 1)

                    WebLink("Mot de passe oublié ?", url: URL(string: APIConfig.shared.webLink("/mon-compte/lost-password/"))!)
                        .font(.subheadline)
                        .foregroundColor(.accent180)
                }
            }
            .navigationTitle("Connexion")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { UmamiTracker.shared.trackScreen(path: "/connexion", title: "Connexion") }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Fermer") { dismiss() }
                }
            }
            .overlay {
                if showSuccess {
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.green)

                        Text("Connexion réussie !")
                            .font(.title3)
                            .fontWeight(.bold)

                        Text("Bienvenue, \(AuthService.shared.firstName.isEmpty ? username : AuthService.shared.firstName)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground))
                    .transition(.opacity)
                    .onAppear {
                        Haptics.success()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation {
                                dismiss()
                            }
                        }
                    }
                }
            }
        }
    }

    private func performLogin() async {
        isLoading = true
        errorMessage = nil

        do {
            try await AuthService.shared.login(username: username, password: password)
            await MainActor.run {
                AnalyticsService.login(method: username.contains("@") ? "email" : "username")
                UmamiTracker.shared.trackEvent(name: "login_success")
                showSuccess = true
            }
        } catch {
            await MainActor.run {
                AnalyticsService.loginFailed(error: error.localizedDescription)
                // `reason` générique (cf. `AuthError.analyticsReason`) : jamais le
                // message affiché ni un texte serveur.
                let reason = (error as? AuthError)?.analyticsReason ?? "unknown"
                UmamiTracker.shared.trackEvent(name: "login_error", data: ["reason": reason])
                errorMessage = error.localizedDescription
            }
        }

        await MainActor.run { isLoading = false }
    }
}
