import Foundation
import os

/// Résout dynamiquement les termes de taxonomie `recipe_*` (slug → ID).
///
/// Les IDs natifs en dur (cat 38, tags 33–36/19…) ont disparu avec la migration
/// vers le CPT `recipe`. Les vues raisonnent en **slugs** (`SeasonSlug`,
/// `DishCategorySlug`, `PublicationSlug`) ; ce resolver charge les termes réels
/// d'une taxonomie une fois, les met en cache, et expose la correspondance
/// slug → ID. Un slug introuvable renvoie `nil` (le filtre ne matche alors rien,
/// dégradation propre plutôt que résultats erronés).
actor RecipeTaxonomyResolver {

    static let shared = RecipeTaxonomyResolver()

    /// taxonomie → (slug → term ID).
    private var cache: [String: [String: Int]] = [:]

    /// Résout un slug en ID de terme pour une taxonomie donnée.
    func termID(taxonomy: String, slug: String) async -> Int? {
        let map = await slugMap(for: taxonomy)
        return map[slug]
    }

    /// Carte slug → ID pour une taxonomie (chargée puis mise en cache).
    func slugMap(for taxonomy: String) async -> [String: Int] {
        if let cached = cache[taxonomy] {
            return cached
        }

        var map: [String: Int] = [:]
        do {
            let terms = try await APIService.shared.fetchTerms(taxonomy: taxonomy)
            for term in terms {
                map[term.slug] = term.id
            }
        } catch {
            AppLogger.api.error("Résolution taxo \(taxonomy) échouée: \(error)")
            // Pas de mise en cache d'un échec : on retentera au prochain appel.
            return map
        }

        cache[taxonomy] = map
        return map
    }

    /// Invalide le cache (utile après changement d'environnement).
    func reset() {
        cache.removeAll()
    }
}
