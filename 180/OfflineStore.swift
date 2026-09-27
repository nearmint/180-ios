import Foundation
import os

/// Métadonnées d'une fiche téléchargée, tenues dans l'index.
///
/// `modified` est le jeton de fraîcheur : la réconciliation compare la valeur
/// serveur à celle-ci pour décider d'un re-téléchargement. `nil` (fiche écrite
/// par une version antérieure, ou serveur muet) ⇒ re-téléchargement au prochain
/// cycle, jamais de contenu périmé conservé par défaut.
struct OfflineRecipeMeta: Codable, Equatable {
    let id: Int
    let downloadedAt: Date
    let modified: String?
    let imageCount: Int
}

/// Persistance des fiches consultables hors ligne.
///
/// ## Emplacement
///
/// `Application Support/OfflineRecipes/` — **pas** `Caches/`. Les deux caches
/// existants (`DiskCache`, `ImageCacheManager`) vivent sous `Caches/`, que le
/// système évince librement sous pression disque : parfait pour un cache, fatal
/// pour un carnet hors ligne dont l'utilisateur a explicitement demandé le
/// téléchargement. Le répertoire est en revanche **exclu de la sauvegarde
/// iCloud** : tout y est re-téléchargeable.
///
/// ```
/// OfflineRecipes/
///   index.json                  ← métadonnées (id, date, modified, nb images)
///   13400072/recipe.json        ← Recipe encodée
///   13400072/images/<clé>.webp  ← octets d'origine, jamais recompressés
/// ```
///
/// ## Images
///
/// Les octets sont stockés **tels que servis** (webp/jpeg d'origine, aucune
/// recompression, aucun recadrage). Le nom de fichier dérive de l'URL par la
/// même transformation base64 url-safe que `ImageCacheManager` et `DiskCache`,
/// ce qui rend la lecture possible sans consulter l'index.
///
/// ## Concurrence
///
/// Les E/S passent par une file série dédiée (même parti pris que `DiskCache`).
/// L'index est doublé en mémoire sous verrou : `has(_:)` et `metadata(_:)` sont
/// donc **synchrones et sans E/S**, ce qu'exige le rendu d'une liste de cartes.
/// `nonisolated` explicite : sans lui, l'isolation `MainActor` par défaut du
/// module s'appliquerait à un type qui travaille justement hors du main thread.
nonisolated final class OfflineStore: @unchecked Sendable {

    static let shared = OfflineStore()

    private let root: URL
    private let indexURL: URL
    private let ioQueue = DispatchQueue(label: "fr.thermostat6.app180.offlinestore", qos: .utility)

    /// Index en mémoire, reflet de `index.json`. Sous verrou : lu depuis le main
    /// (badges, écran compte) et écrit depuis `ioQueue`.
    private let index = OSAllocatedUnfairLock<[Int: OfflineRecipeMeta]>(initialState: [:])

    /// - Parameter baseDirectory: racine d'accueil. `nil` ⇒ *Application
    ///   Support* (production) ; les tests y injectent un dossier temporaire
    ///   pour ne pas polluer le conteneur de l'app hôte.
    init(baseDirectory: URL? = nil, directoryName: String = "OfflineRecipes") {
        let base = baseDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        root = base.appendingPathComponent(directoryName, isDirectory: true)
        indexURL = root.appendingPathComponent("index.json")
        createRootIfNeeded()
        index.withLock { $0 = Self.readIndex(at: indexURL) }
    }

    // MARK: - Arborescence

    private func createRootIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.path) else { return }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        excludeFromBackup()
    }

    /// Marque le répertoire comme non sauvegardé (iCloud / iTunes). Réappliqué à
    /// chaque création : l'attribut est porté par l'inode, il disparaît avec lui.
    private func excludeFromBackup() {
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try url.setResourceValues(values)
        } catch {
            AppLogger.data.error("[OfflineStore] exclusion backup impossible: \(error.localizedDescription)")
        }
    }

    private func directory(for id: Int) -> URL {
        root.appendingPathComponent(String(id), isDirectory: true)
    }

    private func recipeURL(for id: Int) -> URL {
        directory(for: id).appendingPathComponent("recipe.json")
    }

    private func imagesDirectory(for id: Int) -> URL {
        directory(for: id).appendingPathComponent("images", isDirectory: true)
    }

    /// Nom de fichier sûr dérivé d'une URL d'image (base64 url-safe), extension
    /// d'origine préservée pour la lisibilité du dossier.
    private func imageFilename(for url: URL) -> String {
        let safe = Data(url.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension
        return "\(safe).\(ext)"
    }

    // MARK: - Index

    private static func readIndex(at url: URL) -> [Int: OfflineRecipeMeta] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([OfflineRecipeMeta].self, from: data) else {
            return [:]
        }
        return Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Réécrit `index.json` depuis l'index mémoire. **À appeler depuis `ioQueue`.**
    private func persistIndex() {
        let entries = index.withLock { Array($0.values) }.sorted { $0.id < $1.id }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: - Lecture synchrone (index mémoire, aucune E/S)

    /// `true` si la fiche est disponible hors ligne.
    func has(_ id: Int) -> Bool {
        index.withLock { $0[id] != nil }
    }

    func metadata(_ id: Int) -> OfflineRecipeMeta? {
        index.withLock { $0[id] }
    }

    /// Toutes les fiches présentes localement (base de la réconciliation).
    func allMetadata() -> [OfflineRecipeMeta] {
        index.withLock { Array($0.values) }.sorted { $0.id < $1.id }
    }

    /// IDs présents localement.
    func storedIDs() -> Set<Int> {
        index.withLock { Set($0.keys) }
    }

    // MARK: - Écriture

    /// Écrit une fiche et ses visuels. Les octets d'image sont enregistrés tels
    /// quels ; une image manquante n'empêche pas l'écriture de la fiche.
    ///
    /// L'entrée d'index n'est ajoutée qu'**après** l'écriture effective du JSON :
    /// une interruption ne laisse jamais l'index annoncer une fiche absente.
    func save(_ recipe: Recipe, images: [URL: Data]) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ioQueue.async {
                let fm = FileManager.default
                let dir = self.directory(for: recipe.id)
                let imagesDir = self.imagesDirectory(for: recipe.id)

                do {
                    self.createRootIfNeeded()
                    try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
                    let data = try JSONEncoder().encode(recipe)
                    try data.write(to: self.recipeURL(for: recipe.id), options: .atomic)
                } catch {
                    AppLogger.data.error("[OfflineStore] écriture fiche \(recipe.id) échouée: \(error.localizedDescription)")
                    continuation.resume()
                    return
                }

                var written = 0
                for (url, bytes) in images where !bytes.isEmpty {
                    let target = imagesDir.appendingPathComponent(self.imageFilename(for: url))
                    do {
                        try bytes.write(to: target, options: .atomic)
                        written += 1
                    } catch {
                        AppLogger.data.error("[OfflineStore] écriture image échouée: \(error.localizedDescription)")
                    }
                }

                let meta = OfflineRecipeMeta(
                    id: recipe.id,
                    downloadedAt: Date(),
                    modified: recipe.modified,
                    imageCount: written
                )
                self.index.withLock { $0[recipe.id] = meta }
                self.persistIndex()
                _ = dir
                continuation.resume()
            }
        }
    }

    // MARK: - Lecture

    /// Relit une fiche depuis le disque, `nil` si absente ou illisible.
    func load(_ id: Int) async -> Recipe? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Recipe?, Never>) in
            ioQueue.async {
                guard let data = try? Data(contentsOf: self.recipeURL(for: id)),
                      let recipe = try? JSONDecoder().decode(Recipe.self, from: data) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: recipe)
            }
        }
    }

    /// Toutes les fiches disponibles hors ligne, dans l'ordre demandé. Les IDs
    /// sans fiche locale sont simplement absents du résultat.
    func load(ids: [Int]) async -> [Recipe] {
        var out: [Recipe] = []
        for id in ids {
            if let recipe = await load(id) { out.append(recipe) }
        }
        return out
    }

    /// Octets d'une image téléchargée, quelle que soit la fiche qui la porte.
    ///
    /// La recherche est bornée aux fiches de l'index : une URL inconnue coûte un
    /// parcours de dossiers, jamais une lecture réseau.
    func imageData(for url: URL) async -> Data? {
        let ids = storedIDs()
        guard !ids.isEmpty else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            ioQueue.async {
                let filename = self.imageFilename(for: url)
                for id in ids {
                    let candidate = self.imagesDirectory(for: id).appendingPathComponent(filename)
                    if let data = try? Data(contentsOf: candidate), !data.isEmpty {
                        continuation.resume(returning: data)
                        return
                    }
                }
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - Suppression

    /// Supprime une fiche et ses visuels.
    func delete(_ id: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ioQueue.async {
                try? FileManager.default.removeItem(at: self.directory(for: id))
                self.index.withLock { $0[id] = nil }
                self.persistIndex()
                continuation.resume()
            }
        }
    }

    /// Purge intégrale (toggle OFF, « Vider le cache », déconnexion).
    func deleteAll() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ioQueue.async {
                try? FileManager.default.removeItem(at: self.root)
                self.index.withLock { $0 = [:] }
                self.createRootIfNeeded()
                continuation.resume()
            }
        }
    }

    // MARK: - Taille occupée

    /// Poids total sur disque (octets alloués, index compris).
    func totalSizeBytes() async -> Int64 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int64, Never>) in
            ioQueue.async {
                let fm = FileManager.default
                let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
                guard let enumerator = fm.enumerator(
                    at: self.root,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles]
                ) else {
                    continuation.resume(returning: 0)
                    return
                }

                var total: Int64 = 0
                for case let url as URL in enumerator {
                    guard let values = try? url.resourceValues(forKeys: Set(keys)),
                          values.isRegularFile == true else { continue }
                    // `totalFileAllocatedSize` reflète l'occupation réelle
                    // (blocs) ; repli sur la taille logique si indisponible.
                    total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                }
                continuation.resume(returning: total)
            }
        }
    }

    /// Taille lisible (« 12,4 Mo »), formatée selon la locale de l'appareil.
    static func formatted(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
