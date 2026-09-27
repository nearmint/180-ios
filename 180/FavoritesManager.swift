import Foundation
import Combine
import FirebaseAnalytics
import os

// MARK: - Favorites Manager
//
// Carnet synchronisé serveur (180c/v1/favorites) avec cache local hors-ligne.
// - Source de vérité : le serveur quand l'utilisateur est connecté.
// - `UserDefaults` (clé `favorite_recipe_ids`) = cache offline / lecture optimiste,
//   plus la source unique (état conservé hors-ligne et pour les visiteurs).

@MainActor
final class FavoritesManager: ObservableObject {
    static let shared = FavoritesManager()

    @Published var favoriteIDs: Set<Int> = []

    /// Émis lorsqu'un favori est ajouté par une **action utilisateur** (jamais lors
    /// d'un sync serveur). Consommé par `PushSoftAskPresenter` (point d'entrée 1)
    /// et par `OfflineSyncService` (téléchargement immédiat de la fiche).
    let didAddFavorite = PassthroughSubject<Int, Never>()

    /// Miroir de `didAddFavorite` pour le retrait. Consommé par
    /// `OfflineSyncService`, qui supprime la fiche locale sans attendre la
    /// prochaine réconciliation — le carnet hors ligne doit refléter le geste
    /// de l'utilisateur immédiatement, y compris sans réseau.
    let didRemoveFavorite = PassthroughSubject<Int, Never>()

    private let key = "favorite_recipe_ids"

    init() {
        load()
    }

    private var isLoggedIn: Bool {
        AuthService.shared.getToken() != nil
    }

    /// - Parameter slug: slug WordPress de la recette, utilisé comme `recipe_id`
    ///   dans l'event Umami `recipe_favorite` (le web raisonne en slugs). Repli
    ///   sur l'identifiant numérique quand il est absent.
    func toggle(_ recipeID: Int, title: String = "", slug: String? = nil) {
        // Le carnet est un service de compte : hors session il n'y a pas de
        // destinataire pour ce favori. L'UI désactive déjà le bouton
        // (`FavoriteGate`) ; ce garde-fou couvre les autres chemins d'appel.
        guard isLoggedIn else { return }

        let isAdding = !favoriteIDs.contains(recipeID)
        if isAdding {
            favoriteIDs.insert(recipeID)
            AnalyticsService.addFavorite(id: recipeID, title: title)
            // Seul l'AJOUT est mesuré côté Umami (pas le retrait), par parité
            // avec le web et Android.
            UmamiTracker.shared.trackEvent(name: "recipe_favorite", data: [
                "recipe_id": slug ?? String(recipeID)
            ])
            didAddFavorite.send(recipeID)
        } else {
            favoriteIDs.remove(recipeID)
            AnalyticsService.removeFavorite(id: recipeID, title: title)
            didRemoveFavorite.send(recipeID)
        }
        Haptics.light()
        save() // cache local optimiste

        // Propagation serveur best-effort si connecté ; en cas d'échec on garde
        // l'état local, réconcilié au prochain sync.
        guard isLoggedIn else { return }
        Task {
            do {
                if isAdding {
                    try await APIService.shared.addFavorite(recipeID)
                } else {
                    try await APIService.shared.deleteFavorite(recipeID)
                }
            } catch {
                AppLogger.api.error("Sync favori \(recipeID) échouée: \(error)")
            }
        }
    }

    func isFavorite(_ recipeID: Int) -> Bool {
        favoriteIDs.contains(recipeID)
    }

    /// Rafraîchit depuis le serveur (au lancement, si connecté). Hors-ligne : on
    /// conserve le cache local.
    func refreshFromServer() async {
        guard isLoggedIn else { return }
        do {
            let ids = try await APIService.shared.fetchFavoriteIDs()
            favoriteIDs = Set(ids)
            save()
        } catch {
            AppLogger.api.error("Chargement favoris serveur échoué: \(error)")
        }
    }

    /// À la connexion : pousse les favoris locaux puis adopte l'état serveur
    /// réconcilié (union last-write-wins).
    func syncOnLogin() async {
        guard isLoggedIn else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        let items: [[String: Any]] = favoriteIDs.map { id in
            ["recipe_id": id, "favorited": true, "updated_at": now]
        }
        do {
            let ids = try await APIService.shared.syncFavorites(items)
            favoriteIDs = Set(ids)
            save()
        } catch {
            AppLogger.api.error("Sync favoris au login échouée: \(error)")
        }
    }

    /// Efface le carnet **local** (mémoire + `UserDefaults`), sans toucher au
    /// serveur. Appelé à la déconnexion.
    ///
    /// Sans cette purge, les IDs du compte A survivaient à la session : sur un
    /// appareil partagé, le login suivant les poussait dans le carnet du compte
    /// B via `syncOnLogin()` (union last-write-wins). Parité Android.
    func clearLocal() {
        favoriteIDs = []
        UserDefaults.standard.removeObject(forKey: key)
    }

    private func save() {
        UserDefaults.standard.set(Array(favoriteIDs), forKey: key)
    }

    private func load() {
        let array = UserDefaults.standard.array(forKey: key) as? [Int] ?? []
        favoriteIDs = Set(array)
    }
}
