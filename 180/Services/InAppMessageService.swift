//
//  InAppMessageService.swift
//  180
//
//  In-App Messages OneSignal : enregistrement des listeners, routage des clics
//  vers les destinations natives de l'app et exposition des déclencheurs
//  (triggers) utilisables comme conditions d'audience dans le dashboard.
//
//  Le module `OneSignalInAppMessages` doit être lié à la cible (dépendance SPM) :
//  sans lui, le SDK 5 retombe sur `OSStubInAppMessages` et tous les appels ci-
//  dessous deviennent des no-op silencieux.
//

import Foundation
import OneSignalFramework
import os

@MainActor
final class InAppMessageService: NSObject {
    static let shared = InAppMessageService()

    private var isRegistered = false

    private override init() { super.init() }

    /// Enregistre les listeners de clic et de cycle de vie. Appelé une seule
    /// fois, depuis `PushNotificationService.initialize` (après
    /// `OneSignal.initialize`).
    func register() {
        guard !isRegistered else { return }
        isRegistered = true

        OneSignal.InAppMessages.addClickListener(self)
        OneSignal.InAppMessages.addLifecycleListener(self)
    }

    // MARK: - Déclencheurs (triggers)

    /// Les triggers sont évalués **localement** par le SDK : ils servent de
    /// conditions d'audience côté dashboard sans aller-retour serveur.
    func setTrigger(_ key: String, _ value: String) {
        OneSignal.InAppMessages.addTrigger(key, withValue: value)
    }

    func removeTrigger(_ key: String) {
        OneSignal.InAppMessages.removeTrigger(key)
    }

    /// Reflète l'état utilisateur courant en triggers, en miroir des tags posés
    /// par `PushNotificationService.applyTags()`. Les tags ciblent les push
    /// (côté serveur), ces triggers ciblent les IAM (côté client) : il faut les
    /// deux pour qu'un message dashboard puisse viser « abonné » ou « visiteur ».
    func syncStateTriggers() {
        setTrigger("logged_in", AuthService.shared.isLoggedIn ? "true" : "false")
        setTrigger("subscription_status", AuthService.shared.isSubscriber ? "active" : "none")
        setTrigger("env", AppEnvironment.current.rawValue)
        setTrigger("app_version", PushNotificationService.appVersion)
    }

    // MARK: - Pause

    /// Suspend l'affichage des IAM. Levier disponible pour les moments où une
    /// interruption serait néfaste (mise à jour forcée, onboarding, lecture d'une
    /// recette) — non activé par défaut.
    var isPaused: Bool {
        get { OneSignal.InAppMessages.paused }
        set { OneSignal.InAppMessages.paused = newValue }
    }

    // MARK: - Décision de routage

    /// Traduit l'`actionId` d'un bouton d'IAM en destination native.
    ///
    /// Deux formes sont acceptées, toutes deux réduites au triplet
    /// `type`/`id`/`url` de `NotificationRouter` (fonction de décision unique,
    /// partagée avec les push) :
    ///
    /// - abrégée — `recipe:123`, `article:456`, `url:https://…`
    /// - requête — `type=product&id=45&url=https%3A%2F%2Fwww.180c.fr%2Fboutique`
    ///   (seule forme capable de porter à la fois un id et une URL, requise par
    ///   le type `product`)
    ///
    /// Un `actionId` vide ou non reconnu renvoie `.none` : contrairement au tap
    /// sur un push, l'appelant **n'ouvre alors rien** (cf. `onClick`). Un bouton
    /// d'IAM sans intention de navigation ne doit pas éjecter l'utilisateur vers
    /// le centre de notifications.
    nonisolated static func destination(fromActionID actionId: String?) -> NotificationDestination {
        let raw = (actionId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .none }

        // Forme requête. `URLComponents` gère le décodage percent des valeurs,
        // indispensable pour transporter une URL en paramètre.
        if raw.contains("="),
           let items = URLComponents(string: "?\(raw)")?.queryItems {
            let fields = Dictionary(items.map { ($0.name, $0.value ?? "") },
                                    uniquingKeysWith: { _, last in last })
            if let type = fields["type"] {
                return NotificationRouter.destination(
                    type: type.lowercased(),
                    id: Int(fields["id"] ?? "") ?? 0,
                    url: fields["url"]
                )
            }
        }

        // Forme abrégée. Découpe sur le **premier** `:` seulement, pour ne pas
        // tronquer le schéma d'une URL (`url:https://…`).
        guard let separator = raw.firstIndex(of: ":") else { return .none }
        let type = raw[raw.startIndex..<separator].lowercased()
        let value = String(raw[raw.index(after: separator)...])
        return NotificationRouter.destination(type: type, id: Int(value) ?? 0, url: value)
    }
}

// MARK: - Clic

extension InAppMessageService: OSInAppMessageClickListener {
    nonisolated func onClick(event: OSInAppMessageClickEvent) {
        // Parsing pur (hors acteur) ; seule la destination Sendable traverse.
        let actionId = event.result.actionId
        let destination = InAppMessageService.destination(fromActionID: actionId)
        let messageId = event.message.messageId

        AppLogger.notif.info(
            "[IAM] clic message=\(messageId, privacy: .public) action=\(actionId ?? "—", privacy: .public)"
        )

        Task { @MainActor in
            AnalyticsService.inAppMessageClicked(id: messageId, actionId: actionId)
            // `.none` = bouton sans intention de navigation (fermeture, lien
            // ouvert par le SDK lui-même via `urlTarget`). On ne route pas.
            guard destination != .none else { return }
            NotificationRouter.shared.route(to: destination)
        }
    }
}

// MARK: - Cycle de vie

extension InAppMessageService: OSInAppMessageLifecycleListener {
    nonisolated func onDidDisplay(event: OSInAppMessageDidDisplayEvent) {
        let messageId = event.message.messageId
        AppLogger.notif.info("[IAM] affiché message=\(messageId, privacy: .public)")
        Task { @MainActor in
            AnalyticsService.inAppMessageDisplayed(id: messageId)
        }
    }

    nonisolated func onDidDismiss(event: OSInAppMessageDidDismissEvent) {
        AppLogger.notif.debug("[IAM] fermé message=\(event.message.messageId, privacy: .public)")
    }
}
