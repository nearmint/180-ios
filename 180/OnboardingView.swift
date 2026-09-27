import SwiftUI

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var showLogin = false

    /// Transition de page : glissement par défaut, fondu si Reduce Motion.
    private var pageTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading))
    }

    var body: some View {
        ZStack {
            if page == 0 {
                featuresPage
                    .transition(pageTransition)
            } else {
                loginPage
                    .transition(pageTransition)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: page)
        .sheet(isPresented: $showLogin, onDismiss: {
            if AuthService.shared.isLoggedIn {
                AnalyticsService.onboardingComplete()
                hasCompletedOnboarding = true
            }
        }) {
            LoginView()
        }
        .onAppear { UmamiTracker.shared.trackScreen(path: "/onboarding", title: "Onboarding") }
    }

    // MARK: - Page 1 : Features

    private var featuresPage: some View {
        VStack(spacing: 0) {
            Spacer()

            Image("logo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundColor(colorScheme == .dark ? .white : .black)
                .frame(height: 70)
                .padding(.bottom, 32)

            VStack(alignment: .leading, spacing: 28) {
                OnboardingRow(
                    icon: "fork.knife",
                    title: "Les recettes 180°C",
                    description: "Retrouvez l'intégralité des recettes publiées dans 180°C, Les Cahiers de Delphine et 12°5."
                )
                OnboardingRow(
                    icon: "heart",
                    title: "Votre carnet de recettes",
                    description: "Sauvegardez vos recettes favorites et retrouvez-les en un instant."
                )
                OnboardingRow(
                    icon: "bell",
                    title: "Ne manquez rien",
                    description: "Recevez une notification à chaque nouvelle recette publiée."
                )
                OnboardingRow(
                    icon: "iphone.radiowaves.left.and.right",
                    title: "Secouez pour découvrir",
                    description: "Secouez votre iPhone pour accéder instantanément à une recette choisie au hasard."
                )
            }
            .padding(.horizontal, 30)

            Spacer()
            Spacer()

            Button {
                Haptics.medium()
                page = 1
            } label: {
                Text("Continuer")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accent180)
                    .foregroundColor(.white)
                    .cornerRadius(14)
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Page 2 : Connexion

    private var loginPage: some View {
        VStack(spacing: 0) {
            Spacer()

            Image("logo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundColor(colorScheme == .dark ? .white : .black)
                .frame(height: 70)
                .padding(.bottom, 16)

            Text("Connexion")
                .font(.headline)
                .padding(.bottom, 12)

            Text("Connectez-vous pour accéder à toutes les recettes, avec votre abonnement 180°C.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
                .padding(.bottom, 48)

            VStack(spacing: 16) {
                Button {
                    showLogin = true
                } label: {
                    Text("Se connecter")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accent180)
                        .foregroundColor(.white)
                        .cornerRadius(14)
                }

                Button {
                    Haptics.light()
                    AnalyticsService.onboardingComplete()
                    hasCompletedOnboarding = true
                } label: {
                    Text("Continuer sans compte")
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 30)

            Spacer()
            Spacer()
        }
    }
}

struct OnboardingRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accent180)
                .frame(width: 44, height: 44)
                .background(Color.accent180.opacity(0.15))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.bold)

                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }
}
