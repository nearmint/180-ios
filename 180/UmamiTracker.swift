//
//  UmamiTracker.swift
//  180
//
//  Client Umami maison : Umami ne publie aucun SDK mobile, on parle donc
//  directement à l'API Umami Cloud (`POST /api/send`, sans authentification).
//
//  ⚠️ PROPRIÉTÉ UMAMI COMMUNE — le `websiteID` est partagé avec le site web et
//  l'app Android. Les noms d'events et le mapping écran → URL doivent rester
//  STRICTEMENT identiques entre les trois plateformes : toute divergence casse
//  les rapports agrégés. Les hits iOS se distinguent par `hostname` et `tag`,
//  jamais par un nom d'event dérivé.
//
//  Aucune donnée personnelle n'est transmise : ni e-mail, ni identifiant
//  utilisateur, ni jeton.
//

import Foundation
import UIKit
import os

/// Métadonnées du device, lues **une fois** par session sur le main actor puis
/// figées (elles ne changent pas en cours d'exécution : l'app est verrouillée en
/// portrait, cf. `AppDelegate.supportedInterfaceOrientationsFor`).
private struct UmamiDevice: Sendable {
    /// Taille de l'écran en points, `"390x844"`.
    let screen: String
    /// Locale réelle du device, format BCP-47 (`"fr-FR"`).
    let language: String
    /// User-Agent au format navigateur, construit depuis la version d'iOS réelle.
    let userAgent: String

    @MainActor
    static func current() -> UmamiDevice {
        let size = UIScreen.main.bounds.size
        // Portrait normalisé : le petit côté est la largeur, quelle que soit
        // l'orientation au moment de la lecture.
        let width = Int(min(size.width, size.height).rounded())
        let height = Int(max(size.width, size.height).rounded())

        // `preferredLanguages` rend déjà du BCP-47 (`fr-FR`) ; l'identifiant de
        // locale (`fr_FR`) sert de repli avec normalisation du séparateur.
        let language = Locale.preferredLanguages.first
            ?? Locale.current.identifier.replacingOccurrences(of: "_", with: "-")

        return UmamiDevice(
            screen: "\(width)x\(height)",
            language: language,
            userAgent: makeUserAgent()
        )
    }

    /// User-Agent réaliste. **Obligatoire** : avec l'UA par défaut d'`URLSession`
    /// (`180/1.0 CFNetwork/… Darwin/…`), Umami classe le hit comme bot et le jette.
    @MainActor
    private static func makeUserAgent() -> String {
        let version = UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")
        let platform = UIDevice.current.userInterfaceIdiom == .pad
            ? "iPad; CPU OS \(version)"
            : "iPhone; CPU iPhone OS \(version)"
        return "Mozilla/5.0 (\(platform) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
    }
}

/// Traceur Umami de l'app : pages vues + events custom.
///
/// Acteur dédié plutôt que classe `@MainActor` : l'encodage JSON et la gestion
/// du jeton de session se font hors du main actor, pour qu'aucun hit ne coûte
/// quoi que ce soit à l'UI. Les points d'entrée publics sont `nonisolated` et
/// synchrones : un appelant (vue SwiftUI, service) déclenche un envoi sans
/// `await` et sans jamais attendre le réseau.
actor UmamiTracker {

    static let shared = UmamiTracker()

    // MARK: - Constantes de la propriété Umami

    private static let endpoint = URL(string: "https://cloud.umami.is/api/send")!

    /// Identifiant de la propriété Umami — **commun web / Android / iOS**.
    private static let websiteID = "94b264d5-6963-4678-9d7f-316583113c91"

    /// Hôte virtuel des hits iOS. Fixe sur chaque requête : c'est lui qui isole
    /// le trafic app dans la propriété commune. Ne jamais l'omettre.
    private static let hostname = "ios.180c.fr"

    /// Tag de plateforme, fixe sur chaque requête (même rôle que `hostname`).
    private static let tag = "ios"

    /// Clé du drapeau de première ouverture (`app_first_open`).
    private static let firstOpenKey = "umami.hasTrackedFirstOpen"

    /// Tracking coupé en DEBUG pour ne pas polluer les statistiques. Constante
    /// **runtime** (et non `#if` autour du corps d'envoi) : tout le chemin
    /// d'envoi reste ainsi compilé dans les deux configurations, une erreur de
    /// compilation ne peut pas se cacher dans la branche Release.
    private static let isEnabled: Bool = {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }()

    /// Session dédiée aux hits analytics.
    ///
    /// Volontairement distincte d'`AppHTTP.session` : (1) ce sont des POST
    /// fire-and-forget qui n'ont rien à faire dans l'`URLCache` applicatif d'où
    /// la config `ephemeral`, (2) un hit perdu ne doit pas mobiliser une
    /// connexion pendant 15 s, (3) `AppHTTP.session` est isolée sur le main
    /// actor (isolation par défaut du module) et cet acteur ne l'est pas.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    // MARK: - État de session

    private var device: UmamiDevice?

    /// Jeton renvoyé par Umami dans le champ `cache` de la réponse, réémis en
    /// header `x-umami-cache` sur tous les appels suivants : c'est lui qui
    /// regroupe les hits en une même session côté Umami (indispensable aux
    /// funnels). Durée de vie = session app, aucune persistance disque.
    private var cacheToken: String?

    /// Dernier écran vu : sert d'`url` aux events custom.
    private var currentPath: String?
    private var currentTitle = ""

    /// Écran précédent, envoyé en `referrer` (vide au premier écran).
    private var previousPath = ""

    private init() {}

    // MARK: - API publique (fire-and-forget)

    /// Page vue. Payload **sans** champ `name`.
    /// - Parameters:
    ///   - path: chemin court calqué sur le site (`/recettes`, `/recette/tarte-citron`).
    ///   - title: titre lisible de l'écran.
    nonisolated func trackScreen(path: String, title: String) {
        Task(priority: .utility) { await self.recordScreen(path: path, title: title) }
    }

    /// Event custom, rattaché au dernier écran vu. Payload **avec** champ `name`.
    /// - Parameters:
    ///   - name: nom exact en snake_case, commun aux trois plateformes.
    ///   - data: propriétés de l'event (valeurs texte uniquement).
    nonisolated func trackEvent(name: String, data: [String: String]? = nil) {
        Task(priority: .utility) { await self.recordEvent(name: name, data: data) }
    }

    /// `app_first_open` : émis **une seule fois** dans la vie de l'installation,
    /// gardé par un drapeau `UserDefaults`.
    nonisolated func trackFirstOpenIfNeeded() {
        // En DEBUG on ne consomme pas le drapeau : sinon un build de dev lancé
        // avant l'installation d'une Release sur le même appareil brûlerait la
        // première ouverture, qui ne serait alors jamais mesurée.
        guard Self.isEnabled else { return }

        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.firstOpenKey) else { return }
        defaults.set(true, forKey: Self.firstOpenKey)
        trackEvent(name: "app_first_open")
    }

    // MARK: - Enregistrement

    private func recordScreen(path: String, title: String) async {
        if let currentPath { previousPath = currentPath }
        currentPath = path
        currentTitle = title
        await send(url: path, title: title, name: nil, data: nil)
    }

    private func recordEvent(name: String, data: [String: String]?) async {
        // `is_subscriber` sur **tous** les events sans exception : c'est ce qui
        // rend n'importe quelle métrique segmentable abonné / non-abonné. Ajouté
        // ici plutôt que chez les appelants pour qu'un nouvel event ne puisse pas
        // l'oublier. Un event déjà porteur d'une clé `is_subscriber` explicite
        // n'est pas écrasé (aucun aujourd'hui, garde-fou de parité).
        var eventData = data ?? [:]
        if eventData["is_subscriber"] == nil {
            eventData["is_subscriber"] = isSubscriber ? "true" : "false"
        }

        // Un event émis avant tout écran (ex. `app_first_open` au lancement) se
        // rattache à la racine plutôt que de partir sans `url`.
        await send(url: currentPath ?? "/", title: currentTitle, name: name, data: eventData)
    }

    /// Statut abonné du compte courant, relu à **chaque** event.
    ///
    /// Source : le cache `UserDefaults` d'`AuthService`, alimenté par
    /// `/180c/v1/me` (`is_subscriber`) — la vérité serveur — et non par un claim
    /// du JWT, que le plugin d'auth ne garantit pas. Lecture directe de la clé
    /// partagée plutôt qu'un accès à `AuthService` : cet acteur n'est pas isolé
    /// sur le main actor, et un hit analytics ne doit jamais y sauter.
    ///
    /// Clé absente → `false`. C'est l'état voulu pour un visiteur comme après
    /// `logout()`, qui la supprime. Après un force-quit la clé persiste : le
    /// compte reste taggé abonné jusqu'à la déconnexion ou la prochaine
    /// vérification serveur — comportement assumé.
    private var isSubscriber: Bool {
        UserDefaults.standard.bool(forKey: AuthService.isSubscriberDefaultsKey)
    }

    // MARK: - Envoi

    private func send(url: String, title: String, name: String?, data: [String: String]?) async {
        let device = await deviceInfo()

        let envelope = Envelope(payload: Payload(
            website: Self.websiteID,
            hostname: Self.hostname,
            tag: Self.tag,
            language: device.language,
            screen: device.screen,
            url: url,
            title: title,
            referrer: previousPath,
            name: name,
            data: data
        ))

        guard let body = try? JSONEncoder().encode(envelope) else { return }

        guard Self.isEnabled else {
            // Les propriétés sont journalisées ici parce que c'est le **seul**
            // moyen de vérifier un payload en DEBUG : rien ne part sur le réseau,
            // donc rien n'est inspectable côté Umami. Valeurs texte non
            // personnelles uniquement (cf. en-tête de fichier).
            let properties = (data ?? [:])
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            AppLogger.data.debug(
                "[Umami] DEBUG — hit non envoyé : \(name ?? "pageview", privacy: .public) url=\(url, privacy: .public) \(properties, privacy: .public)"
            )
            return
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(device.userAgent, forHTTPHeaderField: "User-Agent")
        if let cacheToken {
            request.setValue(cacheToken, forHTTPHeaderField: "x-umami-cache")
        }
        request.httpBody = body

        do {
            let (responseData, _) = try await Self.session.data(for: request)
            if let token = Self.cacheToken(from: responseData) {
                cacheToken = token
            }
        } catch {
            // Échec silencieux, par contrat : pas de retry agressif, pas de file
            // persistante, aucune remontée UI. En mode avion on perd le hit.
        }
    }

    /// Métadonnées device, résolues à la demande puis mémorisées.
    private func deviceInfo() async -> UmamiDevice {
        if let device { return device }
        let resolved = await MainActor.run { UmamiDevice.current() }
        device = resolved
        return resolved
    }

    /// Extrait le jeton de session de la réponse. Umami rend selon les versions
    /// un objet `{"cache":"…"}`, une chaîne JSON entre guillemets, ou le jeton
    /// brut : les trois formes sont acceptées, tout le reste est ignoré.
    private static func cacheToken(from data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = object["cache"] as? String,
           !token.isEmpty {
            return token
        }

        var raw = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count > 2 {
            raw = String(raw.dropFirst().dropLast())
        }
        // Garde-fou : un corps vide, un `ok` ou un JSON sans champ `cache` ne
        // sont pas des jetons — les renvoyer en header ferait rejeter les hits.
        guard raw.count > 8, !raw.hasPrefix("{"), !raw.hasPrefix("[") else { return nil }
        return raw
    }

    // MARK: - Corps de requête

    private struct Envelope: Encodable {
        let type = "event"
        let payload: Payload
    }

    /// Les champs optionnels absents ne sont pas encodés (`JSONEncoder` omet les
    /// `nil`) : une page vue part donc bien **sans** clé `name`.
    private struct Payload: Encodable {
        let website: String
        let hostname: String
        let tag: String
        let language: String
        let screen: String
        let url: String
        let title: String
        let referrer: String
        let name: String?
        let data: [String: String]?
    }
}
