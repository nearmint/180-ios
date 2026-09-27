import Foundation
import os

/// Source unique des URLs d'environnement (prod ↔ local).
///
/// Les valeurs `API_BASE_URL` / `WEB_BASE_URL` sont injectées dans l'Info.plist
/// généré à partir des `.xcconfig` (`Config/Local.xcconfig`, `Config/Release.xcconfig`)
/// selon la configuration de build. `APIConfig` les lit une seule fois au démarrage
/// et expose les chemins REST + les liens web.
///
/// Chaque environnement est fixé sur son domaine **canonique** : en prod
/// `www.180c.fr` (l'apex `180c.fr` redirige en 301 vers `www`, et ce 301
/// dégrade un POST en GET) ; en local `180c.local` (l'apex, `www.180c.local`
/// n'existant pas).
struct APIConfig: Sendable {

    nonisolated static let shared = APIConfig()

    /// Hôte de l'API (domaine canonique). Provient EXCLUSIVEMENT de l'Info.plist
    /// injecté par la config (`Local` → `180c.local`, `Release` → `www.180c.fr`).
    /// Jamais de défaut prod codé en dur : un repli silencieux masquerait une
    /// config non câblée.
    let apiBaseURL: String

    /// Hôte web pour les liens navigateur (apex).
    let webBaseURL: String

    /// App ID OneSignal, injecté depuis les xcconfig via la clé Info.plist
    /// `OneSignalAppId`. Lecture **tolérante** : chaîne vide si absent (le
    /// service push se désactive proprement plutôt que de crasher). L'App ID
    /// n'est pas un secret.
    let oneSignalAppId: String

    /// Adresse « Contacter la rédaction » (clé Info.plist `ContactEditorialEmail`).
    let editorialEmail: String

    /// Adresse « Contacter le support » (clé Info.plist `ContactSupportEmail`).
    let supportEmail: String

    private init() {
        let info = Bundle.main.infoDictionary

        // Lit une clé d'env ; en cas d'absence, échoue bruyamment (assert en
        // DEBUG) plutôt que de retomber silencieusement sur la prod.
        func read(_ key: String) -> String {
            let raw = (info?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if raw.isEmpty {
                assertionFailure("[APIConfig] \(key) absent de l'Info.plist — xcconfig non câblé (scheme/config ?).")
            }
            return raw
        }

        self.apiBaseURL = read("API_BASE_URL")
        self.webBaseURL = read("WEB_BASE_URL")

        // Lecture tolérante (pas d'assert) : l'absence d'App ID désactive le
        // push sans casser le reste de l'app.
        self.oneSignalAppId = (info?["OneSignalAppId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Adresses de contact : lecture tolérante, repli sur les adresses
        // publiées sur le site si la config ne les fournit pas.
        func email(_ key: String, _ fallback: String) -> String {
            let raw = (info?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.contains("@") ? raw : fallback
        }
        self.editorialEmail = email("ContactEditorialEmail", "redaction@180c.fr")
        self.supportEmail = email("ContactSupportEmail", "contact@180c.fr")

        // Log de démarrage conservé : rend l'environnement effectif visible à
        // chaque lancement (diagnostic local vs prod). Via OSLog plutôt que
        // `print()` (pas de pollution stdout en release). Copies locales : éviter
        // que l'autoclosure du logger capture `self` pendant l'init.
        let api = apiBaseURL, web = webBaseURL
        AppLogger.data.info("[APIConfig] API_BASE_URL=\(api, privacy: .public) | WEB_BASE_URL=\(web, privacy: .public)")
    }

    // MARK: - REST WordPress

    /// Base REST du cœur WordPress (`/wp-json/wp/v2`).
    var wpV2: String { "\(apiBaseURL)/wp-json/wp/v2" }

    /// Base REST custom 180°C (`/wp-json/180c/v1`).
    var restV1: String { "\(apiBaseURL)/wp-json/180c/v1" }

    /// Route du plugin Simple JWT Login via `?rest_route` (auth / refresh).
    /// - Parameter path: chemin relatif au namespace, ex. `"/auth"`.
    func jwtRoute(_ path: String) -> String {
        "\(apiBaseURL)/?rest_route=/simple-jwt-login/v1\(path)"
    }

    // MARK: - Liens web (navigateur)

    /// Construit un lien web absolu vers le site.
    /// - Parameter path: chemin relatif (avec ou sans `/` initial).
    func webLink(_ path: String) -> String {
        let normalized = path.hasPrefix("/") ? path : "/\(path)"
        return "\(webBaseURL)\(normalized)"
    }

    /// Lien web **auto-connecté** via l'endpoint thème `?180c_app_login=1`.
    ///
    /// Le JWT n'est **PAS** dans l'URL (il finirait dans les logs serveur) : seul
    /// le marqueur + la destination `redirect`. `WebSession.prime` envoie le token
    /// en **corps POST** au moment de l'amorçage, l'endpoint pose le cookie, puis
    /// le webview charge `path` déjà connecté. Sans token, lien web simple.
    ///
    /// Le paramètre `token` ne sert qu'à choisir le type de lien (auto-login vs
    /// simple) ; la valeur effective est relue par `prime` à l'amorçage.
    func autoLoginLink(_ path: String, token: String?) -> String {
        guard let token, !token.isEmpty else { return webLink(path) }
        let normalized = path.hasPrefix("/") ? path : "/\(path)"
        let encoded = normalized.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? normalized
        return "\(webBaseURL)/?180c_app_login=1&redirect=\(encoded)"
    }
}

/// Identifiants App Store. **Source unique** de l'ID.
enum AppStoreInfo {
    /// ID App Store (ex. `"id1234567890"`). `nil` tant que l'app n'est **pas
    /// publiée** : les fonctions qui en dépendent (Noter / Partager / invite de
    /// mise à jour) sont alors **masquées ou no-op** (aucun lien factice).
    /// 👉 À renseigner à la publication.
    static let appID: String? = nil

    /// `true` lorsqu'un ID réel est configuré.
    static var isConfigured: Bool { appID != nil }

    /// Fiche App Store (partage / mise à jour). `nil` si non configuré.
    static var appStoreURL: URL? {
        appID.flatMap { URL(string: "https://apps.apple.com/app/\($0)") }
    }

    /// Écran « Donner une note ». `nil` si non configuré.
    static var reviewURL: URL? {
        appID.flatMap { URL(string: "itms-apps://itunes.apple.com/app/\($0)?action=write-review") }
    }
}
