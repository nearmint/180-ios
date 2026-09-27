import SwiftUI

/// Barre de filtres locale réutilisable (Carnet) : champ de recherche + une
/// **icône filtre** (à droite) ouvrant un `Menu` natif (dropdown) regroupant
/// type de plat (`recipe_category`) et saison (`recipe_season`). Les options
/// proposées sont les termes **réellement présents** dans la liste (via `_embed`),
/// le filtrage est purement local. Le composant n'est pas sticky : il se place
/// dans le flux scrollable de l'écran appelant.
struct RecipeFilterBar: View {
    let recipes: [Recipe]
    @Binding var keyword: String
    @Binding var categorySlug: String?
    @Binding var seasonSlug: String?

    private var presentCategories: [EmbeddedTerm] { uniqueTerms(RecipeTaxonomy.category) }
    private var presentSeasons: [EmbeddedTerm] { uniqueTerms(RecipeTaxonomy.season) }
    private var hasActiveFilter: Bool { categorySlug != nil || seasonSlug != nil }

    var body: some View {
        HStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Rechercher dans le carnet", text: $keyword)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !keyword.isEmpty {
                    Button {
                        keyword = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Effacer la recherche")
                }
            }
            .padding(10)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            filterMenu
        }
        .padding(.horizontal)
    }

    private var filterMenu: some View {
        Menu {
            if !presentCategories.isEmpty {
                Section("Type de plat") {
                    option("Tous", isOn: categorySlug == nil) { categorySlug = nil }
                    ForEach(presentCategories) { term in
                        option(term.name, isOn: categorySlug == term.slug) {
                            categorySlug = categorySlug == term.slug ? nil : term.slug
                        }
                    }
                }
            }
            if !presentSeasons.isEmpty {
                Section("Saison") {
                    option("Toutes", isOn: seasonSlug == nil) { seasonSlug = nil }
                    ForEach(presentSeasons) { term in
                        option(term.name, isOn: seasonSlug == term.slug) {
                            seasonSlug = seasonSlug == term.slug ? nil : term.slug
                        }
                    }
                }
            }
            if hasActiveFilter {
                Button(role: .destructive) {
                    categorySlug = nil
                    seasonSlug = nil
                } label: {
                    Label("Réinitialiser les filtres", systemImage: "arrow.counterclockwise")
                }
            }
        } label: {
            Image(systemName: hasActiveFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.title2)
                .foregroundColor(hasActiveFilter ? .accent180 : .secondary)
        }
        .accessibilityLabel(Text("Filtres"))
    }

    @ViewBuilder
    private func option(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isOn {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    /// Termes uniques présents dans la liste pour une taxonomie donnée.
    private func uniqueTerms(_ taxonomy: String) -> [EmbeddedTerm] {
        var seen = Set<String>()
        var out: [EmbeddedTerm] = []
        for recipe in recipes {
            for term in recipe.embeddedTerms(taxonomy) where seen.insert(term.slug).inserted {
                out.append(term)
            }
        }
        return out
    }
}

extension RecipeFilterBar {
    /// Applique les filtres à une liste (préserve l'ordre d'entrée).
    static func apply(_ recipes: [Recipe], keyword: String, categorySlug: String?, seasonSlug: String?) -> [Recipe] {
        let kw = keyword.trimmingCharacters(in: .whitespaces).lowercased()
        return recipes.filter { recipe in
            if !kw.isEmpty && !recipe.cleanTitle.lowercased().contains(kw) { return false }
            if let categorySlug, !recipe.categorySlugs.contains(categorySlug) { return false }
            if let seasonSlug, !recipe.seasonSlugs.contains(seasonSlug) { return false }
            return true
        }
    }
}
