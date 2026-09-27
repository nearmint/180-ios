import SwiftUI
import Combine
import os

/// État et logique du toggle newsletter, isolés de la vue.
///
/// **Pourquoi un store + un `Binding` custom ?** Lier un `Toggle` à un `@State`
/// que l'on écrit aussi par programme (hydratation, rollback) rend `.onChange`
/// incapable de distinguer un geste utilisateur d'un écho — source répétée de
/// bugs (opt-in fantôme, toggle qui s'éteint seul). Ici, `isOn` est piloté par le
/// serveur ; le geste utilisateur passe par `toggle(to:)` (appelé **uniquement**
/// par le setter du `Binding`), jamais par un observateur. Plus d'écho possible.
@MainActor
final class NewsletterStore: ObservableObject {
    /// Reflète l'état **serveur** connu (source de vérité de l'affichage).
    @Published private(set) var isOn = false
    /// Mutation en cours (désactive le toggle + affiche un indicateur).
    @Published private(set) var isBusy = false

    /// Dernier code d'erreur serveur, joint au mail de support (diagnostic
    /// TestFlight : la cause d'un refus est lisible sans build DEBUG).
    private(set) var lastErrorCode: String?

    /// Dernière valeur confirmée par le serveur, pour le rollback.
    private var serverValue: Bool?

    /// `Binding` à passer au `Toggle`. Le **setter n'est appelé que sur geste
    /// utilisateur** ; les mises à jour programmatiques de `isOn` passent par le
    /// getter (re-render) sans redéclencher d'appel réseau.
    var binding: Binding<Bool> {
        Binding(
            get: { self.isOn },
            set: { desired in Task { await self.toggle(to: desired) } }
        )
    }

    /// Lit le statut serveur au chargement de l'écran / changement de session.
    /// Un statut illisible **laisse l'état inchangé** (jamais de faux OFF).
    func hydrate() async {
        guard AuthService.shared.isLoggedIn,
              let email = await AuthService.shared.canonicalEmail() else {
            return
        }
        switch await NewsletterService.shared.status(email: email) {
        case .success(let status):
            apply(subscribed: status.isSubscribed)
        case .failure(let error):
            // 401/403/429/503, réseau, décodage → on ne touche pas au toggle.
            lastErrorCode = error.serverCode
        }
    }

    /// Applique un geste utilisateur. Optimiste puis réconcilié / rollback.
    private func toggle(to desired: Bool) async {
        guard !isBusy, AuthService.shared.isLoggedIn else { return }
        // Rien à faire si l'état visé est déjà l'état serveur (double tap, écho).
        guard desired != serverValue else { return }

        guard let email = await AuthService.shared.canonicalEmail() else {
            ToastManager.shared.show(Self.failureMessage(NewsletterError(httpCode: nil, serverCode: "no_email")))
            return
        }

        isBusy = true
        isOn = desired   // optimiste : retour visuel immédiat

        let result = desired
            ? await NewsletterService.shared.subscribe(email: email)
            : await NewsletterService.shared.unsubscribe(email: email)

        switch result {
        case .success(let status):
            apply(subscribed: status.isSubscribed)
            if desired {
                AnalyticsService.newsletterSubscribe()
            } else {
                AnalyticsService.newsletterUnsubscribe()
            }
        case .failure(let error):
            // Rollback visuel sur la dernière valeur serveur connue.
            isOn = serverValue ?? !desired
            lastErrorCode = error.serverCode
            ToastManager.shared.show(Self.failureMessage(error))
        }

        isBusy = false
    }

    private func apply(subscribed: Bool) {
        serverValue = subscribed
        isOn = subscribed
        // Persiste l'état réel : lu par les analytics et le mail de support.
        UserDefaults.standard.set(subscribed, forKey: "newsletter_cahiers")
    }

    /// Message d'échec. En **DEBUG** il porte le code HTTP + serveur ; en
    /// Release, message générique (aucun code interne ne fuite à l'utilisateur).
    private static func failureMessage(_ error: NewsletterError) -> String {
        let base = "Impossible de mettre à jour votre inscription newsletter."
        #if DEBUG
        let http = error.httpCode.map { "HTTP \($0)" } ?? "réseau"
        return "\(base) (\(http) · \(error.serverCode ?? "sans code"))"
        #else
        return base
        #endif
    }
}
