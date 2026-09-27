import Foundation

// MARK: - Taxonomies du CPT `recipe`
//
// Plus aucun ID natif en dur (les anciens `categories=38` / tags 33–36/19…
// ont disparu avec la migration vers le CPT `recipe`). On référence les
// taxonomies par leur `rest_base`, et les termes par leur **slug**, résolus
// dynamiquement en IDs au runtime via `RecipeTaxonomyResolver`.

enum RecipeTaxonomy {
    /// Type de plat (hiérarchique) — Entrée, Plat, Dessert, Apéro, Accompagnement…
    static let category = "recipe_category"
    /// Saison (plate) — Printemps, Été, Automne, Hiver.
    static let season = "recipe_season"
    /// Publication d'origine (plate) — Cahiers de Delphine, 180°C, 12°5…
    static let publication = "recipe_publication"
}

/// Slugs attendus de la taxonomie `recipe_season`.
enum SeasonSlug {
    static let printemps = "printemps"
    static let ete = "ete"
    static let automne = "automne"
    static let hiver = "hiver"
}

/// Slugs attendus de la taxonomie `recipe_category` (types de plat).
enum DishCategorySlug {
    static let entree = "entree"
    static let plat = "plat"
    static let dessert = "dessert"
    static let apero = "apero"
    static let accompagnement = "accompagnement"
}

/// Slugs réels de la taxonomie `recipe_publication`.
enum PublicationSlug {
    static let cahiersDelphine = "cahiers-de-delphine"
    static let douzeDegres5 = "12degres5"
    static let revue180 = "180c"
    static let selections = "selections"
}

// Les listes Saisons / Types de plat sont désormais chargées dynamiquement
// au runtime (cf. TaxonomyStore) — plus aucun tableau statique ici.
