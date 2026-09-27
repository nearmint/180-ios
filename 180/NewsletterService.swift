import Foundation
import os

/// Statut d'opt-in normalisé renvoyé par le proxy serveur.
enum NewsletterStatus: String {
    case subscribed
    case unsubscribed
    case pending

    /// `pending` compte comme inscrit : le double opt-in place tout membre en
    /// attente tant que le lien de confirmation n'est pas cliqué — c'est un
    /// opt-in réel, pas une absence d'inscription.
    var isSubscribed: Bool { self == .subscribed || self == .pending }
}

/// Échec d'un appel newsletter, porteur du diagnostic serveur.
struct NewsletterError: Error {
    let httpCode: Int?
    /// `code` du `WP_Error` serveur : `email_mismatch`, `invalid_email`,
    /// `invalid_list`, `rate_limited`, `mailchimp_*`, `jwt_*`… — nomme la cause.
    let serverCode: String?
}

/// Service newsletter — proxy serveur `180c/v1/newsletter/subscribe`
/// (contrat apps).
///
/// La clé d'e-mailing ne quitte jamais le serveur : l'app envoie
/// `{ email, action }` + Bearer JWT. Le serveur vérifie que l'e-mail correspond
/// au compte authentifié puis relaie côté Mailchimp. Réponse : `{ list_id,
/// action, status }`.
///
/// **`list_id` volontairement OMIS** : le serveur applique alors son audience
/// unique (`_180c_nl_audience_id()`, `list_id` absent → défaut). Embarquer l'ID
/// d'audience dans l'app était fragile — si l'audience de prod diffère de la
/// constante compilée, le serveur rejetait **toutes** les requêtes en
/// `invalid_list` (400), invisible sur TestFlight (Release masque le code). En
/// laissant le serveur choisir, l'app ne peut plus se désynchroniser de prod.
final class NewsletterService {
    static let shared = NewsletterService()

    private var endpoint: String { "\(APIConfig.shared.restV1)/newsletter/subscribe" }

    private enum Action: String {
        case subscribe, unsubscribe, status
    }

    /// Appel proxy authentifié. Renvoie le statut normalisé ou un `NewsletterError`
    /// portant le code de refus serveur.
    private func call(_ action: Action, email: String) async -> Result<NewsletterStatus, NewsletterError> {
        guard let token = AuthService.shared.getToken(), let url = URL(string: endpoint) else {
            return .failure(NewsletterError(httpCode: nil, serverCode: "no_token"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "email": email.lowercased(),
            "action": action.rawValue,
        ])

        do {
            let (data, response) = try await AppHTTP.session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            #if DEBUG
            let body = String(data: data, encoding: .utf8) ?? "<illisible>"
            AppLogger.api.info("[NL \(action.rawValue, privacy: .public)] HTTP \(code) — \(String(body.prefix(300)), privacy: .public)")
            #endif

            guard code == 200 else {
                let serverCode = (try? JSONDecoder().decode(ServerError.self, from: data))?.code
                #if DEBUG
                AppLogger.api.error("[NL \(action.rawValue, privacy: .public)] refus HTTP \(code) — code=\(serverCode ?? "<absent>", privacy: .public)")
                #endif
                return .failure(NewsletterError(httpCode: code, serverCode: serverCode))
            }

            guard let decoded = try? JSONDecoder().decode(NewsletterResponse.self, from: data),
                  let status = NewsletterStatus(rawValue: decoded.status) else {
                return .failure(NewsletterError(httpCode: code, serverCode: "decode_error"))
            }
            return .success(status)
        } catch {
            AppLogger.api.error("Newsletter \(action.rawValue) error: \(error)")
            return .failure(NewsletterError(httpCode: nil, serverCode: "network"))
        }
    }

    /// Lecture du statut d'opt-in (lecture seule serveur, action `status`).
    func status(email: String) async -> Result<NewsletterStatus, NewsletterError> {
        await call(.status, email: email)
    }

    /// Inscription (double opt-in serveur → un nouveau membre passe `pending`).
    func subscribe(email: String) async -> Result<NewsletterStatus, NewsletterError> {
        await call(.subscribe, email: email)
    }

    /// Désinscription.
    func unsubscribe(email: String) async -> Result<NewsletterStatus, NewsletterError> {
        await call(.unsubscribe, email: email)
    }
}

// MARK: - Enveloppes de décodage

/// Enveloppe d'erreur REST WordPress : `{"code":"email_mismatch","message":…}`.
private struct ServerError: Decodable {
    let code: String
}

/// Réponse proxy newsletter (contrat apps).
struct NewsletterResponse: Decodable {
    let listID: String
    let action: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case listID = "list_id"
        case action
        case status
    }
}
