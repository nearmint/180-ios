//
//  NotificationRouter.swift
//  180
//
//  Route les taps de notification (push OU ligne du feed) vers la bonne
//  destination. Une seule fonction de décision, alimentée par deux adaptateurs
//  (additionalData d'un push / objet `target` du feed) — pas deux chemins.
//

import Foundation
import Combine
import OneSignalFramework
import os

enum NotificationDestination: Equatable {
    case recipe(Int)
    case article(Int)
    case url(URL)
    /// Page produit à ouvrir en **webview authentifiée** (réutilise l'amorçage
    /// `WebSession.prime`). Distinct de `.url` : `.url` ouvre un lien quelconque
    /// (potentiellement hors domaine) sans garantie de session ; `.product`
    /// exige une URL du site et passe par l'amorçage. `url` est déjà normalisée
    /// sur le domaine canonique (cf. `productDestination`).
    case product(id: Int, url: URL)
    case none
}

@MainActor
final class NotificationRouter: NSObject, ObservableObject {
    static let shared = NotificationRouter()

    /// Destination en attente d'application par la hiérarchie de vues (ContentView).
    /// Mémorisée jusqu'à ce que l'UI soit prête (gère le cold start).
    @Published var pendingDestination: NotificationDestination?

    private override init() { super.init() }

    /// Enregistre le listener de clic OneSignal (appelé à l'init du service push).
    func registerClickListener() {
        OneSignal.Notifications.addClickListener(self)
    }

    /// Demande le routage vers une destination. `.none` déclenche l'ouverture du
    /// centre de notifications (jamais de crash).
    func route(to destination: NotificationDestination) {
        pendingDestination = destination
    }

    // MARK: - Décision unique

    /// Fonction de parsing UNIQUE : décide la destination à partir des champs bruts.
    nonisolated static func destination(type: String, id: Int, url: String?) -> NotificationDestination {
        switch type {
        case "recipe":  return id > 0 ? .recipe(id) : .none
        case "article": return id > 0 ? .article(id) : .none
        case "url":     return url.flatMap(URL.init(string:)).map { .url($0) } ?? .none
        case "product": return productDestination(id: id, url: url)
        default:        return .none
        }
    }

    /// Destination produit **défensive**. L'URL doit être présente, absolue, et
    /// **dans le domaine du site** (`webBaseURL`) — sinon `.none` (repli centre
    /// de notifications, jamais de crash). Le host est forcé sur le domaine
    /// canonique : une URL apex (`180c.fr`) verrait sinon son POST d'amorçage
    /// dégradé par le 301 apex→www, vidant le token du corps.
    nonisolated private static func productDestination(id: Int, url: String?) -> NotificationDestination {
        guard let raw = url,
              var comps = URLComponents(string: raw),
              let host = comps.host,
              let canonical = URLComponents(string: APIConfig.shared.webBaseURL),
              let canonicalHost = canonical.host,
              isSameSite(host, canonicalHost)
        else { return .none }

        // Reconstruit l'URL sur le host canonique (force `www` en prod).
        comps.scheme = canonical.scheme
        comps.host = canonicalHost
        comps.port = canonical.port
        guard let normalized = comps.url else { return .none }
        return .product(id: id, url: normalized)
    }

    /// Deux hosts appartiennent-ils au même site ? Compare en ignorant un
    /// préfixe `www.` et la casse : `180c.fr`, `www.180c.fr` et `180c.local`
    /// sont acceptés selon l'environnement ; tout autre host (sous-domaine,
    /// tiers) est rejeté.
    nonisolated private static func isSameSite(_ a: String, _ b: String) -> Bool {
        func core(_ h: String) -> String {
            let lower = h.lowercased()
            return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
        }
        return core(a) == core(b)
    }

    /// Adaptateur : objet `target` typé du feed.
    nonisolated static func destination(for target: AppNotification.Target) -> NotificationDestination {
        destination(type: target.type, id: target.id, url: target.url)
    }

    /// Adaptateur : `additionalData` d'un push (plat, ou imbriqué sous
    /// `target`/`custom_data` selon le mapping OneSignal).
    nonisolated static func destination(fromPush data: [AnyHashable: Any]?) -> NotificationDestination {
        let dict = normalize(data)
        let type = dict["type"] as? String ?? "none"
        let id = intValue(dict["id"]) ?? 0
        let url = dict["url"] as? String
        return destination(type: type, id: id, url: url)
    }

    // MARK: - Helpers

    nonisolated private static func normalize(_ data: [AnyHashable: Any]?) -> [AnyHashable: Any] {
        guard let data else { return [:] }
        if let target = data["target"] as? [AnyHashable: Any] { return target }
        if let custom = data["custom_data"] as? [AnyHashable: Any] { return custom }
        return data
    }

    nonisolated private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}

extension NotificationRouter: OSNotificationClickListener {
    nonisolated func onClick(event: OSNotificationClickEvent) {
        // Parsing pur (sans acteur) ; seule la destination Sendable traverse.
        let destination = NotificationRouter.destination(fromPush: event.notification.additionalData)

        // `push_open` : nom de template OneSignal en priorité (c'est la
        // « campagne » au sens dashboard), sinon le titre affiché, sinon l'id du
        // message. Aucun des trois n'est une donnée personnelle.
        let campaign = event.notification.templateName
            ?? event.notification.title
            ?? event.notification.notificationId
        UmamiTracker.shared.trackEvent(
            name: "push_open",
            data: campaign.map { ["campaign": $0] }
        )
        Task { @MainActor in
            self.route(to: destination)
            await NotificationManager.shared.refresh()
        }
    }
}
