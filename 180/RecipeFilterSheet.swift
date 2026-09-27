import SwiftUI

/// Option de tri générique (id opaque + libellé affiché).
struct RecipeSortOption: Identifiable, Equatable {
    let id: String
    let label: String
}

/// Option de filtre taxonomique (slug + nom + icône SF Symbol optionnelle).
struct RecipeFilterOption: Identifiable, Equatable {
    let slug: String
    let name: String
    let systemImage: String?

    var id: String { slug }
}

/// Feuille de filtres/tri **réutilisable**, présentée en bottom sheet
/// (`presentationDetents([.medium, .large])`).
///
/// Extrait de l'écran « Toutes les recettes » (`RecipeListView`) pour être
/// partagé avec « Mon carnet de recettes » (`FavoritesView`) : les deux écrans
/// présentent désormais tri + filtres dans la même UX. Le composant ne connaît
/// ni la source des données ni le mode de filtrage (serveur ou local) : il
/// expose des sélections via `@Binding` et notifie `onApply` à la validation.
struct RecipeFilterSheet: View {
    let sortOptions: [RecipeSortOption]
    @Binding var selectedSortID: String

    let seasons: [RecipeFilterOption]
    @Binding var seasonSlug: String?

    let categories: [RecipeFilterOption]
    @Binding var categorySlug: String?

    /// Valeur de tri par défaut (bouton « Réinitialiser »).
    let defaultSortID: String
    var onApply: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var hasActiveFilter: Bool {
        seasonSlug != nil || categorySlug != nil || selectedSortID != defaultSortID
    }

    var body: some View {
        NavigationStack {
            List {
                if !sortOptions.isEmpty {
                    Section("Trier par") {
                        ForEach(sortOptions) { option in
                            row(option.label, isOn: selectedSortID == option.id) {
                                selectedSortID = option.id
                            }
                        }
                    }
                }

                if !seasons.isEmpty {
                    Section("Saison") {
                        row("Toutes", isOn: seasonSlug == nil) { seasonSlug = nil }
                        ForEach(seasons) { season in
                            row(season.name, systemImage: season.systemImage,
                                isOn: seasonSlug == season.slug) {
                                seasonSlug = seasonSlug == season.slug ? nil : season.slug
                            }
                        }
                    }
                }

                if !categories.isEmpty {
                    Section("Type de plat") {
                        row("Tous", isOn: categorySlug == nil) { categorySlug = nil }
                        ForEach(categories) { category in
                            row(category.name, systemImage: category.systemImage,
                                isOn: categorySlug == category.slug) {
                                categorySlug = categorySlug == category.slug ? nil : category.slug
                            }
                        }
                    }
                }

                if hasActiveFilter {
                    Section {
                        Button(role: .destructive) {
                            selectedSortID = defaultSortID
                            seasonSlug = nil
                            categorySlug = nil
                        } label: {
                            HStack {
                                Spacer()
                                Text("Réinitialiser les filtres")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Filtres")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Appliquer") {
                        onApply()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(.accent180)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func row(_ title: String, systemImage: String? = nil, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundColor(.accent180)
                        .frame(width: 24)
                }
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
                if isOn {
                    Image(systemName: "checkmark").foregroundColor(.accent180)
                }
            }
        }
    }
}

/// Bouton « Filtres » de barre d'outils, partagé (pastille = filtre actif).
struct FilterToolbarButton: View {
    let hasActiveFilter: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(.systemGray5))
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                )
                .overlay(alignment: .topTrailing) {
                    if hasActiveFilter {
                        Circle()
                            .fill(Color.accent180)
                            .frame(width: 8, height: 8)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filtres")
        .accessibilityValue(hasActiveFilter ? "actifs" : "aucun")
    }
}
