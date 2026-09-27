//
//  PushNotificationService.swift
//  180
//
//  Point d'entrée unique OneSignal : initialisation, synchronisation d'identité
//  (external id = user id WordPress) et pose des tags. AUCUNE demande de
//  permission ici — l'opt-in est piloté par PushPermissionCoordinator.
//

import Foundation
import Combine
import UIKit
import OneSignalFramework
import os

/// Environnement de distribution, source du tag OneSignal `env` qui alimente les
/// segments dashboard `TestFlight` et `App Store`.
enum AppEnvironment: String {
    case debug
    case testflight
    case appstore

    /// Détection empirique : `#if DEBUG` → `debug` ; sinon la présence d'un reçu
    /// `sandboxReceipt` désigne un build TestFlight (APNs **production** mais reçu
    /// sandbox) ; sinon App Store.
    ///
    /// ⚠️ À valider au premier build TestFlight (cf. Phase 9, test n°10).
    ///
    /// ⚠️ ÉCART DÉPRÉCIATION (signalé au rapport) : `Bundle.main.appStoreReceiptURL`
    /// est déprécié depuis iOS 18 (deployment target = 26.2). Il reste néanmoins
    /// la seule API **synchrone et fiable** distinguant TestFlight d'App Store au
    /// runtime. L'alternative StoreKit 2 (`AppTransaction.shared.environment`) est
    /// asynchrone et sa sémantique TestFlight n'est pas garantie ; migration à
    /// décider après validation TestFlight. L'appel est confiné à
    /// `releaseEnvironment()`, annoté pour neutraliser l'avertissement.
    static var current: AppEnvironment {
        #if DEBUG
        return .debug
        #else
        return releaseEnvironment()
        #endif
    }

    @available(iOS, deprecated: 18.0, message: "appStoreReceiptURL déprécié — revalider une éventuelle migration StoreKit 2 après le premier TestFlight.")
    private static func releaseEnvironment() -> AppEnvironment {
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" ? .testflight : .appstore
    }
}

@MainActor
final class PushNotificationService {
    static let shared = PushNotificationService()

    private var cancellables = Set<AnyCancellable>()
    private var didWarnMissingUserID = false
    private var isInitialized = false

    private init() {}

    /// Valeur d'environnement calculée, exposée en lecture seule (constat debug).
    var environmentTag: String { AppEnvironment.current.rawValue }

    /// Version courte du bundle (tag `app_version`).
    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    /// Initialise OneSignal. Appelé une seule fois depuis
    /// `AppDelegate.didFinishLaunchingWithOptions`. Ne demande JAMAIS la
    /// permission (opt-in délégué à `PushPermissionCoordinator`).
    func initialize(launchOptions: [UIApplication.LaunchOptionsKey: Any]?) {
        let appId = APIConfig.shared.oneSignalAppId
        guard !appId.isEmpty else {
            AppLogger.data.error("[Push] OneSignalAppId absent de l'Info.plist — push désactivé.")
            return
        }
        guard !isInitialized else { return }
        isInitialized = true

        OneSignal.initialize(appId, withLaunchOptions: launchOptions)

        NotificationRouter.shared.registerClickListener()
        InAppMessageService.shared.register()
        applyTags()
        observeIdentity()
        syncExternalId()

        AppLogger.data.info("[Push] OneSignal initialisé — env=\(AppEnvironment.current.rawValue, privacy: .public)")
    }

    /// Observe l'identité/abonnement pour (dé)lier l'external id et rafraîchir les
    /// tags. Lecture seule des `@Published` d'`AuthService` — le flux d'auth
    /// n'est pas modifié.
    private func observeIdentity() {
        AuthService.shared.$isLoggedIn
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.syncExternalId()
                self?.applyTags()
            }
            .store(in: &cancellables)

        AuthService.shared.$userID
            .removeDuplicates()
            .sink { [weak self] _ in self?.syncExternalId() }
            .store(in: &cancellables)

        AuthService.shared.$isSubscriber
            .removeDuplicates()
            .sink { [weak self] _ in self?.applyTags() }
            .store(in: &cancellables)
    }

    /// Lie (`login`) ou délie (`logout`) l'external id OneSignal selon la session.
    /// Si le user id n'est pas encore servi par `/me`, on **n'appelle pas** login
    /// mais on garde les tags, avec un avertissement journalisé une seule fois.
    private func syncExternalId() {
        guard isInitialized else { return }

        guard AuthService.shared.isLoggedIn else {
            OneSignal.logout()
            return
        }

        if let id = AuthService.shared.userID {
            OneSignal.login(String(id))
        } else if !didWarnMissingUserID {
            didWarnMissingUserID = true
            AppLogger.data.error("[Push] user id absent de /180c/v1/me — login OneSignal ignoré (tags conservés). Ajouter `id` à la réponse /me.")
        }
    }

    /// (Re)pose les tags `env`, `subscription_status`, `app_version`, et reflète
    /// le même état en triggers IAM. Les tags ciblent les push (évalués côté
    /// serveur), les triggers ciblent les In-App Messages (évalués côté client) :
    /// les deux doivent bouger ensemble, d'où l'appel unique ici — le seul
    /// endroit d'où l'état utilisateur est déjà rediffusé à chaque changement.
    func applyTags() {
        guard isInitialized else { return }
        OneSignal.User.addTag(key: "env", value: AppEnvironment.current.rawValue)
        OneSignal.User.addTag(key: "subscription_status", value: AuthService.shared.isSubscriber ? "active" : "none")
        OneSignal.User.addTag(key: "app_version", value: Self.appVersion)
        InAppMessageService.shared.syncStateTriggers()
    }
}
