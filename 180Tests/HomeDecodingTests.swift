import Testing
import Foundation
@testable import _80

/// Contrat `180c/v1/home-recettes` — décodage **tolérant** (cœur de la
/// forward-compat : un bloc cassé ne doit pas vider l'accueil).
struct HomeDecodingTests {

    private func decode(_ json: String) throws -> HomePayload {
        try JSONDecoder().decode(HomePayload.self, from: Data(json.utf8))
    }

    @Test("Un bloc sans `type` est ignoré, les autres restent")
    func dropsBlockWithoutType() throws {
        let payload = try decode("""
        {
          "page_id": 12,
          "blocks": [
            {"type": "featured", "title": "À la une", "recipe_ids": [1]},
            {"type": "rail", "recipe_ids": [2, 3]},
            {"type": "brand_new_block_2027", "title": "Futur"},
            {"anchor": "orphelin", "title": "sans type"},
            {"type": "category_tiles", "title": "Catégories", "terms": [{"slug": "plat", "name": "Plat"}]}
          ]
        }
        """)

        // Le bloc sans `type` est retiré ; les 4 autres subsistent.
        #expect(payload.blocks.count == 4)
        #expect(payload.pageId == 12)
        #expect(payload.blocks[0].type == "featured")
        #expect(payload.blocks[0].title == "À la une")
        #expect(payload.blocks[0].recipeIds == [1])
    }

    @Test("`title` manquant ⇒ chaîne vide (et pas d'échec)")
    func missingTitleDefaultsToEmpty() throws {
        let payload = try decode("""
        { "blocks": [ {"type": "rail", "recipe_ids": [2, 3]} ] }
        """)
        #expect(payload.pageId == nil)            // page_id optionnel
        #expect(payload.blocks.count == 1)
        #expect(payload.blocks[0].title == "")
        #expect(payload.blocks[0].recipeIds == [2, 3])
    }

    @Test("Type inconnu conservé (passthrough forward-compat)")
    func keepsUnknownBlockType() throws {
        let payload = try decode("""
        { "blocks": [ {"type": "brand_new_block_2027", "title": "Futur"} ] }
        """)
        #expect(payload.blocks.first?.type == "brand_new_block_2027")
    }

    @Test("Tuile sans `count` ⇒ 0 (bloc tiles non cassé)")
    func tileWithoutCountDefaultsToZero() throws {
        let payload = try decode("""
        {
          "blocks": [
            {"type": "category_tiles", "title": "Catégories", "terms": [{"slug": "plat", "name": "Plat"}]}
          ]
        }
        """)
        #expect(payload.blocks.first?.terms?.first?.count == 0)
        #expect(payload.blocks.first?.terms?.first?.slug == "plat")
    }

    @Test("`blocks` absent ⇒ payload vide, pas d'échec")
    func missingBlocksIsEmpty() throws {
        let payload = try decode("{ \"page_id\": 1 }")
        #expect(payload.blocks.isEmpty)
    }

    // MARK: - visibility (parité stricte avec Android : seul `web_only` sort)

    @Test("`web_only` exclu, `app_only` et `web_app` conservés")
    func filtersWebOnlyBlocks() throws {
        let payload = try decode("""
        {
          "blocks": [
            {"type": "rail", "title": "Récentes", "visibility": "web_app"},
            {"type": "newsletter_form", "title": "Newsletter", "visibility": "web_only"},
            {"type": "carnet", "title": "Mon carnet", "visibility": "app_only"},
            {"type": "grid_paginated", "title": "Toutes", "visibility": "web_only"}
          ]
        }
        """)

        #expect(payload.blocks.count == 2)
        #expect(payload.blocks.map(\.type) == ["rail", "carnet"])
        #expect(payload.blocks[0].visibility == .webAndApp)
        #expect(payload.blocks[1].visibility == .appOnly)
    }

    @Test("`visibility` absent ou inconnu ⇒ rien n'est exclu (fallback web_app)")
    func unknownOrMissingVisibilityKeepsBlock() throws {
        let payload = try decode("""
        {
          "blocks": [
            {"type": "featured", "title": "À la une"},
            {"type": "rail", "title": "Futur", "visibility": "app_only_v2"},
            {"type": "category_tiles", "title": "Catégories", "visibility": null},
            {"type": "search", "title": "Recherche", "visibility": 42}
          ]
        }
        """)

        // Champ absent, valeur inconnue, `null` et type inattendu : aucun bloc
        // ne doit disparaître, et le décodage ne doit jamais échouer.
        #expect(payload.blocks.count == 4)
        #expect(payload.blocks.allSatisfy { $0.visibility == .webAndApp })
    }

    @Test("Un seul module, `web_only` ⇒ accueil vide plutôt qu'un module fantôme")
    func onlyWebOnlyBlockYieldsEmptyHome() throws {
        let payload = try decode("""
        { "blocks": [ {"type": "rail", "title": "Web", "visibility": "web_only"} ] }
        """)
        #expect(payload.blocks.isEmpty)
    }

    @Test("Le filtre s'applique aussi à un instantané disque (payload brut relu)")
    func filtersWhenReplayingCachedSnapshotPayload() throws {
        // Simule un snapshot écrit **avant** l'arrivée du filtre serveur : le
        // JSON stocké contient encore un `web_only`, qui doit sortir à la relecture.
        let staleSnapshotPayload = """
        {
          "page_id": 7,
          "blocks": [
            {"type": "featured", "title": "À la une", "recipe_ids": [1], "visibility": "web_app"},
            {"type": "cta_subscribe", "title": "Abonnement", "visibility": "web_only"}
          ]
        }
        """
        let payload = try decode(staleSnapshotPayload)

        #expect(payload.pageId == 7)
        #expect(payload.blocks.count == 1)
        #expect(payload.blocks[0].type == "featured")
    }

    /// Test d'intégration du chemin **cache disque de bout en bout** : la
    /// composition réelle de `/home-recettes` (prod, 7 modules) augmentée d'un
    /// `web_only`, écrite dans un `HomeCacheSnapshot`, round-trippée par le même
    /// couple `JSONEncoder`/`JSONDecoder` que `DiskCache`, puis relue comme le
    /// fait `HomeView.applySnapshot`. Remplace le test manuel end-to-end, non
    /// jouable tant qu'aucun module n'est configuré en `web_only` en prod.
    @Test("Round-trip snapshot disque : le `web_only` ne réapparaît pas au rechargement")
    func snapshotRoundTripKeepsWebOnlyFilteredOut() throws {
        let productionLikePayload = """
        {
          "page_id": 4210,
          "blocks": [
            {"type": "rail", "title": "Dernières recettes publiées", "source": "recent",
             "recipe_ids": [101, 102, 103], "visibility": "web_app"},
            {"type": "search", "title": "Trouvez une recette", "visibility": "web_app"},
            {"type": "category_tiles", "title": "Explorez les recettes", "taxonomy": "recipe_category",
             "terms": [{"slug": "plat", "name": "Plat", "count": 42}], "visibility": "web_app"},
            {"type": "carnet", "title": "", "visibility": "app_only"},
            {"type": "cta_subscribe", "title": "Abonnement digital 100% bien manger", "visibility": "web_only"},
            {"type": "grid_paginated", "title": "Toutes les recettes", "visibility": "web_app"},
            {"type": "newsletter_form", "title": "Chaque semaine, nos recettes", "visibility": "web_only"}
          ]
        }
        """

        let snapshot = HomeCacheSnapshot(
            payload: Data(productionLikePayload.utf8),
            recent: [],
            hydrated: []
        )

        // Aller-retour disque (DiskCache encode le snapshot en JSON, `payload`
        // étant transporté en base64 par la synthèse Codable de `Data`).
        let stored = try JSONEncoder().encode(snapshot)
        let reloaded = try JSONDecoder().decode(HomeCacheSnapshot.self, from: stored)

        // Relecture telle que `HomeView.applySnapshot` la fait.
        let blocks = try JSONDecoder().decode(HomePayload.self, from: reloaded.payload).blocks

        #expect(blocks.map(\.type) == ["rail", "search", "category_tiles", "carnet", "grid_paginated"])
        #expect(!blocks.contains { $0.visibility == .webOnly })
        // Les index de `blocks` pilotent la table d'hydratation ET le `ForEach`
        // de la vue : tous deux partent de cette même liste filtrée, donc le
        // rail reste bien à l'index 0 avec ses `recipe_ids`.
        #expect(blocks[0].recipeIds == [101, 102, 103])
    }
}
