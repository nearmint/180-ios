import SwiftUI
import os

/// Écran de recherche
struct SearchView: View {

    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @State private var searchText = ""
    @State private var results: [Recipe] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    /// Panne de la dernière recherche. Distincte d'un résultat vide : une
    /// coupure réseau ne doit jamais être présentée comme « aucune recette ».
    @State private var searchError: APIError?

    @State private var recentSearches: [String] = []
    @StateObject private var taxonomy = TaxonomyStore.shared
    @StateObject private var auth = AuthService.shared

    private func loadRecentSearches() {
        if let data = UserDefaults.standard.data(forKey: "recentSearches"),
           let searches = try? JSONDecoder().decode([String].self, from: data) {
            recentSearches = searches
        }
    }

    private func addToRecentSearches(_ query: String) {
        var searches = recentSearches
        searches.removeAll { $0.lowercased() == query.lowercased() }
        searches.insert(query, at: 0)
        if searches.count > 5 { searches = Array(searches.prefix(5)) }
        recentSearches = searches
        if let data = try? JSONEncoder().encode(searches) {
            UserDefaults.standard.set(data, forKey: "recentSearches")
        }
    }

    private func removeRecentSearch(_ query: String) {
        var searches = recentSearches
        searches.removeAll { $0 == query }
        recentSearches = searches
        if let data = try? JSONEncoder().encode(searches) {
            UserDefaults.standard.set(data, forKey: "recentSearches")
        }
    }

    private func clearRecentSearches() {
        recentSearches = []
        UserDefaults.standard.removeObject(forKey: "recentSearches")
    }

    var body: some View {
        NavigationStack {
            Group {
                if !hasSearched {
                    // État initial : historique + suggestions
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {

                            // Recherches récentes
                            if !recentSearches.isEmpty {
                                Text("Recherches récentes")
                                    .font(.title3)
                                    .fontWeight(.bold)
                                    .padding(.horizontal)

                                ForEach(recentSearches, id: \.self) { search in
                                    Button {
                                        Haptics.selection()
                                        searchText = search
                                        Task { await performSearch() }
                                    } label: {
                                        HStack(spacing: 14) {
                                            Image(systemName: "clock.arrow.circlepath")
                                                .font(.title3)
                                                .foregroundColor(.gray)
                                                .frame(width: 36)
                                            Text(search)
                                                .foregroundColor(.primary)
                                            Spacer()
                                            Button {
                                                removeRecentSearch(search)
                                            } label: {
                                                Image(systemName: "xmark")
                                                    .font(.caption)
                                                    .foregroundColor(.gray)
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityLabel("Supprimer « \(search) » de l'historique")
                                        }
                                        .padding(.horizontal)
                                        .padding(.vertical, 6)
                                    }
                                }
                            }

                            SectionHeader(title: "Explorer par saison")

                            ForEach(taxonomy.seasons) { season in
                                NavigationLink(destination: RecipeListView(title: season.name, seasonSlug: season.slug)) {
                                    HStack(spacing: 14) {
                                        Image(systemName: TaxonomyIcon.season(season.slug))
                                            .font(.title3)
                                            .foregroundColor(.accent180)
                                            .frame(width: 36)

                                        Text(season.name)
                                            .foregroundColor(.primary)

                                        Spacer()

                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal)
                                    .padding(.vertical, 6)
                                }
                            }

                            SectionHeader(title: "Explorer par type")

                            ForEach(taxonomy.dishCategories) { type in
                                NavigationLink(destination: RecipeListView(title: type.name, categorySlug: type.slug)) {
                                    HStack(spacing: 14) {
                                        Image(systemName: TaxonomyIcon.dish(type.slug))
                                            .font(.title3)
                                            .foregroundColor(.accent180)
                                            .frame(width: 36)

                                        Text(type.name)
                                            .foregroundColor(.primary)

                                        Spacer()

                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal)
                                    .padding(.vertical, 6)
                                }
                            }
                        }
                        .padding(.top)
                    }
                } else if isSearching {
                    ScrollView {
                        SkeletonRecipeList()
                    }
                    .scrollDisabled(true)
                } else if let searchError {
                    // La panne prime sur l'état vide : `results` est vide parce
                    // que la requête a échoué, pas parce que rien ne correspond.
                    TypedErrorView(error: searchError) {
                        await performSearch()
                    }
                } else if results.isEmpty {
                    ContentUnavailableView(
                        "Aucune recette trouvée",
                        systemImage: "fork.knife",
                        description: Text("Essayez avec d'autres mots-clés.")
                    )
                } else {
                    VStack(spacing: 0) {
                        Text("\(results.count) recette\(results.count > 1 ? "s" : "") trouvée\(results.count > 1 ? "s" : "")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if horizontalSizeClass == .regular {
                            // iPad : grille adaptative 2-3 colonnes
                            ScrollView {
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 280, maximum: 400))],
                                    spacing: 14
                                ) {
                                    ForEach(results) { recipe in
                                        NavigationLink(destination: RecipeDetailView(recipe: recipe)) {
                                            RecipeCard(recipe: recipe, style: .row)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding()
                            }
                            .refreshable {
                                APIService.shared.clearImageCaches()
                                await performSearch()
                            }
                        } else {
                            List(results) { recipe in
                                NavigationLink(destination: RecipeDetailView(recipe: recipe)) {
                                    RecipeCard(recipe: recipe, style: .row)
                                }
                            }
                            .listStyle(.plain)
                            .refreshable {
                                APIService.shared.clearImageCaches()
                                await performSearch()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Recherche")
            // `placement` explicite : par défaut iOS loge la barre au-dessus du
            // contenu défilable, si bien que l'écran s'ouvrait déjà scrollé et
            // que le champ n'était visible qu'après un tirage vers le bas. En
            // `navigationBarDrawer(displayMode: .always)` elle est épinglée sous
            // le titre, visible d'emblée.
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Chercher une recette…"
            )
            .onSubmit(of: .search) {
                Task { await performSearch() }
            }
            .onChange(of: searchText) { _, newValue in
                if newValue.isEmpty {
                    Task { @MainActor in
                        hasSearched = false
                        results = []
                        searchError = nil
                    }
                }
            }
            .onAppear {
                loadRecentSearches()
                UmamiTracker.shared.trackScreen(path: "/recherche", title: "Recherche")
            }
            // Rejoué à chaque changement de session : une recherche déjà
            // affichée est relancée pour rafraîchir le verrouillage des recettes.
            .task(id: auth.contentGeneration) {
                await taxonomy.loadIfNeeded()
                if hasSearched { await performSearch() }
            }
        }
        // Hors de la pile de navigation : le bandeau coiffe la barre de
        // recherche au lieu de s'intercaler entre elle et les résultats.
        .offlineBanner()
    }

    private func performSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }

        // Mesuré au **lancement** de la recherche, avant l'appel réseau : une
        // recherche qui échoue reste une recherche lancée.
        UmamiTracker.shared.trackEvent(name: "recipe_search", data: [
            "query": String(query.lowercased().prefix(50))
        ])

        await MainActor.run {
            isSearching = true
            hasSearched = true
            searchError = nil
        }

        do {
            let searchResults = try await APIService.shared.searchRecipes(query: query)
            await MainActor.run {
                results = searchResults
                searchError = nil
                isSearching = false
                addToRecentSearches(query)
                AnalyticsService.search(query: query, resultsCount: searchResults.count)
            }
        } catch {
            let apiError = APIError.from(error)
            AppLogger.api.error("Erreur recherche: \(apiError.localizedDescription)")
            await MainActor.run {
                // La recherche n'est pas ajoutée à l'historique : on n'archive
                // pas un terme dont on ignore s'il donne quelque chose.
                results = []
                searchError = apiError
                isSearching = false
            }
        }
    }
}
