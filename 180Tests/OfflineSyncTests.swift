import Testing
import Foundation
@testable import _80

/// Diff de réconciliation du carnet hors ligne (`OfflineSyncPlanner`).
///
/// C'est la seule pièce où une erreur se traduit directement par du contenu
/// manquant, périmé, ou re-téléchargé en boucle.
struct OfflineSyncPlannerTests {

    private func meta(_ id: Int, modified: String?) -> OfflineRecipeMeta {
        OfflineRecipeMeta(id: id, downloadedAt: Date(timeIntervalSince1970: 0), modified: modified, imageCount: 1)
    }

    @Test("Premier cycle : tout est à télécharger, dans l'ordre serveur")
    func firstRunDownloadsEverything() {
        let plan = OfflineSyncPlanner.plan(
            serverIDs: [30, 10, 20],
            serverModified: [30: "d3", 10: "d1", 20: "d2"],
            local: []
        )
        #expect(plan.toDownload == [30, 10, 20])
        #expect(plan.toDelete.isEmpty)
        #expect(plan.upToDate.isEmpty)
    }

    @Test("Rien à faire quand tout est présent et à jour")
    func steadyStateIsNoop() {
        let plan = OfflineSyncPlanner.plan(
            serverIDs: [1, 2],
            serverModified: [1: "d1", 2: "d2"],
            local: [meta(1, modified: "d1"), meta(2, modified: "d2")]
        )
        #expect(plan.toDownload.isEmpty)
        #expect(plan.toDelete.isEmpty)
        #expect(plan.upToDate == [1, 2])
    }

    @Test("Favori retiré côté serveur ⇒ suppression locale")
    func removedFavoriteIsDeleted() {
        let plan = OfflineSyncPlanner.plan(
            serverIDs: [1],
            serverModified: [1: "d1"],
            local: [meta(1, modified: "d1"), meta(2, modified: "d2")]
        )
        #expect(plan.toDelete == [2])
        #expect(plan.toDownload.isEmpty)
    }

    @Test("Favori ajouté côté serveur ⇒ téléchargement")
    func addedFavoriteIsDownloaded() {
        let plan = OfflineSyncPlanner.plan(
            serverIDs: [1, 2],
            serverModified: [1: "d1", 2: "d2"],
            local: [meta(1, modified: "d1")]
        )
        #expect(plan.toDownload == [2])
        #expect(plan.upToDate == [1])
        #expect(plan.toDelete.isEmpty)
    }

    @Test("`modified` serveur plus récent ⇒ re-téléchargement")
    func staleRecipeIsRefreshed() {
        let plan = OfflineSyncPlanner.plan(
            serverIDs: [1, 2],
            serverModified: [1: "2026-07-24T16:44:07", 2: "d2"],
            local: [meta(1, modified: "2026-07-03T00:38:18"), meta(2, modified: "d2")]
        )
        #expect(plan.toDownload == [1])
        #expect(plan.upToDate == [2])
    }

    @Test("Fiche locale sans jeton de fraîcheur ⇒ re-téléchargement")
    func metaWithoutModifiedIsRefreshed() {
        let plan = OfflineSyncPlanner.plan(
            serverIDs: [1],
            serverModified: [1: "d1"],
            local: [meta(1, modified: nil)]
        )
        #expect(plan.toDownload == [1])
    }

    @Test("Date serveur indisponible ⇒ on conserve, pas de boucle de téléchargement")
    func unknownServerDateKeepsLocalCopy() {
        // Cas typique : la sonde a échoué (serverModified vide). Re-télécharger
        // ici produirait un cycle qui retélécharge tout, à chaque lancement.
        let plan = OfflineSyncPlanner.plan(
            serverIDs: [1, 2],
            serverModified: [:],
            local: [meta(1, modified: "d1"), meta(2, modified: "d2")]
        )
        #expect(plan.toDownload.isEmpty)
        #expect(plan.upToDate == [1, 2])
        #expect(plan.toDelete.isEmpty)
    }

    @Test("Sonde en panne : les manquants sont quand même téléchargés")
    func unknownServerDateStillDownloadsMissing() {
        let plan = OfflineSyncPlanner.plan(
            serverIDs: [1, 2],
            serverModified: [:],
            local: [meta(1, modified: "d1")]
        )
        #expect(plan.toDownload == [2])
        #expect(plan.upToDate == [1])
    }

    @Test("Un échec de téléchargement est repris au cycle suivant")
    func failedDownloadIsRetried() {
        // Un échec n'écrit rien : la fiche reste absente du store, donc le cycle
        // suivant la replanifie sans mécanisme de reprise dédié.
        let plan = OfflineSyncPlanner.plan(
            serverIDs: [1, 2, 3],
            serverModified: [1: "d1", 2: "d2", 3: "d3"],
            local: [meta(1, modified: "d1"), meta(3, modified: "d3")]
        )
        #expect(plan.toDownload == [2])
    }

    @Test("Carnet vidé côté serveur ⇒ tout est supprimé")
    func emptyServerListDeletesAll() {
        let plan = OfflineSyncPlanner.plan(
            serverIDs: [],
            serverModified: [:],
            local: [meta(1, modified: "d1"), meta(2, modified: "d2")]
        )
        #expect(plan.toDelete == [1, 2])
        #expect(plan.toDownload.isEmpty)
    }

    @Test("Doublons dans la liste serveur neutralisés")
    func duplicateServerIDsAreCollapsed() {
        let plan = OfflineSyncPlanner.plan(
            serverIDs: [5, 5, 7],
            serverModified: [5: "d5", 7: "d7"],
            local: []
        )
        #expect(plan.toDownload == [5, 7])
    }
}

/// Extraction des visuels à embarquer.
struct OfflineImageExtractionTests {

    private func recipe(_ json: String) throws -> Recipe {
        try JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
    }

    @Test("La photo principale est extraite depuis l'embed")
    func extractsFeaturedImage() throws {
        let r = try recipe("""
        {"id":1,"date":"2026-01-01T00:00:00","title":{"rendered":"A"},"excerpt":{"rendered":""},
         "_embedded":{"wp:featuredmedia":[{"source_url":"https://www.180c.fr/photo.webp"}]}}
        """)
        #expect(OfflineSyncService.imageURLs(in: r).map(\.absoluteString) == ["https://www.180c.fr/photo.webp"])
    }

    @Test("Fiche sans visuel : aucune URL, aucun crash")
    func noImageYieldsEmpty() throws {
        let r = try recipe("""
        {"id":1,"date":"2026-01-01T00:00:00","title":{"rendered":"A"},"excerpt":{"rendered":""}}
        """)
        #expect(OfflineSyncService.imageURLs(in: r).isEmpty)
    }

    @Test("Les images du corps et des étapes sont détectées (défensif)")
    func extractsContentAndStepImages() throws {
        let r = try recipe("""
        {"id":1,"date":"2026-01-01T00:00:00","title":{"rendered":"A"},"excerpt":{"rendered":""},
         "content":{"rendered":"<p>Texte</p><img src=\\"https://www.180c.fr/corps.jpg\\" alt=\\"x\\">"},
         "steps":[{"step_title":"S1","step_content":"<img src='https://www.180c.fr/etape.png'>Suite"}],
         "_embedded":{"wp:featuredmedia":[{"source_url":"https://www.180c.fr/hero.webp"}]}}
        """)
        let urls = OfflineSyncService.imageURLs(in: r).map(\.absoluteString)
        // La photo principale reste en tête (c'est elle qui est rendue).
        #expect(urls.first == "https://www.180c.fr/hero.webp")
        #expect(urls.contains("https://www.180c.fr/corps.jpg"))
        #expect(urls.contains("https://www.180c.fr/etape.png"))
    }

    @Test("Une même URL n'est collectée qu'une fois")
    func deduplicatesURLs() throws {
        let r = try recipe("""
        {"id":1,"date":"2026-01-01T00:00:00","title":{"rendered":"A"},"excerpt":{"rendered":""},
         "content":{"rendered":"<img src=\\"https://www.180c.fr/hero.webp\\"><img src=\\"https://www.180c.fr/hero.webp\\">"},
         "_embedded":{"wp:featuredmedia":[{"source_url":"https://www.180c.fr/hero.webp"}]}}
        """)
        #expect(OfflineSyncService.imageURLs(in: r).count == 1)
    }

    @Test("Les URI `data:` et les schémas non HTTP sont ignorés")
    func skipsDataURIs() throws {
        let r = try recipe("""
        {"id":1,"date":"2026-01-01T00:00:00","title":{"rendered":"A"},"excerpt":{"rendered":""},
         "content":{"rendered":"<img src=\\"data:image/gif;base64,R0lGODlh\\"><img src=\\"https://www.180c.fr/ok.jpg\\">"}}
        """)
        #expect(OfflineSyncService.imageURLs(in: r).map(\.absoluteString) == ["https://www.180c.fr/ok.jpg"])
    }

    @Test("Extraction HTML brute : guillemets simples ou doubles, casse libre")
    func parsesBothQuoteStyles() {
        let html = "<IMG SRC = \"https://a.fr/1.jpg\"><img src='https://a.fr/2.jpg'>"
        #expect(OfflineSyncService.imageSources(inHTML: html) == ["https://a.fr/1.jpg", "https://a.fr/2.jpg"])
    }

    @Test("HTML sans image ⇒ liste vide")
    func emptyHTMLYieldsNothing() {
        #expect(OfflineSyncService.imageSources(inHTML: "").isEmpty)
        #expect(OfflineSyncService.imageSources(inHTML: "<p>Aucune image ici</p>").isEmpty)
    }
}
