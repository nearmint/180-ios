import Testing
import Foundation
@testable import _80

/// Persistance hors ligne : écriture, relecture, suppression, taille.
///
/// Chaque test travaille dans un dossier temporaire **unique** (injecté au
/// `OfflineStore`) : aucune interférence entre tests, aucune pollution du
/// conteneur de l'app hôte.
struct OfflineStoreTests {

    // MARK: Fixtures

    private func makeStore() -> (store: OfflineStore, base: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-tests-\(UUID().uuidString)", isDirectory: true)
        return (OfflineStore(baseDirectory: base), base)
    }

    private func recipe(id: Int, title: String = "Tarte", modified: String? = "2026-07-24T16:44:07") throws -> Recipe {
        let modifiedField = modified.map { "\"modified\":\"\($0)\"," } ?? ""
        let json = """
        {"id":\(id),"date":"2026-01-01T00:00:00",\(modifiedField)
         "title":{"rendered":"\(title)"},"excerpt":{"rendered":""},
         "ingredients_groups":[{"group_label":"","items":[{"line":"200 g de farine"}]}],
         "steps":[{"step_title":"Mélanger","step_content":"Verser la farine."}]}
        """
        return try JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
    }

    private func cleanup(_ base: URL) {
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: Tests

    @Test("save puis load restitue la fiche complète")
    func saveThenLoad() async throws {
        let (store, base) = makeStore()
        defer { cleanup(base) }

        let original = try recipe(id: 42, title: "Flan aux abricots")
        await store.save(original, images: [:])

        let loaded = await store.load(42)
        #expect(loaded?.id == 42)
        #expect(loaded?.cleanTitle == "Flan aux abricots")
        // Le contenu ACF survit au round-trip : c'est lui qui est rendu hors ligne.
        #expect(loaded?.ingredientGroups.first?.lines == ["200 g de farine"])
        #expect(loaded?.preparationSteps.first?.cleanTitle == "Mélanger")
    }

    @Test("has() est vrai après save, faux avant")
    func hasReflectsPresence() async throws {
        let (store, base) = makeStore()
        defer { cleanup(base) }

        #expect(!store.has(7))
        await store.save(try recipe(id: 7), images: [:])
        #expect(store.has(7))
        #expect(store.storedIDs() == [7])
    }

    @Test("load() d'une fiche absente renvoie nil")
    func loadMissingReturnsNil() async {
        let (store, base) = makeStore()
        defer { cleanup(base) }

        let loaded = await store.load(999)
        #expect(loaded == nil)
    }

    @Test("Les octets d'image sont restitués à l'identique (aucune recompression)")
    func imageRoundTrip() async throws {
        let (store, base) = makeStore()
        defer { cleanup(base) }

        let url = URL(string: "https://www.180c.fr/wp-content/uploads/2026/07/photo.webp")!
        let bytes = Data((0..<2048).map { UInt8($0 % 251) })
        await store.save(try recipe(id: 12), images: [url: bytes])

        let read = await store.imageData(for: url)
        #expect(read == bytes)
    }

    @Test("Une URL d'image inconnue ne renvoie rien")
    func unknownImageReturnsNil() async throws {
        let (store, base) = makeStore()
        defer { cleanup(base) }

        await store.save(try recipe(id: 12), images: [:])
        let read = await store.imageData(for: URL(string: "https://www.180c.fr/absente.jpg")!)
        #expect(read == nil)
    }

    @Test("Les métadonnées portent le `modified` serveur")
    func metadataCarriesModified() async throws {
        let (store, base) = makeStore()
        defer { cleanup(base) }

        await store.save(try recipe(id: 3, modified: "2026-07-24T16:44:07"), images: [:])
        #expect(store.metadata(3)?.modified == "2026-07-24T16:44:07")

        // Fiche sans `modified` : l'entrée existe, le jeton est nil (⇒ la
        // réconciliation la re-téléchargera plutôt que de la croire fraîche).
        await store.save(try recipe(id: 4, modified: nil), images: [:])
        #expect(store.metadata(4) != nil)
        #expect(store.metadata(4)?.modified == nil)
    }

    @Test("delete() retire la fiche, ses images et son entrée d'index")
    func deleteRemovesEverything() async throws {
        let (store, base) = makeStore()
        defer { cleanup(base) }

        let url = URL(string: "https://www.180c.fr/photo.jpg")!
        await store.save(try recipe(id: 5), images: [url: Data(repeating: 0xAB, count: 512)])
        await store.save(try recipe(id: 6), images: [:])

        await store.delete(5)

        #expect(!store.has(5))
        let loaded = await store.load(5)
        #expect(loaded == nil)
        let image = await store.imageData(for: url)
        #expect(image == nil)
        // La fiche voisine est intacte : la suppression est ciblée.
        #expect(store.has(6))
    }

    @Test("deleteAll() vide le store et le laisse réutilisable")
    func deleteAllPurges() async throws {
        let (store, base) = makeStore()
        defer { cleanup(base) }

        await store.save(try recipe(id: 1), images: [URL(string: "https://a.fr/x.jpg")!: Data(repeating: 1, count: 4096)])
        await store.save(try recipe(id: 2), images: [:])

        await store.deleteAll()

        #expect(store.storedIDs().isEmpty)
        #expect(await store.totalSizeBytes() == 0)

        // Réutilisable immédiatement après purge (le répertoire est recréé).
        await store.save(try recipe(id: 8), images: [:])
        #expect(store.has(8))
    }

    @Test("totalSizeBytes() croît avec le contenu écrit")
    func sizeGrowsWithContent() async throws {
        let (store, base) = makeStore()
        defer { cleanup(base) }

        #expect(await store.totalSizeBytes() == 0)

        await store.save(try recipe(id: 1), images: [:])
        let afterRecipe = await store.totalSizeBytes()
        #expect(afterRecipe > 0)

        await store.save(
            try recipe(id: 2),
            images: [URL(string: "https://a.fr/y.jpg")!: Data(repeating: 7, count: 200_000)]
        )
        let afterImage = await store.totalSizeBytes()
        #expect(afterImage > afterRecipe + 100_000)
    }

    @Test("L'index survit à une réouverture du store")
    func indexIsPersisted() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-tests-\(UUID().uuidString)", isDirectory: true)
        defer { cleanup(base) }

        let first = OfflineStore(baseDirectory: base)
        await first.save(try recipe(id: 77, title: "Pudding"), images: [:])

        // Nouvelle instance sur le même dossier = relance de l'app.
        let second = OfflineStore(baseDirectory: base)
        #expect(second.has(77))
        #expect(second.metadata(77)?.modified == "2026-07-24T16:44:07")
        let loaded = await second.load(77)
        #expect(loaded?.cleanTitle == "Pudding")
    }

    @Test("Le répertoire est exclu de la sauvegarde iCloud")
    func rootIsExcludedFromBackup() async throws {
        let (store, base) = makeStore()
        defer { cleanup(base) }

        await store.save(try recipe(id: 1), images: [:])

        let root = base.appendingPathComponent("OfflineRecipes", isDirectory: true)
        let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test("Taille formatée lisible")
    func formatsBytes() {
        // `ByteCountFormatter` est localisé : on n'assertionne pas le libellé
        // exact (« 12,4 Mo » / « Zero KB »…), seulement qu'il produit quelque
        // chose d'affichable et que l'ordre de grandeur est distingué.
        #expect(!OfflineStore.formatted(12_400_000).isEmpty)
        #expect(!OfflineStore.formatted(0).isEmpty)
        #expect(OfflineStore.formatted(0) != OfflineStore.formatted(12_400_000))
    }
}
