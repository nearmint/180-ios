import SwiftUI

/// Rayon d'arrondi unique des cartes (équivalent token `--radius` web).
enum AppRadius {
    static let card: CGFloat = 14
}

/// Carte recette **unique**, alignée sur le composant web `recipe-card`.
///
/// Image en tête (`scaledToFill` + `clipped`, coins arrondis, jamais croppée
/// au-delà du ratio) puis, SOUS l'image : label type de plat
/// (`recipe_category`) · titre · saison (`recipe_season`). **Jamais de texte
/// en overlay sur la photo** (contrainte éditoriale) ; seul le bouton favori
/// (icône) est en incrustation. Trois présentations partagent ce langage visuel.
struct RecipeCard: View {
    let recipe: Recipe
    var style: Style = .standard

    enum Style {
        case standard   // rail horizontal (largeur fixe)
        case featured   // hero pleine largeur
        case row        // ligne horizontale (recherche / listes)
        case grid       // cellule de grille (largeur flexible)
    }

    @ObservedObject private var favorites = FavoritesManager.shared
    @ObservedObject private var auth = AuthService.shared
    /// `@Observable` : la lecture de `isEnabled` dans `body` suffit à établir le
    /// suivi, aucun property wrapper n'est requis.
    private let offlineSync = OfflineSyncService.shared

    var body: some View {
        switch style {
        case .row:
            rowBody
        default:
            verticalBody
        }
    }

    // MARK: Présentation verticale (standard / featured / grid)

    private var isFeatured: Bool { style == .featured }
    private var fixedWidth: CGFloat? { style == .standard ? 200 : nil }
    private var fillsWidth: Bool { style == .featured || style == .grid }

    private var verticalBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            recipeImage
                .frame(width: fixedWidth)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .frame(height: isFeatured ? 300 : 150)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
                .overlay(alignment: .topTrailing) { favoriteButton }

            categoryLabel
            Text(recipe.cleanTitle)
                .font(AppFont.playfair(isFeatured ? 26 : 18, weight: .bold))
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 5) {
                seasonLabel
                offlineBadge
            }
        }
        .frame(width: fixedWidth, alignment: .leading)
    }

    // MARK: Présentation ligne (recherche / listes)

    private var rowBody: some View {
        HStack(spacing: 12) {
            recipeImage
                .frame(width: 96, height: 96)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                categoryLabel
                Text(recipe.cleanTitle)
                    .font(AppFont.playfair(17, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    seasonLabel
                    offlineBadge
                }
            }

            Spacer(minLength: 8)

            favoriteIcon
        }
        .padding(.vertical, 4)
    }

    // MARK: Briques partagées

    private var recipeImage: some View {
        // Visuel décoratif : le titre/labels sont lus séparément par VoiceOver.
        // `maxRenderWidth` calé sur la taille réelle d'affichage du style → le
        // downsampling ImageIO ne décode pas plus de pixels que nécessaire.
        CachedAsyncImage(url: recipe.imageURL.flatMap { URL(string: $0) }, maxRenderWidth: imageMaxWidth)
            .accessibilityHidden(true)
    }

    /// Plus grand côté rendu (points) selon la présentation de la carte.
    private var imageMaxWidth: CGFloat {
        switch style {
        case .row: return 120        // vignette 96 pt
        case .standard, .grid: return 240
        case .featured: return 450   // hero pleine largeur
        }
    }

    @ViewBuilder
    private var categoryLabel: some View {
        if let category = recipe.categoryName, !category.isEmpty {
            Text(category.uppercased())
                .font(AppFont.oswald(11, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(.accent180)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var seasonLabel: some View {
        // Masqué sur la carte « à la une » (demande produit) : le hero ne porte
        // pas le tag saison. Les autres présentations (rail, grille, ligne)
        // continuent de l'afficher.
        if !isFeatured, let season = recipe.seasonName, !season.isEmpty {
            Text(season)
                .font(AppFont.oswald(12))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    /// Marqueur discret « disponible hors ligne ».
    ///
    /// Une icône, pas un libellé : sur une carte de 200 pt, un texte
    /// concurrencerait le titre pour une information secondaire. Le libellé
    /// complet reste lu par VoiceOver.
    ///
    /// Masqué sur la carte « à la une », comme le tag saison — le hero ne porte
    /// aucune métadonnée. Affiché en ligne comme hors ligne : c'est justement
    /// avant de perdre le réseau qu'il est utile de savoir ce qu'on emporte.
    @ViewBuilder
    private var offlineBadge: some View {
        if !isFeatured, offlineSync.isEnabled, OfflineStore.shared.has(recipe.id) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption2)
                .foregroundColor(.secondary)
                .accessibilityLabel("Disponible hors ligne")
        }
    }

    /// Favori **du point de vue de l'affichage**.
    ///
    /// Hors session le carnet n'existe pas : un résidu local (`UserDefaults`,
    /// favori posé avant la mise en place du gating) ne doit pas afficher un
    /// cœur plein et rouge à un visiteur — l'icône serait à la fois remplie et
    /// intouchable. Le rendu rempli est donc conditionné à la session, pas
    /// seulement l'interaction.
    private var showsAsFavorite: Bool {
        auth.isLoggedIn && favorites.isFavorite(recipe.id)
    }

    private var favoriteButton: some View {
        Button {
            favorites.toggle(recipe.id, title: recipe.cleanTitle, slug: recipe.slug)
        } label: {
            Image(systemName: showsAsFavorite ? "heart.fill" : "heart")
                .foregroundColor(showsAsFavorite ? .red : .white)
                .font(.subheadline)
                .padding(8)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(favoriteLabel)
        .padding(8)
        .modifier(FavoriteGate(isLoggedIn: auth.isLoggedIn))
    }

    private var favoriteIcon: some View {
        Button {
            favorites.toggle(recipe.id, title: recipe.cleanTitle, slug: recipe.slug)
        } label: {
            Image(systemName: showsAsFavorite ? "heart.fill" : "heart")
                .foregroundColor(showsAsFavorite ? .red : .gray)
                .font(.title3)
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(favoriteLabel)
        .modifier(FavoriteGate(isLoggedIn: auth.isLoggedIn))
    }

    private var favoriteLabel: Text {
        Text(showsAsFavorite ? "Retirer des favoris" : "Ajouter aux favoris")
    }
}

/// Verrou visuel du bouton favori hors session.
///
/// Le carnet est un service **de compte** (synchronisé serveur) : sans jeton il
/// n'y a rien à quoi rattacher un favori. Le bouton reste visible mais inerte et
/// atténué — la fonctionnalité reste ainsi découvrable, et l'écran Favoris
/// explique comment y accéder. `FavoritesManager.toggle` refuse de son côté
/// toute écriture hors session (défense en profondeur).
struct FavoriteGate: ViewModifier {
    let isLoggedIn: Bool

    func body(content: Content) -> some View {
        content
            .disabled(!isLoggedIn)
            .opacity(isLoggedIn ? 1 : 0.35)
            .accessibilityHint(isLoggedIn ? Text("") : Text("Connectez-vous pour utiliser les favoris"))
    }
}

/// Variante hero « à la une » — même langage visuel, pleine largeur.
struct FeaturedRecipeCard: View {
    let recipe: Recipe
    var body: some View { RecipeCard(recipe: recipe, style: .featured) }
}
