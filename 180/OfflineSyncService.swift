import Foundation
import Combine
import Observation
import os

// MARK: - Planificateur de réconciliation (logique pure)

/// Diff entre l'état serveur du carnet et le contenu du store local.
///
/// Isolé du service pour être testable sans réseau ni disque : c'est la seule
/// pièce où une erreur se traduirait par du contenu manquant ou périmé.
enum OfflineSyncPlanner {

    struct Plan: Equatable {
        /// À télécharger, **dans l'ordre serveur** (favoris récents d'abord).
        var toDownload: [Int]
        /// À supprimer du disque (retirés du carnet, ou dépubliés).
        var toDelete: [Int]
        /// Déjà présents et à jour — aucun octet réseau.
        var upToDate: [Int]
    }

    /// Construit le plan d'un cycle de réconciliation.
    ///
    /// - Parameters:
    ///   - serverIDs: favoris du compte, ordre serveur (`created_at DESC`).
    ///   - serverModified: `[id: modified]` renvoyé par la sonde de fraîcheur.
    ///     Un ID absent = date indisponible (recette dépubliée, champ muet).
    ///   - local: métadonnées des fiches déjà sur disque.
    ///
    /// Règles, de la plus prioritaire à la moins :
    /// 1. Fiche locale absente du carnet serveur ⇒ **suppression**.
    /// 2. Favori sans fiche locale ⇒ **téléchargement** (couvre aussi la reprise
    ///    des échecs : un téléchargement raté n'écrit rien, donc reste absent).
    /// 3. Fiche locale sans jeton `modified` ⇒ **téléchargement** (fraîcheur
    ///    invérifiable : on ne conserve jamais du contenu qu'on ne sait pas dater).
    /// 4. Date serveur indisponible ⇒ **on garde** la version locale. Re-télécharger
    ///    à chaque cycle une fiche qu'on ne saura jamais comparer produirait une
    ///    boucle de téléchargement permanente.
    /// 5. Dates différentes ⇒ **téléchargement** ; identiques ⇒ rien.
    static func plan(
        serverIDs: [Int],
        serverModified: [Int: String],
        local: [OfflineRecipeMeta]
    ) -> Plan {
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let serverSet = Set(serverIDs)

        let toDelete = local
            .map(\.id)
            .filter { !serverSet.contains($0) }
            .sorted()

        var toDownload: [Int] = []
        var upToDate: [Int] = []

        // Ordre serveur préservé, doublons neutralisés.
        var seen = Set<Int>()
        for id in serverIDs where seen.insert(id).inserted {
            guard let meta = localByID[id] else {
                toDownload.append(id)          // règle 2
                continue
            }
            guard let localModified = meta.modified else {
                toDownload.append(id)          // règle 3
                continue
            }
            guard let remoteModified = serverModified[id] else {
                upToDate.append(id)            // règle 4
                continue
            }
            if localModified == remoteModified {
                upToDate.append(id)            // règle 5
            } else {
                toDownload.append(id)          // règle 5
            }
        }

        return Plan(toDownload: toDownload, toDelete: toDelete, upToDate: upToDate)
    }
}

// MARK: - Service de synchronisation

/// Téléchargement et maintien à jour des fiches du carnet consultables hors ligne.
///
/// ## Cycle de vie
///
/// - **Activation du toggle** : cycle complet (liste serveur → sonde → diff →
///   téléchargement séquentiel), progression observable.
/// - **Incrémental** : un favori ajouté est téléchargé aussitôt, un favori
///   retiré est supprimé aussitôt (y compris hors ligne, cf. `didRemoveFavorite`).
/// - **Réconciliation** au lancement, si en ligne et toggle actif.
///
/// ## Garde-fous
///
/// - **Éligibilité revérifiée au démarrage de chaque cycle** : logué *et* abonné.
///   Ce n'est pas qu'une règle produit — le serveur retire ingrédients et étapes
///   des recettes verrouillées (`recipe_locked`), donc une fiche téléchargée hors
///   abonnement serait une coquille vide. Une fiche verrouillée est d'ailleurs
///   refusée à l'écriture, même si tout le reste passait.
/// - **Jamais bloquant** : tout se joue dans une tâche d'arrière-plan annulable ;
///   un échec individuel ne vide pas la file, il sera repris au cycle suivant
///   (la fiche non écrite réapparaît en « absente » dans le plan).
@MainActor
@Observable
final class OfflineSyncService {

    static let shared = OfflineSyncService()

    /// Clé du toggle « Recettes hors ligne » (écran Mon compte).
    static let enabledKey = "offline_recipes_enabled"

    enum SyncState: Equatable {
        case idle
        /// Cycle en cours : `done` fiches traitées sur `total`.
        case running(done: Int, total: Int)
    }

    /// Toggle utilisateur. Persisté, remis à `false` à la déconnexion et à la
    /// perte d'abonnement.
    private(set) var isEnabled: Bool

    private(set) var state: SyncState = .idle

    /// Taille occupée, rafraîchie après chaque cycle et à la demande de l'UI.
    private(set) var cacheSizeBytes: Int64 = 0

    @ObservationIgnored private let store: OfflineStore
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()

    init(store: OfflineStore = .shared) {
        self.store = store
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        observeFavorites()
    }

    // MARK: - Éligibilité

    /// Logué **et** abonné. Revérifié au démarrage de chaque cycle : un statut
    /// peut tomber pendant qu'une file de téléchargement s'écoule.
    private var isEligible: Bool {
        AuthService.shared.isLoggedIn && AuthService.shared.isSubscriber
    }

    /// `true` si la section « Recettes hors ligne » doit être visible.
    var isAvailable: Bool { isEligible }

    // MARK: - Toggle

    /// Bascule la fonctionnalité. `true` déclenche un cycle complet, `false`
    /// annule toute synchronisation en cours et purge le disque.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }

        if enabled {
            guard isEligible else { return }
            isEnabled = true
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
            startCycle()
        } else {
            isEnabled = false
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            purge()
        }
    }

    /// Annule la synchronisation et vide le store, sans toucher au toggle.
    /// (« Vider le cache » le remet à `false` de son côté via `setEnabled`.)
    func purge() {
        syncTask?.cancel()
        syncTask = nil
        state = .idle
        Task { [store] in
            await store.deleteAll()
            await MainActor.run { self.cacheSizeBytes = 0 }
        }
    }

    /// Purge **et** extinction du toggle : déconnexion, fin d'abonnement.
    func disableAndPurge() {
        isEnabled = false
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        purge()
    }

    /// Fin d'abonnement constatée lors d'un rafraîchissement **en ligne** du
    /// statut (`/180c/v1/me`).
    ///
    /// Jamais déclenché hors connexion : aucune horloge locale ne décide de la
    /// fin d'un abonnement, sans quoi un utilisateur à jour perdrait son carnet
    /// dans un train. L'information est donnée par un toast, pas par une alerte
    /// bloquante — l'utilisateur n'a rien à décider ici.
    func handleSubscriptionLost() {
        guard isEnabled else { return }   // rien de téléchargé : rien à dire
        disableAndPurge()
        ToastManager.shared.show(
            "Votre abonnement a pris fin : les recettes téléchargées ont été supprimées.",
            type: .info
        )
    }

    // MARK: - Déclencheurs

    /// Réconciliation au lancement (et au retour du réseau).
    func reconcileIfNeeded() {
        guard isEnabled, isEligible, NetworkMonitor.shared.isConnected else { return }
        startCycle()
    }

    /// Lance un cycle, en remplaçant celui éventuellement en cours.
    private func startCycle() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            await self?.runCycle()
            await MainActor.run { self?.syncTask = nil }
        }
    }

    /// Recalcule la taille occupée (écran Mon compte).
    func refreshCacheSize() {
        Task { [store] in
            let size = await store.totalSizeBytes()
            await MainActor.run { self.cacheSizeBytes = size }
        }
    }

    // MARK: - Synchronisation incrémentale

    private func observeFavorites() {
        FavoritesManager.shared.didAddFavorite
            .sink { [weak self] id in self?.favoriteAdded(id) }
            .store(in: &cancellables)

        FavoritesManager.shared.didRemoveFavorite
            .sink { [weak self] id in self?.favoriteRemoved(id) }
            .store(in: &cancellables)
    }

    private func favoriteAdded(_ id: Int) {
        guard isEnabled, isEligible, NetworkMonitor.shared.isConnected else { return }
        // Tâche isolée : elle ne doit ni annuler ni être annulée par un cycle
        // complet en cours.
        Task { [weak self] in
            await self?.download(id)
            self?.refreshCacheSize()
        }
    }

    private func favoriteRemoved(_ id: Int) {
        guard isEnabled else { return }
        // Aucune condition de réseau : retirer du disque est une opération locale,
        // et le carnet hors ligne doit refléter le geste immédiatement.
        Task { [store, weak self] in
            await store.delete(id)
            self?.refreshCacheSize()
        }
    }

    // MARK: - Cycle complet

    private func runCycle() async {
        guard isEnabled, isEligible, NetworkMonitor.shared.isConnected else { return }

        guard let serverIDs = try? await APIService.shared.fetchFavoriteIDs() else {
            AppLogger.data.error("[Offline] liste des favoris indisponible — cycle abandonné")
            return
        }

        // La sonde est un confort : si elle échoue, on considère toutes les dates
        // serveur inconnues (règle 4 → on conserve l'existant, on télécharge les
        // manquants). Jamais de purge sur une panne de sonde.
        let serverModified = (try? await APIService.shared.fetchRecipeModifiedDates(ids: serverIDs)) ?? [:]

        let plan = OfflineSyncPlanner.plan(
            serverIDs: serverIDs,
            serverModified: serverModified,
            local: store.allMetadata()
        )
        AppLogger.data.info(
            "[Offline] plan: \(plan.toDownload.count) à télécharger, \(plan.toDelete.count) à supprimer, \(plan.upToDate.count) à jour"
        )

        for id in plan.toDelete {
            await store.delete(id)
        }

        let total = plan.toDownload.count
        guard total > 0 else {
            state = .idle
            refreshCacheSize()
            return
        }

        state = .running(done: 0, total: total)
        for (offset, id) in plan.toDownload.enumerated() {
            if Task.isCancelled { break }
            // Le statut peut tomber pendant que la file s'écoule.
            guard isEligible else { break }
            await download(id)
            state = .running(done: offset + 1, total: total)
        }
        state = .idle
        refreshCacheSize()
    }

    // MARK: - Téléchargement d'une fiche

    /// Télécharge une fiche et ses visuels. Un échec est journalisé et **n'écrit
    /// rien** : la fiche restera « absente » et sera reprise au cycle suivant.
    private func download(_ id: Int) async {
        do {
            guard let recipe = try await APIService.shared.fetchRecipesByIDs([id]).first else {
                AppLogger.data.error("[Offline] recette \(id) introuvable côté serveur")
                return
            }

            // Filet de sécurité : une fiche verrouillée arrive sans ingrédients ni
            // étapes (gating serveur). L'écrire produirait un carnet hors ligne
            // rempli de coquilles vides.
            guard !recipe.isLocked else {
                AppLogger.data.error("[Offline] recette \(id) verrouillée — non téléchargée")
                return
            }

            var images: [URL: Data] = [:]
            for url in Self.imageURLs(in: recipe) {
                if Task.isCancelled { return }
                if let data = await Self.fetchImageData(url) {
                    images[url] = data
                }
            }

            await store.save(recipe, images: images)
        } catch {
            AppLogger.data.error("[Offline] téléchargement de \(id) échoué: \(APIError.from(error).localizedDescription)")
        }
    }

    /// Octets d'une image, ou `nil` si indisponible. Une image manquante
    /// n'empêche jamais l'enregistrement de la fiche.
    private static func fetchImageData(_ url: URL) async -> Data? {
        guard let (data, response) = try? await AppHTTP.session.data(from: url),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              !data.isEmpty else {
            return nil
        }
        return data
    }

    // MARK: - Extraction des visuels

    /// Visuels à embarquer pour une fiche : photo principale **puis** images
    /// éventuelles du contenu.
    ///
    /// Aujourd'hui le contenu n'en porte aucune — le rendu lit les champs ACF et
    /// le corps Gutenberg des recettes premium est tronqué côté serveur. La
    /// détection est donc **défensive** : coût nul tant qu'il n'y a rien à
    /// trouver, et la fonctionnalité ne se périme pas si l'éditorial ajoute un
    /// jour des visuels d'étapes.
    static func imageURLs(in recipe: Recipe) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []

        func append(_ candidate: String?) {
            guard let candidate, !candidate.isEmpty,
                  let url = URL(string: candidate),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  seen.insert(url.absoluteString).inserted else { return }
            out.append(url)
        }

        append(recipe.imageURL)

        var html = recipe.content?.rendered ?? ""
        html += recipe.recipeIntro ?? ""
        for step in recipe.steps ?? [] {
            html += step.stepContent
        }
        for source in imageSources(inHTML: html) {
            append(source)
        }

        return out
    }

    /// Valeurs des attributs `src` des balises `<img>` d'un fragment HTML.
    /// Les URI `data:` sont écartées par `append` (schéma non http).
    static func imageSources(inHTML html: String) -> [String] {
        guard !html.isEmpty,
              let regex = try? NSRegularExpression(
                pattern: "<img[^>]+src\\s*=\\s*[\"']([^\"']+)[\"']",
                options: [.caseInsensitive]
              ) else { return [] }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captured = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[captured])
        }
    }
}
