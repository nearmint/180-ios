import Foundation
import Combine

/// Chargeur partagé des termes de taxonomie (résolus dynamiquement, par slug).
///
/// Remplace les anciens tableaux statiques `seasons` / `dishTypes` : les listes
/// Saisons (`recipe_season`) et Types de plat (`recipe_category`) sont chargées
/// au runtime via `APIService.fetchTerms` et reflètent le back-office.
@MainActor
final class TaxonomyStore: ObservableObject {
    static let shared = TaxonomyStore()

    @Published private(set) var seasons: [Term] = []
    @Published private(set) var dishCategories: [Term] = []

    private var hasLoaded = false

    /// Charge les termes une fois (no-op si déjà chargés).
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await reload()
    }

    /// Recharge les termes depuis l'API.
    func reload() async {
        async let seasonsTask = APIService.shared.fetchTerms(taxonomy: RecipeTaxonomy.season)
        async let dishesTask = APIService.shared.fetchTerms(taxonomy: RecipeTaxonomy.category)

        let loadedSeasons = (try? await seasonsTask) ?? []
        let loadedDishes = (try? await dishesTask) ?? []

        seasons = Self.orderedSeasons(loadedSeasons)
        dishCategories = loadedDishes.sorted { $0.count > $1.count }
        hasLoaded = !seasons.isEmpty || !dishCategories.isEmpty
    }

    // Ordre chronologique des saisons (sinon ordre alpha en repli).
    private static let seasonOrder = ["printemps", "ete", "automne", "hiver", "toute-saison"]

    private static func orderedSeasons(_ terms: [Term]) -> [Term] {
        terms.sorted {
            let ia = seasonOrder.firstIndex(of: $0.slug) ?? Int.max
            let ib = seasonOrder.firstIndex(of: $1.slug) ?? Int.max
            return ia == ib ? $0.name < $1.name : ia < ib
        }
    }
}

/// Icônes SF Symbols par slug de terme (repli générique pour les slugs inconnus).
enum TaxonomyIcon {
    static func season(_ slug: String) -> String {
        switch slug {
        case "printemps": return "leaf"
        case "ete": return "sun.max"
        case "automne": return "wind"
        case "hiver": return "snowflake"
        default: return "calendar"
        }
    }

    static func dish(_ slug: String) -> String {
        switch slug {
        case "apero": return "wineglass"
        case "entree": return "fork.knife"
        case "plat": return "frying.pan"
        case "dessert": return "birthday.cake"
        case "accompagnement": return "leaf.circle"
        case "boisson": return "cup.and.saucer"
        case "petit-dejeuner": return "sunrise"
        default: return "fork.knife"
        }
    }
}
