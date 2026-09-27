//
//  PushPermissionCoordinator.swift
//  180
//
//  Pilote l'opt-in notifications de façon non intrusive. Le prompt système iOS
//  n'est présentable qu'UNE fois dans la vie de l'installation : toute la logique
//  vise à ne le déclencher qu'au moment de plus forte probabilité d'acceptation.
//

import Foundation
import UIKit
import UserNotifications
import OneSignalFramework
import os

/// Points de déclenchement d'un « soft ask » (pré-demande maison).
enum SoftAskTrigger {
    case firstFavorite
    case thirdLaunch
}

@MainActor
final class PushPermissionCoordinator {
    static let shared = PushPermissionCoordinator()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let promptShown = "push.hasSystemPromptBeenShown"
        static let declineCount = "push.softAskDeclineCount"
        static let lastSoftAsk = "push.lastSoftAskDate"
    }

    /// Fenêtre de rappel minimale entre deux soft asks.
    private let cooldown: TimeInterval = 30 * 24 * 60 * 60

    /// Réinitialisé à chaque lancement (état en mémoire).
    private var sessionSoftAskShown = false

    /// Vrai tant qu'une recette est en cours de lecture (posé par la vue détail).
    /// Un soft ask ne doit jamais interrompre une lecture.
    var isRecipeReadingInProgress = false

    private init() {}

    // MARK: - État persisté

    private(set) var hasSystemPromptBeenShown: Bool {
        get { defaults.bool(forKey: Key.promptShown) }
        set { defaults.set(newValue, forKey: Key.promptShown) }
    }

    private var softAskDeclineCount: Int {
        get { defaults.integer(forKey: Key.declineCount) }
        set { defaults.set(newValue, forKey: Key.declineCount) }
    }

    private var lastSoftAskDate: Date? {
        get { defaults.object(forKey: Key.lastSoftAsk) as? Date }
        set { defaults.set(newValue, forKey: Key.lastSoftAsk) }
    }

    /// Vrai si un soft ask a déjà été présenté au moins une fois (persistant).
    var hasEverShownSoftAsk: Bool { lastSoftAskDate != nil }

    // MARK: - Décision

    /// Autorise l'affichage d'un soft ask uniquement si TOUTES les conditions
    /// sont réunies : autorisation `.notDetermined`, moins de 2 refus, aucun soft
    /// ask déjà montré dans la session, dernier soft ask absent ou > 30 j, et
    /// aucune lecture de recette en cours.
    func shouldShowSoftAsk(for trigger: SoftAskTrigger) async -> Bool {
        _ = trigger // même politique pour tous les déclencheurs (anti-fatigue commun).

        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard status == .notDetermined else { return false }
        guard softAskDeclineCount < 2 else { return false }
        guard !sessionSoftAskShown else { return false }
        if let last = lastSoftAskDate, Date().timeIntervalSince(last) < cooldown {
            return false
        }
        guard !isRecipeReadingInProgress else { return false }
        return true
    }

    /// À appeler à la présentation du sheet : marque la session et horodate.
    func markSoftAskShown() {
        sessionSoftAskShown = true
        lastSoftAskDate = Date()
    }

    /// « Plus tard » : incrémente le compteur de refus et réarme le cooldown.
    /// Au 2ᵉ refus, plus aucun soft ask ne réapparaîtra.
    func registerSoftAskDeclined() {
        softAskDeclineCount += 1
        lastSoftAskDate = Date()
    }

    // MARK: - Prompt système

    /// Déclenche le prompt système iOS via OneSignal. Le fallback Réglages du SDK
    /// est **désactivé** : on gère nous-mêmes l'ouverture des Réglages.
    @discardableResult
    func requestSystemPermission() async -> Bool {
        hasSystemPromptBeenShown = true
        let accepted: Bool = await withCheckedContinuation { continuation in
            OneSignal.Notifications.requestPermission({ accepted in
                continuation.resume(returning: accepted)
            }, fallbackToSettings: false)
        }
        // Point de mesure UNIQUE de l'opt-in : tous les chemins (soft ask, toggle
        // Mon compte, CTA d'activation, ligne Réglages) passent par ici.
        UmamiTracker.shared.trackEvent(name: "push_optin", data: ["accepted": accepted ? "true" : "false"])
        return accepted
    }

    /// Ouvre les Réglages iOS de l'app (cas `.denied`).
    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Abonnement OneSignal (opt-in / opt-out)

    /// État d'abonnement push de l'utilisateur courant, lu à la demande (aucun
    /// observer). Côté SDK, `optedIn == reachable && !isDisabled` : il **intègre
    /// déjà** l'état de permission (cf. `OSSubscriptionModel.calculateIsOptedIn`).
    var isOptedIn: Bool {
        OneSignal.User.pushSubscription.optedIn
    }

    /// Réactive l'abonnement push. À n'appeler qu'avec une permission **déjà
    /// accordée** : `optIn()` re-déclenche sinon le prompt système
    /// (`requestPermission(fallbackToSettings:)` en interne), ce qui doublonnerait
    /// `requestSystemPermission()`. Le chemin `.notDetermined` prompte donc
    /// d'abord, puis n'appelle `optIn()` qu'en cas d'acceptation.
    func optIn() {
        OneSignal.User.pushSubscription.optIn()
    }

    /// Désabonne l'utilisateur **sans toucher à l'autorisation système** (iOS
    /// interdit de la révoquer depuis l'app). Le device cesse de recevoir les push.
    func optOut() {
        OneSignal.User.pushSubscription.optOut()
    }
}
