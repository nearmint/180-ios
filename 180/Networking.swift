import Foundation

/// Session HTTP partagée de l'app, avec **timeouts bornés**.
///
/// `URLSession.shared` laisse pendre une requête jusqu'à 60 s par défaut, ce qui
/// fige les écrans de chargement hors-ligne. On borne la requête à 15 s et la
/// ressource complète à 30 s. Toutes les couches réseau (REST, auth, home,
/// version, images) passent par cette session.
enum AppHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        // Cache HTTP dimensionné (mémoire + disque, persistant entre lancements).
        // Les réponses porteuses de `Cache-Control`/`ETag` (visuels WP, requêtes
        // anonymes) sont alors réutilisées sans réseau ; `.useProtocolCachePolicy`
        // respecte la fraîcheur annoncée par le serveur. Sans en-tête positif, le
        // cache applicatif (`DiskCache`) prend le relais côté contenu.
        config.urlCache = URLCache(
            memoryCapacity: 16 * 1024 * 1024,   // 16 Mo RAM
            diskCapacity: 128 * 1024 * 1024      // 128 Mo disque
        )
        config.requestCachePolicy = .useProtocolCachePolicy
        // Délégué partagé, actif dans **toutes les configs** : garde-fou
        // anti-redirection-sur-POST (Debug + Release) + confiance au certificat
        // auto-signé local (Debug uniquement). Voir `AppSessionDelegate`.
        return URLSession(configuration: config, delegate: AppSessionDelegate.shared, delegateQueue: nil)
    }()
}

/// Délégué de session partagé, compilé et actif en **Debug comme en Release**.
///
/// Rôle principal (toutes configs) : **refuser de suivre une redirection HTTP
/// sur une requête POST**. Par défaut `URLSession` suit un 301/302 et rejoue la
/// requête en GET — le corps (donc identifiant + mot de passe du login) est
/// alors perdu silencieusement, et le serveur refuse. En bloquant la
/// redirection, l'appelant reçoit la réponse 3xx telle quelle et la traite comme
/// une erreur HTTP explicite, au lieu d'un échec d'auth trompeur. C'est ce
/// garde-fou qui aurait rendu le bug apex→www visible en trente secondes.
///
/// Rôle secondaire (**Debug uniquement**, cf. `#if DEBUG` plus bas) : faire
/// confiance au certificat auto-signé de l'environnement local (Local by
/// Flywheel sert `180c.local` en HTTPS non fiable), borné à l'hôte de l'API
/// local. En Release cette méthode n'est pas compilée : validation TLS standard.
///
/// `nonisolated` : `URLSession` appelle le délégué sur sa propre file
/// (`delegateQueue: nil`), jamais sur le main actor — isolation par défaut du
/// module. `Sendable` : uniquement des constantes immuables.
nonisolated final class AppSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = AppSessionDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Une requête non idempotente ne doit jamais être rejouée après une
        // redirection : `URLSession` la transformerait en GET et perdrait le
        // corps. On refuse (`nil`) → l'appelant reçoit la réponse 3xx d'origine.
        if task.originalRequest?.httpMethod == "POST" {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    #if DEBUG
    /// Hôte (apex) autorisé à présenter un cert auto-signé, ex. `180c.local`.
    private let trustedHost = URL(string: APIConfig.shared.apiBaseURL)?.host

    /// Variante `async` plutôt que `completionHandler:` : sous l'isolation
    /// `MainActor` par défaut du module, Swift 6.2 importe le handler de cette
    /// exigence comme `@MainActor`, signature impossible à satisfaire depuis la
    /// file du délégué. La forme `async` n'a pas de type closure à faire coïncider.
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust,
              let host = trustedHost,
              space.host == host || space.host == "www.\(host)" else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
    #endif
}

// MARK: - Erreurs réseau typées

/// Erreur d'API typée : permet de distinguer hors-ligne / timeout / HTTP /
/// décodage pour des messages UI pertinents et un retry ciblé.
enum APIError: LocalizedError, Equatable {
    case invalidURL
    case offline
    case timeout
    case http(Int)
    case serverError
    case decodingError

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "URL invalide"
        case .offline: return "Pas de connexion Internet"
        case .timeout: return "La requête a expiré"
        case .http(let code): return "Erreur serveur (\(code))"
        case .serverError: return "Erreur serveur"
        case .decodingError: return "Erreur de décodage"
        }
    }

    /// Message court orienté utilisateur (toasts / états d'erreur).
    var userMessage: String {
        switch self {
        case .offline: return "Pas de connexion Internet. Vérifiez votre réseau."
        case .timeout: return "La connexion est trop lente. Réessayez."
        default: return "Impossible de charger les données. Réessayez plus tard."
        }
    }

    /// Erreur transitoire → un retry léger peut réussir (GET idempotents).
    var isTransient: Bool {
        switch self {
        case .offline, .timeout: return true
        case .http(let code): return code >= 500
        default: return false
        }
    }

    /// Normalise n'importe quelle `Error` réseau/décodage en `APIError`.
    static func from(_ error: Error) -> APIError {
        if let api = error as? APIError { return api }
        if error is DecodingError { return .decodingError }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .timeout
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                 .cannotConnectToHost, .cannotFindHost:
                return .offline
            default:
                return .serverError
            }
        }
        return .serverError
    }
}
