import SwiftUI
import os

/// Liste de recettes filtrée par taxonomie (catégorie culinaire, saison, publication).
struct RecipeListView: View {
    let title: String
    var categorySlug: String? = nil      // recipe_category (type de plat)
    var seasonSlug: String? = nil        // recipe_season
    var publicationSlug: String? = nil   // recipe_publication
    var showFilters: Bool = false

    @State private var recipes: [Recipe] = []
    @State private var isLoading = true
    @State private var currentPage = 1
    @State private var canLoadMore = true
    @State private var selectedSortID: String = RecipeListView.defaultSortID
    @State private var filterSeasonSlug: String? = nil
    @State private var filterCategorySlug: String? = nil
    @State private var showFilterSheet = false
    @StateObject private var taxonomy = TaxonomyStore.shared
    @StateObject private var auth = AuthService.shared

    private static let defaultSortID = "date_desc"

    /// Options de tri de l'écran « Toutes les recettes » (tri serveur).
    private static let sortOptions: [RecipeSortOption] = [
        RecipeSortOption(id: "date_desc", label: "Plus récentes"),
        RecipeSortOption(id: "date_asc", label: "Plus anciennes"),
        RecipeSortOption(id: "title_asc", label: "Titre A → Z"),
    ]

    /// Traduit l'id de tri en couple `orderby`/`order` de l'API WordPress.
    private var sortParams: (orderby: String, order: String) {
        switch selectedSortID {
        case "date_asc": return ("date", "asc")
        case "title_asc": return ("title", "asc")
        default: return ("date", "desc")
        }
    }

    private var hasActiveFilter: Bool {
        filterSeasonSlug != nil || filterCategorySlug != nil || selectedSortID != Self.defaultSortID
    }

    var body: some View {
        List {
            ForEach(recipes) { recipe in
                NavigationLink(destination: RecipeDetailView(recipe: recipe)) {
                    RecipeCard(recipe: recipe, style: .row)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }

            if canLoadMore && !recipes.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .task {
                        await loadMore()
                    }
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .toolbar {
            if showFilters {
                ToolbarItem(placement: .navigationBarTrailing) {
                    FilterToolbarButton(hasActiveFilter: hasActiveFilter) {
                        showFilterSheet = true
                    }
                }
            }
        }
        .sheet(isPresented: $showFilterSheet) {
            RecipeFilterSheet(
                sortOptions: Self.sortOptions,
                selectedSortID: $selectedSortID,
                seasons: taxonomy.seasons.map {
                    RecipeFilterOption(slug: $0.slug, name: $0.name, systemImage: TaxonomyIcon.season($0.slug))
                },
                seasonSlug: $filterSeasonSlug,
                categories: taxonomy.dishCategories.map {
                    RecipeFilterOption(slug: $0.slug, name: $0.name, systemImage: TaxonomyIcon.dish($0.slug))
                },
                categorySlug: $filterCategorySlug,
                defaultSortID: Self.defaultSortID,
                onApply: { Task { await applyFilters() } }
            )
        }
        .overlay {
            if isLoading && recipes.isEmpty {
                // Skeleton plutôt qu'un spinner : la page annonce sa forme
                // pendant le chargement. Fond opaque pour masquer la liste vide.
                ScrollView {
                    SkeletonRecipeList()
                }
                .scrollDisabled(true)
                .background(Color(.systemBackground))
            }
            if !isLoading && recipes.isEmpty {
                ContentUnavailableView(
                    "Aucune recette",
                    systemImage: "fork.knife",
                    description: Text("Aucune recette trouvée dans cette catégorie.")
                )
            }
        }
        // Rejoué à chaque changement de session : les recettes en mémoire portent
        // le `recipe_locked` de l'ancien jeton.
        .task(id: auth.contentGeneration) {
            currentPage = 1
            canLoadMore = true
            await loadRecipes()
            await taxonomy.loadIfNeeded()
        }
        // Toutes les listes partagent l'url `/recettes` (parité web / Android) ;
        // c'est le titre qui porte le filtre d'entrée (« Été », « Desserts »…).
        .onAppear { UmamiTracker.shared.trackScreen(path: "/recettes", title: title) }
    }

    // Filtre effectif : le choix dans la feuille de filtres prime sur le filtre d'entrée.
    private var combinedSeasonSlug: String? { filterSeasonSlug ?? seasonSlug }
    private var combinedCategorySlug: String? { filterCategorySlug ?? categorySlug }

    private func loadRecipes() async {
        isLoading = true
        do {
            recipes = try await APIService.shared.fetchRecipes(
                categorySlug: combinedCategorySlug,
                seasonSlug: combinedSeasonSlug,
                publicationSlug: publicationSlug,
                page: 1,
                perPage: 20,
                orderby: sortParams.orderby,
                order: sortParams.order
            )
        } catch {
            AppLogger.api.error("Erreur loadRecipes: \(error)")
        }
        isLoading = false
    }

    private func applyFilters() async {
        isLoading = true
        currentPage = 1
        canLoadMore = true

        let seasonName = filterSeasonSlug.flatMap { slug in taxonomy.seasons.first { $0.slug == slug }?.name }
        let typeName = filterCategorySlug.flatMap { slug in taxonomy.dishCategories.first { $0.slug == slug }?.name }
        AnalyticsService.filterApplied(sortOrder: selectedSortID, season: seasonName, dishType: typeName)

        do {
            recipes = try await APIService.shared.fetchRecipes(
                categorySlug: combinedCategorySlug,
                seasonSlug: combinedSeasonSlug,
                publicationSlug: publicationSlug,
                page: 1,
                perPage: 20,
                orderby: sortParams.orderby,
                order: sortParams.order
            )
        } catch {
            AppLogger.api.error("Erreur filtres: \(error)")
        }

        isLoading = false
    }

    private func loadMore() async {
        currentPage += 1
        do {
            let newRecipes = try await APIService.shared.fetchRecipes(
                categorySlug: combinedCategorySlug,
                seasonSlug: combinedSeasonSlug,
                publicationSlug: publicationSlug,
                page: currentPage,
                perPage: 20,
                orderby: sortParams.orderby,
                order: sortParams.order
            )
            if newRecipes.isEmpty {
                canLoadMore = false
            } else {
                recipes.append(contentsOf: newRecipes)
            }
        } catch {
            canLoadMore = false
        }
    }
}
