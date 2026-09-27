import Foundation
import UIKit
import UserNotifications
import Combine

@MainActor
final class NotificationManager: ObservableObject {
    static let shared = NotificationManager()

    @Published var isAuthorized = false
    @Published var isDenied = false
    /// Abonnement push OneSignal actif (miroir de `pushSubscription.optedIn`),
    /// rafraîchi à la demande par `checkStatus()`.
    @Published var isOptedIn = false
    @Published var notifications: [AppNotification] = []
    @Published var loadState: NotificationsLoadState = .idle

    /// Nombre de notifications non lues (source de la pastille + du badge app).
    var unreadCount: Int { notifications.filter { !$0.isRead }.count }

    /// Abonnement push **effectif** : autorisation système accordée ET abonnement
    /// OneSignal actif. Source unique de vérité pour la pastille de la cloche et le
    /// bandeau inline. `isOptedIn` intègre déjà la joignabilité côté SDK ; le terme
    /// `isAuthorized` reste un garde défensif calé sur la vérité iOS immédiate
    /// (`UNUserNotificationCenter`), face à une éventuelle latence de propagation
    /// d'OneSignal.
    var pushEffectivelyEnabled: Bool { isAuthorized && isOptedIn }

    private let repository = NotificationsRepository()
    private let readIDsKey = "readNotificationIDs.v2"
    private var readIDs: Set<Int> = []
    private var page = 1
    private var canLoadMore = true

    init() {
        readIDs = Self.loadReadIDs(key: readIDsKey)
        // Affichage optimiste depuis le cache disque (hors-ligne).
        notifications = applyRead(repository.loadCache())
        checkStatus()
        updateBadge()

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // L'observateur est livré sur la file principale (queue: .main).
            MainActor.assumeIsolated {
                self?.checkStatus()
                self?.updateBadge()
            }
        }
    }

    // MARK: - Permission système

    func checkStatus() {
        Task { @MainActor in
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            self.isAuthorized = status == .authorized
            self.isDenied = status == .denied
            // Lecture à la demande de l'abonnement OneSignal (pas d'observer) :
            // cohérent avec le refresh appear + willEnterForeground.
            self.isOptedIn = PushPermissionCoordinator.shared.isOptedIn
        }
    }

    /// Bascule l'abonnement push depuis Mon compte, selon la matrice de recette.
    /// iOS interdit de révoquer l'autorisation depuis l'app : ce contrôle pilote
    /// **l'abonnement OneSignal**, jamais la permission système.
    /// - `.notDetermined` : prompt système, puis opt-in **seulement** si accordé.
    ///   Le prompt passe par `requestSystemPermission()` (et non `optIn()` nu) pour
    ///   poser `hasSystemPromptBeenShown` et éviter un double prompt.
    /// - `.authorized` / `.provisional` : opt-in ou opt-out selon `enabled`.
    /// - `.denied` : ouverture des Réglages (le toggle est désactivé ; garde-fou).
    func setPushSubscription(enabled: Bool) async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        switch status {
        case .notDetermined:
            let granted = await PushPermissionCoordinator.shared.requestSystemPermission()
            if granted { PushPermissionCoordinator.shared.optIn() }
        case .authorized, .provisional, .ephemeral:
            if enabled {
                PushPermissionCoordinator.shared.optIn()
            } else {
                PushPermissionCoordinator.shared.optOut()
            }
        case .denied:
            PushPermissionCoordinator.shared.openSystemSettings()
        @unknown default:
            break
        }
        checkStatus()
    }

    /// CTA d'activation (écran vide **et** bandeau inline) : jamais de soft ask
    /// ici — l'utilisateur vient explicitement activer. Trois cas :
    /// - `.notDetermined` : prompt système, puis opt-in **si accordé**.
    /// - `.authorized` / `.provisional` / `.ephemeral` : permission déjà là mais
    ///   abonnement OneSignal coupé (opt-out depuis Mon compte) → opt-in **direct**,
    ///   sans prompt. C'est ce qui rend le bouton « Activer » du bandeau opérant
    ///   pour un utilisateur autorisé-mais-désabonné.
    /// - `.denied` : ouverture des Réglages iOS.
    /// Après opt-in, `checkStatus()` rafraîchit l'état → `pushEffectivelyEnabled`
    /// repasse à vrai et le bandeau disparaît.
    func handleActivationCTA() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        switch status {
        case .notDetermined:
            let granted = await PushPermissionCoordinator.shared.requestSystemPermission()
            if granted { PushPermissionCoordinator.shared.optIn() }
        case .authorized, .provisional, .ephemeral:
            PushPermissionCoordinator.shared.optIn()
        case .denied:
            PushPermissionCoordinator.shared.openSystemSettings()
        @unknown default:
            break
        }
        checkStatus()
    }

    /// Ligne « Notifications » de Mon compte : prompt système si `.notDetermined`,
    /// sinon ouverture des Réglages iOS (activées comme désactivées).
    func openNotificationSettings() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = await PushPermissionCoordinator.shared.requestSystemPermission()
        } else {
            PushPermissionCoordinator.shared.openSystemSettings()
        }
        checkStatus()
    }

    // MARK: - Feed

    func loadInitial() async {
        guard loadState != .loading else { return }
        loadState = .loading
        do {
            let items = try await repository.fetch(page: 1)
            page = 1
            canLoadMore = items.count >= repository.perPage
            notifications = applyRead(items)
            repository.saveCache(items)
            loadState = .loaded
            updateBadge()
        } catch {
            // Le cache déjà affiché reste ; on ne signale l'erreur que s'il est vide.
            loadState = notifications.isEmpty ? .failed : .loaded
        }
    }

    func refresh() async {
        await loadInitial()
    }

    /// Pagination : charge la page suivante quand la dernière ligne apparaît.
    func loadMoreIfNeeded(current item: AppNotification) async {
        guard canLoadMore, loadState == .loaded, item.id == notifications.last?.id else { return }
        do {
            let items = try await repository.fetch(page: page + 1)
            page += 1
            canLoadMore = items.count >= repository.perPage
            let existing = Set(notifications.map { $0.id })
            notifications.append(contentsOf: applyRead(items).filter { !existing.contains($0.id) })
            repository.saveCache(notifications)
        } catch {
            // Échec silencieux : on garde la liste courante.
        }
    }

    // MARK: - État lu / non lu

    func markAsRead(_ id: Int) {
        guard !readIDs.contains(id) else { return }
        readIDs.insert(id)
        if let idx = notifications.firstIndex(where: { $0.id == id }) {
            notifications[idx].isRead = true
        }
        persistReadIDs()
        updateBadge()
    }

    func markAllAsRead() {
        for i in notifications.indices { notifications[i].isRead = true }
        readIDs.formUnion(notifications.map { $0.id })
        persistReadIDs()
        updateBadge()
    }

    // MARK: - Badge de l'icône app

    func updateBadge() {
        UNUserNotificationCenter.current().setBadgeCount(unreadCount)
    }

    // MARK: - Helpers

    private func applyRead(_ items: [AppNotification]) -> [AppNotification] {
        items.map { item in
            var copy = item
            copy.isRead = readIDs.contains(item.id)
            return copy
        }
    }

    private func persistReadIDs() {
        UserDefaults.standard.set(Array(readIDs), forKey: readIDsKey)
    }

    private static func loadReadIDs(key: String) -> Set<Int> {
        Set(UserDefaults.standard.array(forKey: key) as? [Int] ?? [])
    }
}
