//
//  PushSoftAskPresenter.swift
//  180
//
//  Orchestre l'affichage du soft ask selon les points d'entrée (première mise en
//  favori, troisième lancement) et délègue la décision au coordinateur.
//

import Foundation
import Combine
import os

@MainActor
final class PushSoftAskPresenter: ObservableObject {
    static let shared = PushSoftAskPresenter()

    /// Pilote le `.sheet` attaché à la racine (ContentView).
    @Published var isShown = false

    private let coordinator = PushPermissionCoordinator.shared
    private var cancellables = Set<AnyCancellable>()
    private let launchCountKey = "push.launchCount"

    private init() {
        // Point d'entrée 1 : après une mise en favori (action utilisateur).
        FavoritesManager.shared.didAddFavorite
            .sink { [weak self] _ in
                Task { await self?.maybePresent(.firstFavorite) }
            }
            .store(in: &cancellables)
    }

    /// Point d'entrée 2 : à appeler une fois au lancement. Au 3ᵉ lancement, si le
    /// soft ask n'a jamais été montré, tente de le présenter.
    func registerLaunchAndMaybePrompt() {
        let count = UserDefaults.standard.integer(forKey: launchCountKey) + 1
        UserDefaults.standard.set(count, forKey: launchCountKey)

        guard count >= 3, !coordinator.hasEverShownSoftAsk else { return }
        Task { await maybePresent(.thirdLaunch) }
    }

    private func maybePresent(_ trigger: SoftAskTrigger) async {
        guard await coordinator.shouldShowSoftAsk(for: trigger) else { return }
        coordinator.markSoftAskShown()
        isShown = true
    }

    /// « Activer les notifications » : ferme le sheet et déclenche le prompt système.
    func activate() {
        isShown = false
        Task { await coordinator.requestSystemPermission() }
    }

    /// « Plus tard » : enregistre le refus et ferme le sheet.
    func decline() {
        coordinator.registerSoftAskDeclined()
        isShown = false
    }
}
