import SwiftUI
import os

/// Écran « Mon carnet de recettes » (favoris). Onglet « Favoris » dans la tab bar.
struct FavoritesView: View {

    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(NetworkMonitor.self) private var injectedMonitor: NetworkMonitor?
    @StateObject private var favorites = FavoritesManager.shared
    @StateObject private var auth = AuthService.shared

    private var monitor: NetworkMonitor { injectedMonitor ?? .shared }

    @State private var recipes: [Recipe] = []   // ordre serveur (created_at DESC)
    @State private var isLoading = false
    /// Panne du dernier chargement. Distincte d'un carnet vide : un carnet qui
    /// contient des favoris mais ne peut pas les charger n'est pas un carnet vide.
    @State private var loadError: APIError?
    @State private var keyword = ""
    @State private var filterCategory: String? = nil
    @State private var filterSeason: String? = nil
    @State private var selectedSortID: String = FavoritesView.defaultSortID
    @State private var showFilterSheet = false
    @State private var showLogin = false

    private static let defaultSortID = "recent"

    /// Options de tri **propres au Carnet** (tri local, l'API renvoie déjà
    /// l'ordre d'ajout). Distinctes de « Toutes les recettes » (tri serveur).
    private static let sortOptions: [RecipeSortOption] = [
        RecipeSortOption(id: "recent", label: "Récemment ajoutées"),
        RecipeSortOption(id: "title_asc", label: "Titre A → Z"),
    ]

    /// Filtrage **local** (mot-clé + taxonomies) puis tri local. `RecipeFilterBar.apply`
    /// préserve l'ordre serveur ; le tri par titre est appliqué par-dessus.
    private var filtered: [Recipe] {
        let base = RecipeFilterBar.apply(recipes, keyword: keyword, categorySlug: filterCategory, seasonSlug: filterSeason)
        switch selectedSortID {
        case "title_asc":
            return base.sorted { $0.cleanTitle.localizedCaseInsensitiveCompare($1.cleanTitle) == .orderedAscending }
        default:
            return base   // ordre serveur (récemment ajoutées)
        }
    }

    private var hasActiveFilter: Bool {
        filterCategory != nil || filterSeason != nil || selectedSortID != Self.defaultSortID
    }

    /// Termes de taxonomie **réellement présents** dans les favoris chargés.
    private func presentOptions(_ taxonomy: String, icon: (String) -> String) -> [RecipeFilterOption] {
        var seen = Set<String>()
        var out: [RecipeFilterOption] = []
        for recipe in recipes {
            for term in recipe.embeddedTerms(taxonomy) where seen.insert(term.slug).inserted {
                out.append(RecipeFilterOption(slug: term.slug, name: term.name, systemImage: icon(term.slug)))
            }
        }
        return out
    }

    var body: some View {
        NavigationStack {
            Group {
                if !auth.isLoggedIn {
                    signedOutState
                } else if favorites.favoriteIDs.isEmpty {
                    ContentUnavailableView(
                        "Aucun favori pour l'instant",
                        systemImage: "heart",
                        description: Text("Appuyez sur le cœur d'une recette pour la retrouver ici.")
                    )
                } else if isLoading && recipes.isEmpty {
                    ScrollView {
                        SkeletonRecipeList()
                    }
                    .scrollDisabled(true)
                } else if let loadError, recipes.isEmpty {
                    // Erreur seulement si l'écran n'a rien à montrer : une panne
                    // survenue sur un rafraîchissement ne remplace pas un carnet
                    // déjà affiché.
                    TypedErrorView(error: loadError) {
                        await loadFavorites()
                    }
                } else {
                    scrollContent
                }
            }
            .navigationTitle("Mon carnet de recettes")
            // Barre système, même style et même placement que l'onglet
            // « Recherche » : `navigationBarDrawer(.always)` l'épingle sous le
            // titre au lieu de la cacher au-dessus du contenu défilable. Comme
            // le bouton filtres, elle ne s'affiche que s'il y a des favoris.
            .searchable(
                when: auth.isLoggedIn && !favorites.favoriteIDs.isEmpty,
                text: $keyword,
                prompt: "Chercher dans le carnet…"
            )
            .toolbar {
                // Bouton filtres aligné sur « Toutes les recettes » : n'apparaît
                // que lorsqu'il y a des favoris à filtrer.
                if auth.isLoggedIn && !favorites.favoriteIDs.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        FilterToolbarButton(hasActiveFilter: hasActiveFilter) {
                            showFilterSheet = true
                        }
                    }
                }
            }
            .sheet(isPresented: $showLogin) { LoginView() }
            .sheet(isPresented: $showFilterSheet) {
                RecipeFilterSheet(
                    sortOptions: Self.sortOptions,
                    selectedSortID: $selectedSortID,
                    seasons: presentOptions(RecipeTaxonomy.season) { TaxonomyIcon.season($0) },
                    seasonSlug: $filterSeason,
                    categories: presentOptions(RecipeTaxonomy.category) { TaxonomyIcon.dish($0) },
                    categorySlug: $filterCategory,
                    defaultSortID: Self.defaultSortID,
                    // Filtrage local live : « Appliquer » ne fait que fermer la
                    // feuille, la liste est déjà recalculée par `filtered`.
                    onApply: {}
                )
            }
        }
        // Rechargé quand les favoris changent, à chaque changement de session
        // (l'ordre serveur et le verrouillage dépendent du jeton) **et** à
        // chaque bascule de connectivité : le retour du réseau doit reprendre la
        // main sur la reconstruction locale, et sa perte l'inverse.
        .task(id: "\(favorites.favoriteIDs.hashValue)|\(auth.contentGeneration)|\(monitor.isConnected)") {
            await loadFavorites()
        }
        .onAppear { UmamiTracker.shared.trackScreen(path: "/carnet", title: "Carnet") }
    }

    /// État vide du **visiteur** : le carnet étant synchronisé au compte, il n'y a
    /// rien à afficher hors session. On explique et on propose la connexion,
    /// plutôt que le « Aucun favori » du connecté qui laissait croire à un bug.
    private var signedOutState: some View {
        ContentUnavailableView {
            Label("Votre carnet vous attend", systemImage: "heart.text.square")
        } description: {
            Text("Connectez-vous pour enregistrer vos recettes et les retrouver sur tous vos appareils.")
        } actions: {
            Button {
                showLogin = true
            } label: {
                Text("Se connecter")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.accent180)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .buttonStyle(.plain)
        }
    }

    // Le champ de recherche est la barre système (`.searchable`), épinglée sous
    // le titre comme sur « Recherche ». Le tri et les filtres taxonomiques sont
    // dans la bottom sheet (bouton de barre d'outils), comme sur « Toutes les
    // recettes ».
    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if filtered.isEmpty {
                    ContentUnavailableView(
                        "Aucune recette",
                        systemImage: "line.3.horizontal.decrease",
                        description: Text("Aucun favori ne correspond à ces filtres.")
                    )
                    .padding(.top, 40)
                } else if horizontalSizeClass == .regular {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        ForEach(filtered) { recipe in
                            recipeLink(recipe) { RecipeCard(recipe: recipe).frame(maxWidth: .infinity) }
                        }
                    }
                    .padding(.horizontal)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { recipe in
                            recipeLink(recipe) { RecipeCard(recipe: recipe, style: .row) }
                                .padding(.horizontal)
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .refreshable {
            APIService.shared.clearImageCaches()
            await loadFavorites()
        }
    }

    private func recipeLink<Content: View>(_ recipe: Recipe, @ViewBuilder content: () -> Content) -> some View {
        NavigationLink(destination: RecipeDetailView(recipe: recipe)) {
            content()
        }
        .buttonStyle(.plain)
    }

    private func loadFavorites() async {
        guard !favorites.favoriteIDs.isEmpty else {
            recipes = []
            loadError = nil
            return
        }

        isLoading = true

        // Hors ligne : le carnet se reconstruit intégralement depuis les fiches
        // téléchargées, sans toucher au réseau.
        if !monitor.isConnected {
            await loadFromOfflineStore()
            isLoading = false
            return
        }

        // Ordre serveur (created_at DESC) si connecté, sinon cache local. On NE
        // re-trie PAS côté client : l'ordre des IDs fait foi.
        let ids: [Int]
        if AuthService.shared.getToken() != nil,
           let serverIDs = try? await APIService.shared.fetchFavoriteIDs(),
           !serverIDs.isEmpty {
            ids = serverIDs
        } else {
            ids = Array(favorites.favoriteIDs)
        }

        do {
            let loaded = try await APIService.shared.fetchRecipesByIDs(ids)
            let byID = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            recipes = ids.compactMap { byID[$0] }
            loadError = nil
        } catch {
            let apiError = APIError.from(error)
            AppLogger.api.error("Erreur favoris: \(apiError.localizedDescription)")
            loadError = apiError
        }

        isLoading = false
    }

    /// Reconstruit le carnet depuis l'`OfflineStore`.
    ///
    /// L'ordre serveur (`created_at DESC`) n'est pas disponible hors ligne — les
    /// IDs locaux vivent dans un `Set`. On retombe sur la date de téléchargement
    /// décroissante, qui suit l'ordre d'ajout dans l'immense majorité des cas.
    ///
    /// Aucune fiche téléchargée alors que le carnet en contient ⇒ état `Offline`
    /// typé : le carnet n'est pas vide, il est hors de portée.
    private func loadFromOfflineStore() async {
        let store = OfflineStore.shared
        let ids = store.allMetadata()
            .filter { favorites.favoriteIDs.contains($0.id) }
            .sorted { $0.downloadedAt > $1.downloadedAt }
            .map(\.id)

        let loaded = await store.load(ids: ids)
        recipes = loaded
        loadError = loaded.isEmpty ? .offline : nil
    }
}

private extension View {
    /// `.searchable` conditionnel : la barre de recherche système n'a de sens
    /// que lorsqu'il y a effectivement quelque chose à filtrer.
    @ViewBuilder
    func searchable(when condition: Bool, text: Binding<String>, prompt: String) -> some View {
        if condition {
            searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
        } else {
            self
        }
    }
}
