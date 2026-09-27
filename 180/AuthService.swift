import Foundation
import Combine
import UIKit
import Security
import os

class AuthService: ObservableObject {
    static let shared = AuthService()

    @Published var isLoggedIn = false
    @Published var username: String = ""
    @Published var email: String = ""
    @Published var firstName: String = ""
    @Published var lastName: String = ""
    @Published var isSubscriber = false

    /// Identifiant utilisateur WordPress, exposé par `/180c/v1/me` (optionnel :
    /// `nil` tant que le champ n'est pas servi par le serveur). Sert d'external
    /// id OneSignal (cf. `PushNotificationService`). N'intervient pas dans le
    /// flux d'authentification lui-même.
    @Published private(set) var userID: Int?

    /// Génération de session : incrémentée à **chaque changement d'identité**
    /// (login confirmé, déconnexion).
    ///
    /// Le paywall ne dépend pas d'un booléen local mais de `recipe_locked`,
    /// calculé par le serveur **au moment du fetch** en fonction du jeton envoyé.
    /// Les `Recipe` déjà décodées gardent donc l'état de la session précédente —
    /// c'est ce qui obligeait à tuer l'app après un login. Les vues observent
    /// cette valeur via `.task(id:)` et rejouent leur chargement avec le nouveau
    /// jeton, ce qui réévalue le verrouillage immédiatement.
    @Published private(set) var contentGeneration = 0

    /// `true` quand `email` provient de `/180c/v1/me`, seule source qui renvoie
    /// le `user_email` du compte.
    ///
    /// Les autres origines ne valent pas preuve : le payload JWT peut ne pas
    /// porter la clé `email` (→ chaîne vide), et le cache `UserDefaults` relu au
    /// démarrage peut être vide ou périmé — au relancement de l'app, aucun appel
    /// ne rafraîchit l'e-mail. Or le serveur refuse en `email_mismatch` (403) ou
    /// `invalid_email` (400) toute requête newsletter dont l'e-mail ne
    /// correspond pas exactement au compte authentifié.
    private var emailIsCanonical = false

    /// Stockage thread-safe du JWT : il est **lu** depuis des contextes
    /// background (`getToken()` appelé par les couches réseau) et **écrit** sur le
    /// main. Le verrou élimine la data race sur cette `class` non-`Sendable`.
    private let tokenStore = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// JWT courant. L'accès est protégé par `tokenStore` (thread-safe) ; la mise à
    /// jour de `isLoggedIn` (@Published) reste sur le main — toutes les écritures
    /// passent par `MainActor.run` (login/refresh), `logout()` ou `init` (main).
    private var jwtToken: String? {
        get { tokenStore.withLock { $0 } }
        set {
            tokenStore.withLock { $0 = newValue }
            isLoggedIn = (newValue != nil)
        }
    }

    private let tokenKey = "jwt_token"
    private let usernameKey = "saved_username"
    private let emailKey = "saved_email"
    private let firstNameKey = "saved_first_name"
    private let lastNameKey = "saved_last_name"
    /// Clé du statut abonné en cache. **Non privée** : `UmamiTracker` la relit
    /// pour taguer chaque event (son acteur ne peut pas atteindre cette classe
    /// `ObservableObject` non-`Sendable` sans saut sur le main actor).
    /// Le contrat de la clé : présente et à jour tant qu'une session est
    /// ouverte, supprimée par `logout()` — donc absente = visiteur.
    /// `nonisolated` : constante immuable, lisible depuis cet acteur sans saut.
    nonisolated static let isSubscriberDefaultsKey = "is_subscriber"

    init() {
        loadToken()
    }

    // MARK: - Login

    func login(username: String, password: String) async throws {
        // Credentials dans le **corps** (form-urlencoded), pas dans l'URL : évite
        // qu'identifiant/mot de passe finissent dans les logs serveur/proxy.
        guard let url = URL(string: APIConfig.shared.jwtRoute("/auth")) else {
            throw AuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formURLEncodedBody(["login": username, "password": password])

        // 1) Transport : hors-ligne, timeout, DNS, TLS, redirection refusée…
        //    On ne laisse jamais le message système brut atteindre l'UI.
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await AppHTTP.session.data(for: request)
        } catch {
            #if DEBUG
            AppLogger.auth.error("[login] erreur de transport : \(error.localizedDescription)")
            #endif
            throw fail(.transport)
        }

        // 2) Réponse non-HTTP (ne devrait pas arriver) → générique.
        guard let httpResponse = response as? HTTPURLResponse else {
            throw fail(.serverError)
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let dataDict = json?["data"] as? [String: Any]
        let successFlag = json?["success"] as? Bool

        // 3) Succès : success:true + jeton présent. On ne conditionne PAS au code
        //    HTTP : le code renvoyé par le plugin n'est pas fiable (cf. 4), un
        //    jeton valide est valide.
        if successFlag == true,
           let token = dataDict?["jwt"] as? String {

            await MainActor.run {
                self.jwtToken = token
                self.username = username
                self.email = ""
                // Nouvelle identité : l'e-mail qui va être lu du payload JWT
                // n'est pas une preuve, seul `/180c/v1/me` en sera une.
                self.emailIsCanonical = false
                // Le statut abonné en cache est celui du compte précédent :
                // invalidé tout de suite, il sera réécrit par
                // `checkSubscriptionStatus()` juste en dessous. Sans ça, un
                // ancien `true` déverrouillerait l'UI avant vérification.
                self.isSubscriber = false

                let parts = token.split(separator: ".")
                if parts.count == 3,
                   let payloadData = Data(base64Encoded: String(parts[1]).padding(toLength: ((parts[1].count + 3) / 4) * 4, withPad: "=", startingAt: 0)),
                   let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
                    self.email = payload["email"] as? String ?? ""
                    self.username = payload["username"] as? String ?? username
                }

                saveToken()
                Haptics.success()
            }

            // Profil puis statut abonné **en séquence**, et seulement ensuite la
            // nouvelle génération : les vues qui se rechargent voient alors un
            // `isSubscriber` déjà à jour côté serveur.
            Task {
                await self.fetchUserProfile()
                await self.checkSubscriptionStatus()
                await MainActor.run { self.bumpContentGeneration() }
            }
            Task { await FavoritesManager.shared.syncOnLogin() }
            return
        }

        // 4) Échec. IMPORTANT (vérifié en réel au curl) : le plugin renvoie
        //    **HTTP 400** — pas 200 — pour de mauvais identifiants, avec
        //    success:false et errorCode 48. Le code HTTP ne permet donc PAS de
        //    distinguer un refus d'identifiants d'une panne : la source de vérité
        //    est `errorCode`. `errorCode` arrive en Int (cas réel) ; fallback
        //    String par robustesse.
        let errorCode: Int? = (dataDict?["errorCode"] as? Int)
            ?? (dataDict?["errorCode"] as? String).flatMap { Int($0) }
        #if DEBUG
        let serverMessage = dataDict?["message"] as? String ?? "<aucun>"
        AppLogger.auth.error("[login] échec — HTTP \(httpResponse.statusCode), success=\(successFlag.map(String.init) ?? "nil"), errorCode=\(errorCode.map(String.init) ?? "nil"), message=\(serverMessage)")
        #endif

        if successFlag == false {
            // Refus structuré du plugin (quel que soit le code HTTP). Seul
            // errorCode 48 = mauvais identifiants ; tout autre code → générique.
            throw fail(errorCode == 48 ? .invalidCredentials : .pluginRefused)
        }
        // Pas de refus structuré : 5xx, page HTML, ou réponse 3xx renvoyée par le
        // garde-fou anti-redirection. Erreur de service, jamais imputée aux
        // identifiants de l'utilisateur.
        throw fail(.httpError)
    }

    /// Affiche le toast de l'erreur (message app, français) et la renvoie pour
    /// `throw`. Centralise la parité toast + propagation sur tous les chemins.
    private func fail(_ error: AuthError) -> AuthError {
        ToastManager.shared.show(error.localizedDescription)
        return error
    }

    // MARK: - Profil

    func fetchUserProfile() async {
        guard let token = jwtToken else { return }
        guard let url = URL(string: "\(APIConfig.shared.wpV2)/users/me?context=edit") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await AppHTTP.session.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                await MainActor.run {
                    self.firstName = json["first_name"] as? String ?? ""
                    self.lastName = json["last_name"] as? String ?? ""
                    self.email = json["email"] as? String ?? self.email
                    self.saveToken()
                }
            }
        } catch { AppLogger.auth.error("Erreur profil: \(error)") }
    }

    // MARK: - Abonnement

    func checkSubscriptionStatus() async {
        guard let token = jwtToken else { return }
        guard let url = URL(string: "\(APIConfig.shared.restV1)/me") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await AppHTTP.session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                AppLogger.auth.warning("Statut /me non OK")
                return
            }
            let me = try JSONDecoder().decode(MeResponse.self, from: data)
            await MainActor.run {
                self.isSubscriber = me.isSubscriber
                self.userID = me.id
                // Fin d'abonnement constatée **en ligne** : c'est le seul
                // moment où l'on a le droit de retirer l'accès hors ligne. Hors
                // connexion, aucune horloge locale ne doit jamais en décider.
                if !me.isSubscriber {
                    OfflineSyncService.shared.handleSubscriptionLost()
                }
                if !me.email.isEmpty {
                    self.email = me.email
                    // Seule écriture d'e-mail issue de `/180c/v1/me`, donc la
                    // seule à valoir `user_email` côté serveur.
                    self.emailIsCanonical = true
                }
                AppLogger.auth.info("Subscription status: \(me.isSubscriber ? "abonné" : "non abonné")")
                self.saveToken()
            }
        } catch {
            AppLogger.auth.error("Erreur vérification abonnement: \(error)")
        }
    }

    /// E-mail du compte **tel que le serveur le valide** (`user_email`).
    ///
    /// À utiliser pour toute requête où le serveur compare l'e-mail au compte
    /// authentifié (contrat newsletter). Tant que la valeur en mémoire n'a pas
    /// été confirmée par `/180c/v1/me`, elle est rafraîchie depuis cette source
    /// avant d'être renvoyée.
    ///
    /// - Returns: l'e-mail canonique, ou `nil` si aucun e-mail n'est
    ///   résolvable — l'appelant ne doit alors **pas** émettre la requête
    ///   plutôt que d'en envoyer une vide (que le serveur rejette en 400).
    func canonicalEmail() async -> String? {
        if emailIsCanonical, !email.isEmpty { return email }
        await checkSubscriptionStatus()
        return email.isEmpty ? nil : email
    }

    // MARK: - Token Refresh

    /// Date d'expiration (`exp`) portée par un JWT, `nil` s'il est illisible.
    ///
    /// Le payload d'un JWT est encodé en **base64url** (RFC 7515) : `-` et `_` y
    /// remplacent `+` et `/`, et le padding `=` est omis. `Data(base64Encoded:)`
    /// ne connaît que le base64 standard — sans cette conversion, un jeton
    /// parfaitement valide est jugé illisible dès que son payload contient l'un
    /// de ces deux caractères, ce qui arrive couramment.
    ///
    /// `exp` est lu en `TimeInterval` (cas normal), avec repli sur une chaîne
    /// numérique par robustesse — même précaution que sur l'`errorCode` du login.
    static func tokenExpiration(of token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }

        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 = base64.padding(
            toLength: ((base64.count + 3) / 4) * 4,
            withPad: "=",
            startingAt: 0
        )

        guard let payloadData = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else { return nil }

        let exp = (payload["exp"] as? TimeInterval)
            ?? (payload["exp"] as? String).flatMap { TimeInterval($0) }
        guard let exp else { return nil }

        return Date(timeIntervalSince1970: exp)
    }

    func refreshTokenIfNeeded() async {
        guard let token = jwtToken else { return }

        // Jeton illisible : aucun refresh ne le réparera, et il continuerait à
        // partir en en-tête `Authorization` sur chaque appel — ce qui fait
        // rejeter par le middleware JWT **toutes** les lectures, y compris
        // publiques (`wp/v2/recipe` → HTTP 400). Symptôme observé : un accueil
        // sans aucun rail, les blocs étant décodés mais jamais hydratés.
        // Retomber en visiteur restaure un état fonctionnel.
        guard let expirationDate = Self.tokenExpiration(of: token) else {
            AppLogger.auth.warning("Jeton illisible — purge de la session")
            await MainActor.run { self.expireSession() }
            return
        }

        let daysUntilExpiry = expirationDate.timeIntervalSinceNow / 86400

        AppLogger.auth.info("Token expires in \(Int(daysUntilExpiry)) days")

        // Déjà expiré : le refresh ne le ressuscitera pas — le plugin répond
        // « JWT is too old to be refreshed » avec `success:false` en **HTTP 200**,
        // que la branche 401/403 de `refreshToken()` ne peut pas intercepter
        // (même piège que sur le login, cf. l'échec structuré traité plus haut).
        // Le jeton restait donc en keychain indéfiniment. On purge ici, en
        // amont, sur le seul critère qui ne dépende pas du plugin : sa date.
        guard expirationDate > Date() else {
            AppLogger.auth.warning("Jeton expiré — purge de la session")
            await MainActor.run { self.expireSession() }
            return
        }

        if daysUntilExpiry < 7 {
            AppLogger.auth.info("Token expiring soon, attempting refresh...")
            await refreshToken()
        }
    }

    /// Purge une session qui ne peut plus rien authentifier, et le signale.
    ///
    /// Séparée de `logout()` : même effet, mais l'utilisateur n'a rien demandé —
    /// il doit comprendre pourquoi il se retrouve déconnecté. À n'appeler que
    /// depuis le main, comme `logout()`.
    private func expireSession() {
        logout()
        ToastManager.shared.show("Votre session a expiré. Veuillez vous reconnecter.", type: .info)
    }

    private func refreshToken() async {
        guard let oldToken = jwtToken else { return }

        guard let url = URL(string: APIConfig.shared.jwtRoute("/auth/refresh")) else { return }

        // JWT dans le corps plutôt qu'en query string (logs serveur).
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formURLEncodedBody(["JWT": oldToken])

        do {
            let (data, response) = try await AppHTTP.session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else { return }

            if httpResponse.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let success = json["success"] as? Bool, success,
               let dataDict = json["data"] as? [String: Any],
               let newToken = dataDict["jwt"] as? String {

                await MainActor.run {
                    self.jwtToken = newToken
                    self.saveToken()
                    AppLogger.auth.info("Token refreshed successfully")
                }
            } else {
                let body = String(data: data, encoding: .utf8) ?? ""
                AppLogger.auth.warning("Token refresh failed: \(body.prefix(200))")

                // Le serveur rejette explicitement l'authentification : la
                // session est morte, quelle que soit la date du jeton.
                //
                // Un refus *structuré* (`success:false`, quel que soit le code
                // HTTP) ne suffit en revanche pas à conclure : le plugin refuse
                // aussi de rafraîchir un jeton encore parfaitement valide, passé
                // sa fenêtre de renouvellement. Déconnecter là-dessus couperait
                // une session qui a encore des jours à vivre. Ce cas est déjà
                // couvert en amont par `refreshTokenIfNeeded()`, qui purge dès
                // que la date d'expiration est atteinte.
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    await MainActor.run {
                        AppLogger.auth.warning("Token invalid, logging out")
                        self.expireSession()
                    }
                }
            }
        } catch {
            AppLogger.auth.error("Token refresh error: \(error.localizedDescription)")
        }
    }

    // MARK: - Logout

    func logout() {
        jwtToken = nil
        username = ""
        email = ""
        emailIsCanonical = false
        firstName = ""
        lastName = ""
        isSubscriber = false
        userID = nil
        KeychainHelper.shared.delete(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: usernameKey)
        UserDefaults.standard.removeObject(forKey: emailKey)
        UserDefaults.standard.removeObject(forKey: firstNameKey)
        UserDefaults.standard.removeObject(forKey: lastNameKey)
        UserDefaults.standard.removeObject(forKey: Self.isSubscriberDefaultsKey)

        // Purge aussi la session web (cookies WP du WKWebView) : sans ça, les
        // liens internes (« Gérer mon abonnement »…) restaient authentifiés.
        WebSession.clearSession()

        // Le carnet est un service **de compte**. Ses IDs locaux ne doivent pas
        // survivre à la session : sur un appareil partagé, le login suivant les
        // pousserait dans le carnet du compte entrant via `syncOnLogin()`.
        FavoritesManager.shared.clearLocal()

        // Et les fiches téléchargées avec, puisqu'elles matérialisent ce carnet
        // — y compris du contenu réservé aux abonnés.
        OfflineSyncService.shared.disableAndPurge()

        // Le contenu en mémoire a été chargé avec le jeton : il doit être
        // refetché **déverrouillé côté visiteur** (symétrique du login).
        bumpContentGeneration()
    }

    /// Publie un changement d'identité. Toujours appelé depuis le main (login :
    /// `MainActor.run` ; logout : action d'UI), comme les autres `@Published`
    /// de cette classe.
    private func bumpContentGeneration() {
        contentGeneration += 1
    }

    // MARK: - Token

    func getToken() -> String? {
        return jwtToken
    }

    /// Encode des paires clé/valeur en `application/x-www-form-urlencoded`.
    /// Pourcent-encode tout sauf les caractères non réservés (RFC 3986) afin que
    /// `&`/`=`/`+` éventuels d'un mot de passe ne corrompent pas le corps.
    private static func formURLEncodedBody(_ params: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = params.map { key, value -> String in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }
        return pairs.joined(separator: "&").data(using: .utf8) ?? Data()
    }

    // MARK: - Persistence

    private func saveToken() {
        if let token = jwtToken {
            KeychainHelper.shared.save(token, forKey: tokenKey)
        } else {
            KeychainHelper.shared.delete(forKey: tokenKey)
        }
        UserDefaults.standard.set(username, forKey: usernameKey)
        UserDefaults.standard.set(email, forKey: emailKey)
        UserDefaults.standard.set(firstName, forKey: firstNameKey)
        UserDefaults.standard.set(lastName, forKey: lastNameKey)
        UserDefaults.standard.set(isSubscriber, forKey: Self.isSubscriberDefaultsKey)
    }

    private func loadToken() {
        // Migration de UserDefaults vers Keychain
        if let oldToken = UserDefaults.standard.string(forKey: tokenKey) {
            KeychainHelper.shared.save(oldToken, forKey: tokenKey)
            UserDefaults.standard.removeObject(forKey: tokenKey)
        }
        jwtToken = KeychainHelper.shared.read(forKey: tokenKey)
        // Migration d'accessibilité : ré-écrit le token existant avec la nouvelle
        // accessibilité durcie. Même valeur de JWT → aucune déconnexion.
        if let token = jwtToken {
            KeychainHelper.shared.save(token, forKey: tokenKey)
        }
        username = UserDefaults.standard.string(forKey: usernameKey) ?? ""
        email = UserDefaults.standard.string(forKey: emailKey) ?? ""
        // Valeur de cache : rien ne prouve qu'elle vaut encore `user_email`.
        // `canonicalEmail()` la fera reconfirmer par `/180c/v1/me`.
        emailIsCanonical = false
        firstName = UserDefaults.standard.string(forKey: firstNameKey) ?? ""
        lastName = UserDefaults.standard.string(forKey: lastNameKey) ?? ""
        isSubscriber = UserDefaults.standard.bool(forKey: Self.isSubscriberDefaultsKey)
    }
}

// MARK: - Réponse /me (statut abonné)

struct MeResponse: Decodable {
    let isSubscriber: Bool
    let email: String
    let displayName: String
    /// Identifiant utilisateur WordPress. Optionnel : absent tant que le thème
    /// n'ajoute pas le champ `id` à la réponse `/180c/v1/me`.
    let id: Int?

    enum CodingKeys: String, CodingKey {
        case isSubscriber = "is_subscriber"
        case email
        case displayName = "display_name"
        case id
    }
}

/// Erreur d'authentification typée. **Tous les messages sont définis côté app,
/// en français** : aucun message serveur brut (ex. « Wrong user credentials. »)
/// ne doit jamais atteindre l'utilisateur. Le message serveur et l'`errorCode`
/// restent en log DEBUG uniquement.
enum AuthError: LocalizedError {
    /// URL d'endpoint invalide (config cassée).
    case invalidURL
    /// HTTP 200 + `success:false` + `errorCode: 48` — le serveur refuse
    /// réellement les identifiants. **Seul** cas légitime de ce message.
    case invalidCredentials
    /// HTTP 200 + `success:false` avec un autre `errorCode` (refus du plugin
    /// pour une raison qui n'est pas une faute de saisie).
    case pluginRefused
    /// Code HTTP hors 200 (400 après redirection, 5xx, maintenance…).
    case httpError
    /// Erreur de transport (`URLError` : hors-ligne, timeout, DNS, TLS…).
    case transport
    /// Réponse inattendue non exploitable (non-HTTP, corps illisible).
    case serverError

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "URL invalide"
        case .invalidCredentials: return "Identifiants incorrects"
        case .pluginRefused: return "Erreur de connexion, réessayez plus tard."
        case .httpError: return "Le service est momentanément indisponible."
        case .transport: return "Vérifiez votre connexion internet."
        case .serverError: return "Le service est momentanément indisponible."
        }
    }

    /// Libellé **générique** pour l'analytics (`login_error`, champ `reason`).
    /// Volontairement distinct d'`errorDescription` : aucun message serveur ni
    /// texte d'interface ne part dans les statistiques, seulement une cause
    /// stable et comparable entre plateformes.
    var analyticsReason: String {
        switch self {
        case .invalidURL: return "invalid_url"
        case .invalidCredentials: return "invalid_credentials"
        case .pluginRefused: return "plugin_refused"
        case .httpError: return "http_error"
        case .transport: return "transport"
        case .serverError: return "server_error"
        }
    }
}

// MARK: - Keychain Helper

class KeychainHelper {
    static let shared = KeychainHelper()

    func save(_ data: String, forKey key: String) {
        guard let data = data.data(using: .utf8) else { return }

        // Supprimer l'ancien
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Ajouter le nouveau, avec accessibilité durcie : lisible seulement après
        // le 1er déverrouillage (utilisable en tâche de fond) et **lié à cet
        // appareil** (jamais migré vers un autre appareil ni dans une sauvegarde).
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            AppLogger.auth.error("Keychain save échec (OSStatus \(status))")
        }
    }

    func read(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        SecItemCopyMatching(query as CFDictionary, &result)

        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
