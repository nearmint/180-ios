import SwiftUI

/// Bandeau persistant affiché tant que l'appareil est hors ligne.
///
/// Il ne remplace pas les états d'erreur des écrans : il **explique** (le
/// contenu qui manque n'est pas cassé, il est hors de portée) et **oriente**
/// (le carnet, lui, reste consultable). Le CTA est proposé même si rien n'a été
/// téléchargé : le carnet gère son propre état vide, et une porte visible vaut
/// mieux qu'une porte qu'on retire au moment où elle servirait.
struct OfflineBanner: View {

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.subheadline)
                .foregroundColor(.accent180)

            Text("Vous êtes hors ligne")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.primary)

            Spacer(minLength: 8)

            Button {
                Haptics.selection()
                TabRouter.shared.selected = TabRouter.Tab.favorites
            } label: {
                Text("Voir mon carnet")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.accent180)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Modificateur

/// Épingle le bandeau au-dessus d'un écran tant que la connectivité est perdue.
private struct OfflineBannerModifier: ViewModifier {

    /// Forme optionnelle volontaire : une vue montée hors de la hiérarchie
    /// injectée (aperçu Xcode, sheet détachée) retombe sur le singleton plutôt
    /// que de faire crasher l'app pour un bandeau.
    @Environment(NetworkMonitor.self) private var injected: NetworkMonitor?

    private var monitor: NetworkMonitor { injected ?? .shared }

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if !monitor.isConnected {
                OfflineBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: monitor.isConnected)
    }
}

extension View {
    /// Bandeau hors ligne persistant (Accueil, Recherche, Mon compte).
    func offlineBanner() -> some View {
        modifier(OfflineBannerModifier())
    }
}

// MARK: - État d'erreur typé

/// État d'erreur réseau **typé**, partagé par tous les écrans.
///
/// Le message affiché est celui de la taxonomie (`APIError.userMessage`), en
/// français : un écran ne doit jamais présenter une panne réseau comme une
/// absence de résultats.
struct TypedErrorView: View {

    let error: APIError
    /// Action de reprise. Absente ⇒ aucun bouton (l'écran se recharge autrement,
    /// par exemple au pull-to-refresh).
    var retry: (() async -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(error.userMessage)
        } actions: {
            if let retry {
                Button {
                    Task { await retry() }
                } label: {
                    Text("Réessayer")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.accent180)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var title: String {
        switch error {
        case .offline: return "Vous êtes hors ligne"
        case .timeout: return "Connexion trop lente"
        default: return "Chargement impossible"
        }
    }

    private var icon: String {
        switch error {
        case .offline: return "wifi.slash"
        case .timeout: return "clock.badge.exclamationmark"
        default: return "exclamationmark.triangle"
        }
    }
}
