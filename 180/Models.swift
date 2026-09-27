import Foundation

// MARK: - Recipe (CPT `recipe`, champs ACF structurés)

/// Recette décodée depuis `wp/v2/recipe?_embed`.
///
/// Le contenu n'est plus parsé depuis `content.rendered` (HTML Classic) : il est
/// lu directement depuis les champs ACF exposés en REST par le thème
/// (`inc/rest/recipe-fields.php`) — intro, portions, repeaters ingrédients/étapes.
///
/// Conformance `nonisolated Codable` (ici et sur les types imbriqués) : le
/// module isole par défaut au `MainActor`, conformances comprises, alors que
/// `OfflineStore` encode/décode les recettes sur sa file d'E/S. Seule la
/// conformance est désisolée ; le type et ses helpers d'affichage ne changent pas.
struct Recipe: Identifiable, nonisolated Codable {
    let id: Int
    /// Slug WordPress de la recette. Optionnel : les instantanés déjà écrits sur
    /// disque (`HomeCacheSnapshot`, carnet hors ligne) ne le portent pas, et les
    /// relire ne doit pas échouer. Sert d'URL de page vue analytics
    /// (`/recette/{slug}`), calquée sur le site ; repli sur l'`id` s'il manque.
    let slug: String?
    let date: String
    /// Date de dernière modification côté serveur (`modified`, heure du site).
    ///
    /// Optionnelle : elle n'était pas décodée avant la mise en cache hors ligne,
    /// et les instantanés d'accueil déjà écrits sur disque (`HomeCacheSnapshot`)
    /// ne la portent pas — les relire ne doit pas échouer. Sert de jeton de
    /// fraîcheur à la réconciliation du carnet hors ligne.
    let modified: String?
    let title: RenderedContent
    let excerpt: RenderedContent
    /// Corps Gutenberg rendu. **Jamais affiché** : le rendu lit les champs ACF
    /// structurés. Décodé uniquement pour y détecter d'éventuelles images de
    /// contenu à embarquer hors ligne (cf. `OfflineSyncService.imageURLs(in:)`).
    /// Optionnel : le serveur le tronque pour les recettes verrouillées.
    let content: RenderedContent?

    // Champs ACF structurés (register_rest_field, lecture seule).
    let recipeIntro: String?
    let servings: Int?
    let servingsUnit: String?
    let recipeIsPremium: Bool?
    let recipeLocked: Bool?
    let ingredientsGroups: [IngredientGroup]?
    let steps: [RecipeStep]?
    let sourceIssue: Int?

    // Termes de taxonomie (IDs) — exposés nativement par le CPT.
    let recipeCategory: [Int]?
    let recipeSeason: [Int]?
    let recipePublication: [Int]?

    let embedded: Embedded?

    enum CodingKeys: String, CodingKey {
        case id, slug, date, modified, title, excerpt, content, servings, steps
        case recipeIntro = "recipe_intro"
        case servingsUnit = "servings_unit"
        case recipeIsPremium = "recipe_is_premium"
        case recipeLocked = "recipe_locked"
        case ingredientsGroups = "ingredients_groups"
        case sourceIssue = "source_issue"
        case recipeCategory = "recipe_category"
        case recipeSeason = "recipe_season"
        case recipePublication = "recipe_publication"
        case embedded = "_embedded"
    }

    // MARK: Helpers d'affichage

    var cleanTitle: String {
        title.rendered.stripHTML()
    }

    var cleanExcerpt: String {
        excerpt.rendered.stripHTML()
    }

    var imageURL: String? {
        embedded?.wpFeaturedmedia?.first?.sourceURL
    }

    /// Tous les termes embarqués d'une taxonomie donnée (via `_embed`).
    func embeddedTerms(_ taxonomy: String) -> [EmbeddedTerm] {
        (embedded?.wpTerm?.flatMap { $0 } ?? []).filter { $0.taxonomy == taxonomy }
    }

    /// Premier terme embarqué d'une taxonomie donnée.
    private func embeddedTerm(_ taxonomy: String) -> EmbeddedTerm? {
        embeddedTerms(taxonomy).first
    }

    /// Slugs des termes embarqués (filtrage local du carnet).
    var categorySlugs: [String] { embeddedTerms(RecipeTaxonomy.category).map { $0.slug } }
    var seasonSlugs: [String] { embeddedTerms(RecipeTaxonomy.season).map { $0.slug } }

    /// Nom de la publication d'origine (`recipe_publication`).
    var publicationName: String? {
        embeddedTerm(RecipeTaxonomy.publication)?.name
    }

    /// Nom du type de plat (`recipe_category`) pour le label carte.
    var categoryName: String? {
        embeddedTerm(RecipeTaxonomy.category)?.name
    }

    /// Nom de la saison (`recipe_season`) pour le label carte.
    var seasonName: String? {
        embeddedTerm(RecipeTaxonomy.season)?.name
    }

    var isPremium: Bool {
        recipeIsPremium ?? true
    }

    /// Contenu premium verrouillé pour l'utilisateur courant.
    ///
    /// Source de vérité = `recipe_locked` renvoyé par l'API (gating serveur).
    /// En l'absence du champ, repli sur l'état premium (verrouillé par défaut,
    /// jamais de fuite de contenu).
    var isLocked: Bool {
        recipeLocked ?? isPremium
    }

    /// Introduction éditoriale nettoyée (sans balises HTML résiduelles).
    var introText: String {
        (recipeIntro ?? "").stripHTML()
    }

    /// Libellé de portions, ex. « Pour 4 personnes ».
    var servingsText: String? {
        guard let servings, servings > 0 else { return nil }
        let unit = (servingsUnit?.isEmpty == false) ? servingsUnit! : "personnes"
        return "Pour \(servings) \(unit)"
    }

    /// Groupes d'ingrédients non vides.
    var ingredientGroups: [IngredientGroup] {
        (ingredientsGroups ?? []).filter { !$0.items.isEmpty }
    }

    /// Étapes de préparation avec contenu nettoyé.
    var preparationSteps: [RecipeStep] {
        (steps ?? []).filter { !$0.cleanContent.isEmpty || !$0.cleanTitle.isEmpty }
    }
}

/// `Hashable` par **identité** (id), pour la navigation par valeur
/// (`NavigationLink(value:)` + `navigationDestination(for: Recipe.self)`).
/// Une recette est identifiée par son `id` ; les autres champs (contenu ACF,
/// termes) ne participent pas à l'égalité de navigation.
extension Recipe: Hashable {
    static func == (lhs: Recipe, rhs: Recipe) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Repeaters ACF

/// Groupe d'ingrédients (`ingredients_groups`) : libellé optionnel + lignes brutes.
struct IngredientGroup: nonisolated Codable, Identifiable {
    let groupLabel: String
    let items: [IngredientItem]

    enum CodingKeys: String, CodingKey {
        case groupLabel = "group_label"
        case items
    }

    /// Identité stable au sein d'une recette (libellé + nb de lignes).
    var id: String { "\(groupLabel)#\(items.count)" }

    /// Lignes d'ingrédients en texte simple.
    var lines: [String] { items.map { $0.line } }
}

/// Une ligne d'ingrédient (`items[].line`).
struct IngredientItem: nonisolated Codable {
    let line: String
}

/// Étape de préparation (`steps`) : titre optionnel + contenu HTML.
struct RecipeStep: nonisolated Codable, Identifiable {
    let stepTitle: String
    let stepContent: String

    enum CodingKeys: String, CodingKey {
        case stepTitle = "step_title"
        case stepContent = "step_content"
    }

    var id: String { "\(stepTitle)#\(stepContent.count)" }

    var cleanTitle: String { stepTitle.stripHTML() }
    var cleanContent: String { stepContent.stripHTML() }
}

// MARK: - Embed média

struct Embedded: nonisolated Codable {
    let wpFeaturedmedia: [EmbeddedMedia]?
    /// `wp:term` — termes groupés par taxonomie (un sous-tableau par taxonomie).
    let wpTerm: [[EmbeddedTerm]]?

    enum CodingKeys: String, CodingKey {
        case wpFeaturedmedia = "wp:featuredmedia"
        case wpTerm = "wp:term"
    }
}

struct EmbeddedMedia: nonisolated Codable {
    let sourceURL: String

    enum CodingKeys: String, CodingKey {
        case sourceURL = "source_url"
    }
}

/// Terme de taxonomie embarqué (`_embed` → `wp:term`).
struct EmbeddedTerm: nonisolated Codable, Identifiable {
    let name: String
    let slug: String
    let taxonomy: String

    var id: String { "\(taxonomy)|\(slug)" }
}

struct RenderedContent: nonisolated Codable {
    let rendered: String
}

// (Le modèle `Media` a été retiré avec `APIService.fetchImageURL` : les visuels
// proviennent désormais exclusivement de `_embed` → `EmbeddedMedia`.)

// MARK: - Terme de taxonomie

/// Terme générique d'une taxonomie `recipe_*` (`wp/v2/recipe_category`, …).
///
/// `parent` est optionnel : les taxonomies plates (saison, type) n'exposent pas
/// ce champ en REST, contrairement aux taxonomies hiérarchiques.
struct Term: Identifiable, Codable {
    let id: Int
    let count: Int
    let name: String
    let slug: String
    let parent: Int?
}

// MARK: - Favoris (réponses REST 180c/v1)

/// Réponse `GET /180c/v1/favorites` — on ne consomme que les IDs.
struct FavoritesListResponse: Decodable {
    let ids: [Int]
    let count: Int
}

/// Réponse `POST /180c/v1/favorites/sync` — état réconcilié complet.
struct FavoritesSyncResponse: Decodable {
    let favorites: [FavoriteRef]
}

/// Référence minimale d'un favori (l'`id` est l'ID de recette).
struct FavoriteRef: Decodable {
    let id: Int
}

