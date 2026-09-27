import SwiftUI
import os

/// Écran d'accueil — piloté par l'endpoint `180c/v1/home-recettes`.
///
/// Rend les blocs de la composition `/recettes/` **dans l'ordre** ; les rails
/// sont hydratés via `wp/v2/recipe?include=`. Plus aucun rail/carrousel ni liste
/// saison/type codés en dur (cf. TaxonomyStore pour les listes dynamiques).
///
/// Le contenu est **intégralement** piloté par le Home Builder : chaque section
/// visible correspond à un module composé en back-office, aucune n'est ajoutée
/// en dur. Une composition vide donne donc un écran vide — seul l'en-tête (logo
/// et cloche de notifications), qui relève de la navigation et non du contenu,
/// subsiste.
struct HomeView: View {

    @Environment(\.colorScheme) var colorScheme
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @StateObject private var notifManager = NotificationManager.shared
    @StateObject private var auth = AuthService.shared

    @State private var blocks: [HomeBlock] = []
    @State private var hydrated: [Int: [Recipe]] = [:]   // index du bloc → recettes
    @State private var carnetRecipes: [Recipe] = []
    @State private var allRecipes: [Recipe] = []         // 16 dernières publiées
    @State private var isLoading = true
    @State private var loadError = false
    /// `true` dès qu'une composition a été décodée, **même vide**.
    ///
    /// Distingue les deux façons d'afficher zéro bloc : une composition
    /// réellement vide en back-office (écran vide, légitime) et un payload
    /// jamais obtenu (réseau ou serveur en panne → état d'erreur). Sans ce
    /// témoin, retirer tous les modules dans WordPress afficherait un mur
    /// d'erreur trompeur.
    @State private var hasLoadedComposition = false
    /// Nature de la panne, pour un état d'erreur **typé** plutôt qu'un message
    /// figé. `HomeService` absorbe les erreurs (il rend un instantané ou `nil`) :
    /// c'est le `NetworkMonitor` qui tranche entre « hors ligne » et « le
    /// serveur ne répond pas ».
    @State private var loadErrorKind: APIError = .serverError

    /// Pile de navigation **explicite** : tous les liens de l'accueil poussent une
    /// valeur (`Recipe` ou `HomeLink`) via des `Button`, plutôt que des
    /// `NavigationLink` imbriqués dont le hit-testing dans un `ScrollView` était
    /// non déterministe. `NavigationPath` gère les types hétérogènes Hashable.
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    if isLoading && blocks.isEmpty {
                        loadingState
                    } else if loadError && blocks.isEmpty {
                        errorState
                    } else {
                        // L'accueil est **intégralement** piloté par le Home
                        // Builder : aucune section n'est ajoutée en dur après les
                        // blocs. Composition vide en back-office ⇒ écran vide,
                        // et non un contenu de repli que personne n'a demandé.
                        ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                            blockView(block, index: index)
                        }
                    }

                    Spacer(minLength: 30)
                }
                .padding(.top, 0)
            }
            .scrollIndicators(.hidden)
            .navigationBarHidden(true)
            // Header ÉPINGLÉ hors du contenu scrollable, fond OPAQUE : il ne
            // partage plus la surface de scroll ni le hit-testing avec la carte à
            // la une (cause racine du bug tap cloche/logo → recette à la une). Le
            // fond ignore la safe area haute pour couvrir la barre d'état quand le
            // contenu défile dessous.
            .safeAreaInset(edge: .top, spacing: 0) {
                header
                    .background(Color(.systemBackground).ignoresSafeArea(edges: .top))
            }
            .refreshable {
                APIService.shared.clearImageCaches()
                await loadData()
            }
            // Navigation **par valeur** (déterministe) : chaque lien pousse une
            // valeur typée résolue ici. Élimine le bug des `NavigationLink(
            // destination:)` empilés où un tap sur une zone inerte (logo) ou sur
            // l'en-tête activait la recette à la une.
            .navigationDestination(for: Recipe.self) { recipe in
                RecipeDetailView(recipe: recipe)
            }
            .navigationDestination(for: HomeLink.self) { link in
                switch link {
                case .notifications:
                    NotificationsView()
                case .allRecipes:
                    RecipeListView(title: "Toutes les recettes", showFilters: true)
                case let .list(title, categorySlug, seasonSlug, publicationSlug):
                    RecipeListView(
                        title: title,
                        categorySlug: categorySlug,
                        seasonSlug: seasonSlug,
                        publicationSlug: publicationSlug
                    )
                }
            }
        }
        // Bandeau au-dessus de la pile de navigation : il coiffe l'en-tête
        // épinglé de l'accueil au lieu de défiler avec le contenu.
        .offlineBanner()
        // `contentGeneration` change à chaque login/logout : l'accueil est
        // rechargé avec le nouveau jeton (rail Carnet, verrouillage des cartes).
        .task(id: auth.contentGeneration) { await loadData() }
        .onAppear { UmamiTracker.shared.trackScreen(path: "/", title: "Accueil") }
    }

    // MARK: - En-tête (logo + notifications)

    private var header: some View {
        HStack {
            // Logo inerte : au lieu de `.allowsHitTesting(false)` (qui laissait le
            // tap TRAVERSER vers la vue hit-testable en dessous), le logo
            // **capte et absorbe** le tap via un `onTapGesture` no-op → aucun
            // pass-through possible, aucune navigation déclenchée.
            Image("logo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundColor(colorScheme == .dark ? .white : .black)
                .frame(height: 54)
                .contentShape(Rectangle())
                .onTapGesture { }
                .homeHitDebug("logo")

            Spacer()

            // Cloche = lien **par valeur** résolu par `navigationDestination(
            // for: HomeLink.self)`. Tous les liens de l'accueil sont désormais
            // par valeur (recettes ou HomeLink) : plus aucune ambiguïté d'arbitrage.
            Button {
                path.append(HomeLink.notifications)
            } label: {
                ZStack(alignment: .topTrailing) {
                    Circle()
                        .fill(Color(.systemGray5))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Image(systemName: "bell")
                                .font(.body)
                                .foregroundColor(.primary)
                        )
                    // Pastille jaune : au moins une notification non lue OU
                    // abonnement push non effectif — qu'il s'agisse d'une
                    // autorisation refusée/absente OU d'un opt-out depuis Mon compte
                    // (même signalétique, source de vérité unique).
                    if notifManager.unreadCount > 0 || !notifManager.pushEffectivelyEnabled {
                        Circle()
                            .fill(Color.accent180)
                            .frame(width: 10, height: 10)
                            .offset(x: 2, y: -2)
                    }
                }
                // Zone tactile = le disque complet de 44 pt (minimum Apple), y
                // compris la pastille en débord, et non les seuls pixels dessinés.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Notifications")
            .accessibilityValue(notifManager.unreadCount > 0 ? "\(notifManager.unreadCount) non lues" : "")
            .homeHitDebug("cloche")
        }
        .padding(.horizontal)
        // Plus de `.padding(.top, 50)` : la safe area (via `safeAreaInset`) place
        // désormais le header sous la barre d'état. Padding vertical léger pour
        // l'aération ; `.zIndex(1)` retiré (obsolète, le header n'est plus dans le
        // flux scrollable).
        .padding(.vertical, 8)
        // Bande header **réservée** sur toute la largeur : surface de hit-testing
        // unique et opaque, aucun tap ne peut fuir vers le contenu.
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .homeHitDebug("header", border: .red)
    }

    // MARK: - États

    private var loadingState: some View {
        VStack(spacing: 20) {
            SkeletonFeaturedCard().frame(height: 340).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(0..<4, id: \.self) { _ in SkeletonRecipeCard() }
                }
                .padding(.horizontal)
            }
        }
    }

    private var errorState: some View {
        TypedErrorView(error: loadErrorKind) {
            await loadData()
        }
        .padding(.top, 40)
    }

    // MARK: - Rendu d'un bloc

    @ViewBuilder
    private func blockView(_ block: HomeBlock, index: Int) -> some View {
        switch block.type {
        case "featured":
            if let recipe = hydrated[index]?.first {
                Button {
                    path.append(recipe)
                } label: {
                    FeaturedRecipeCard(recipe: recipe)
                        // Zone tactile **strictement** bornée au visuel de la carte
                        // (aucun débordement au-delà de son cadre).
                        .contentShape(Rectangle())
                        .padding(.horizontal)
                }
                .buttonStyle(PressButtonStyle())
                .homeHitDebug("featured", border: .blue, fill: .green.opacity(0.2))
            }

        case "rail":
            if let recipes = hydrated[index], !recipes.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    railHeader(title: block.title, source: block.source, viewAllUrl: block.viewAllUrl)
                    // `variant: "slider"` (module back-office « Slider de
                    // recettes ») : mêmes données qu'un rail, présentation en
                    // carrousel de heros. Tout autre variant — y compris un
                    // futur variant inconnu — garde le rail dense.
                    if block.variant == "slider" {
                        RecipeSlider(recipes: recipes) { path.append($0) }
                    } else {
                        recipeRail(recipes)
                    }
                }
            }

        case "category_tiles":
            if let tiles = block.terms, !tiles.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: block.title)
                    tilesRow(tiles, taxonomy: block.taxonomy)
                }
            }

        case "carnet":
            if auth.isSubscriber && !carnetRecipes.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    carnetHeader(title: block.title.isEmpty ? "Mon carnet de recettes" : block.title)
                    recipeRail(carnetRecipes)
                }
            }

        case "grid_paginated":
            // Grille « Toutes les recettes » : le module qui occupait le bas de
            // l'accueil, désormais rendu **seulement** s'il est composé en
            // back-office. Il consomme les recettes récentes déjà chargées, pas
            // des `recipe_ids` : le serveur n'en sérialise pas pour ce layout.
            if !allRecipes.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: block.title.isEmpty ? "Toutes les recettes" : block.title)
                    allRecipesGrid
                    // L'app ne pagine pas dans l'accueil : l'accès à la suite
                    // passe par l'écran natif « Toutes les recettes », filtrable
                    // et triable. Le bouton appartient donc au module — il
                    // disparaît avec lui.
                    allRecipesButton
                }
            }

        default:
            // cta_subscribe (module abonnement toujours masqué — demande produit),
            // search / articles_rail / products_rail / collection_mosaic /
            // newsletter_form / separator / instagram_promo → pas encore rendus.
            EmptyView()
        }
    }

    /// Grille des 16 dernières recettes publiées (corps du module `grid_paginated`).
    private var allRecipesGrid: some View {
        // Colonnes ancrées en `.top` : cf. `recipeRail`, les cartes ont
        // des hauteurs libres et un alignement centré ferait démarrer
        // les plus courtes plus bas que leurs voisines de ligne.
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 14) {
            ForEach(allRecipes) { recipe in
                Button {
                    path.append(recipe)
                } label: {
                    RecipeCard(recipe: recipe, style: .grid)
                }
                .buttonStyle(PressButtonStyle())
            }
        }
        .padding(.horizontal)
    }

    /// Accès « Toutes les recettes » (liste filtrable), pied du module `grid_paginated`.
    private var allRecipesButton: some View {
        Button {
            path.append(HomeLink.allRecipes)
        } label: {
            HStack {
                Text("Voir toutes les recettes")
                    .font(.subheadline).fontWeight(.semibold)
                Image(systemName: "arrow.right")
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.accent180)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
        .padding(.horizontal)
    }

    // MARK: - Briques

    @ViewBuilder
    private func railHeader(title: String, source: String?, viewAllUrl: String?) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(AppFont.oswald(20, weight: .semibold))
                .foregroundColor(.primary)
            Spacer()
            // Le rail « Dernières recettes publiées » (source serveur `recent`,
            // view_all_url → /recettes/) doit ouvrir l'écran natif « Toutes les
            // recettes » (liste filtrable/triable), pas la page web. Les autres
            // rails éventuels conservent leur lien web via `view_all_url`.
            if source == "recent" {
                Button {
                    path.append(HomeLink.allRecipes)
                } label: {
                    voirToutLabel
                }
                .buttonStyle(.plain)
            } else if let urlString = viewAllUrl, let url = URL(string: urlString) {
                WebLink(url: url) {
                    voirToutLabel
                }
            }
        }
        .padding(.horizontal)
    }

    private var voirToutLabel: some View {
        HStack(spacing: 2) {
            Text("Voir tout").font(AppFont.oswald(14))
            Image(systemName: "chevron.right").font(.caption)
        }
        .foregroundColor(.accent180)
    }

    /// En-tête du rail Carnet avec « Voir tout » → onglet Favoris.
    private func carnetHeader(title: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(AppFont.oswald(20, weight: .semibold))
                .foregroundColor(.primary)
            Spacer()
            Button {
                TabRouter.shared.selected = TabRouter.Tab.favorites
            } label: {
                HStack(spacing: 2) {
                    Text("Voir tout").font(AppFont.oswald(14))
                    Image(systemName: "chevron.right").font(.caption)
                }
                .foregroundColor(.accent180)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
    }

    /// Rail de recettes.
    ///
    /// Conteneurs ancrés en **`.top`** : les cartes n'ont pas toutes la même
    /// hauteur (label catégorie et saison conditionnels, titre sur une ou deux
    /// lignes), et un alignement centré — le défaut de `HStack`/`GridItem` —
    /// recentrait verticalement les cartes courtes, faisant démarrer leur
    /// vignette quelques points plus bas que celle de leur voisine. Les images
    /// elles-mêmes sont déjà à hauteur identique : seul l'ancrage du conteneur
    /// était en cause.
    @ViewBuilder
    private func recipeRail(_ recipes: [Recipe]) -> some View {
        if horizontalSizeClass == .regular {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 14) {
                ForEach(recipes) { recipe in
                    Button {
                        path.append(recipe)
                    } label: {
                        RecipeCard(recipe: recipe).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PressButtonStyle())
                }
            }
            .padding(.horizontal)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(recipes) { recipe in
                        Button {
                            path.append(recipe)
                        } label: {
                            RecipeCard(recipe: recipe)
                        }
                        .buttonStyle(PressButtonStyle())
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func tilesRow(_ tiles: [HomeTile], taxonomy: String?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(tiles) { tile in
                    Button {
                        path.append(tileLink(tile, taxonomy: taxonomy))
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: tileIcon(tile.slug, taxonomy: taxonomy))
                                .font(.title2)
                                .foregroundColor(.accent180)
                                .frame(width: 56, height: 56)
                                .background(Color.accent180.opacity(0.12))
                                .clipShape(Circle())
                            Text(tile.name)
                                .font(AppFont.oswald(12, weight: .medium))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                        }
                        .frame(width: 90)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }


    // MARK: - Navigation des tuiles

    private func tileLink(_ tile: HomeTile, taxonomy: String?) -> HomeLink {
        switch taxonomy {
        case RecipeTaxonomy.category:
            return .list(title: tile.name, categorySlug: tile.slug, seasonSlug: nil, publicationSlug: nil)
        case RecipeTaxonomy.season:
            return .list(title: tile.name, categorySlug: nil, seasonSlug: tile.slug, publicationSlug: nil)
        case RecipeTaxonomy.publication:
            return .list(title: tile.name, categorySlug: nil, seasonSlug: nil, publicationSlug: tile.slug)
        default:
            return .list(title: tile.name, categorySlug: nil, seasonSlug: nil, publicationSlug: nil)
        }
    }

    private func tileIcon(_ slug: String, taxonomy: String?) -> String {
        switch taxonomy {
        case RecipeTaxonomy.season: return TaxonomyIcon.season(slug)
        case RecipeTaxonomy.category: return TaxonomyIcon.dish(slug)
        default: return "square.grid.2x2"
        }
    }

    // MARK: - Chargement

    private func loadData() async {
        // 1. Stale-while-revalidate : rendu immédiat depuis le dernier instantané
        //    disque — l'accueil s'affiche sans attendre le réseau. En ligne il
        //    doit avoir moins de 15 min ; hors ligne son âge est ignoré, faute
        //    de pouvoir aller chercher mieux.
        applyCachedSnapshotIfAny()

        // 2. Revalidation réseau (réécrit le cache disque).
        let fresh = await HomeService.shared.loadAndCache()

        await MainActor.run {
            if let fresh {
                applySnapshot(fresh)
            } else if !hasLoadedComposition {
                // Aucune composition n'a jamais pu être décodée, ni depuis le
                // cache ni depuis le réseau → état d'erreur typé. (Un accueil
                // volontairement vide, lui, a bien décodé sa composition et ne
                // passe pas par ici.)
                loadError = true
                loadErrorKind = NetworkMonitor.shared.isConnected ? .serverError : .offline
                isLoading = false
            } else {
                // On garde le contenu (stale) affiché : pas de mur d'erreur.
                isLoading = false
            }
        }

        await loadCarnet()
    }

    /// Affiche le dernier instantané en cache s'il existe ; sinon prépare l'état
    /// de chargement (skeleton) pour la revalidation qui suit.
    ///
    /// Hors connexion, le TTL est ignoré : un instantané vieux d'une heure vaut
    /// mieux qu'un mur d'erreur, puisqu'aucune revalidation n'est possible. Le
    /// bandeau hors ligne, affiché au-dessus, dit déjà que le contenu peut dater.
    @MainActor
    private func applyCachedSnapshotIfAny() {
        let snapshot = HomeService.shared.cachedSnapshot(
            ignoringTTL: !NetworkMonitor.shared.isConnected
        )
        if let snapshot {
            applySnapshot(snapshot)
        } else if blocks.isEmpty {
            isLoading = true
            loadError = false
        }
    }

    /// Applique un instantané (cache ou frais) à l'état de la vue : redécode les
    /// blocs depuis le JSON brut et reconstruit la table d'hydratation par bloc.
    @MainActor
    private func applySnapshot(_ snapshot: HomeCacheSnapshot) {
        // Le décodage fait foi : un payload valide **sans bloc** est une
        // composition vide assumée par la rédaction (écran vide), alors qu'un
        // payload absent ou illisible signe un échec — c'est ce que produit le
        // repli « recettes récentes » de `loadAndCache`, qui n'embarque aucune
        // composition.
        guard let payload = try? JSONDecoder().decode(HomePayload.self, from: snapshot.payload) else {
            // Ne jamais remplacer par un mur d'erreur une composition déjà à
            // l'écran : même datée, elle vaut mieux. L'erreur n'est montrée que
            // si l'on n'a jamais rien réussi à afficher.
            isLoading = false
            loadError = !hasLoadedComposition
            if loadError {
                loadErrorKind = NetworkMonitor.shared.isConnected ? .serverError : .offline
            }
            return
        }

        let decodedBlocks = payload.blocks

        var newHydrated: [Int: [Recipe]] = [:]
        for (index, block) in decodedBlocks.enumerated()
        where block.type == "rail" || block.type == "featured" {
            if let ids = block.recipeIds, !ids.isEmpty {
                // Un ID absent (404 / dépublié) est ignoré et ne casse pas le rail.
                newHydrated[index] = Self.ordered(snapshot.hydrated, by: ids)
            }
        }

        self.blocks = decodedBlocks
        self.hydrated = newHydrated
        self.allRecipes = snapshot.recent
        self.hasLoadedComposition = true
        self.loadError = false
        self.isLoading = false
    }

    /// Hydrate le rail carnet (favoris) si l'utilisateur est abonné.
    private func loadCarnet() async {
        guard auth.isSubscriber else {
            await MainActor.run { self.carnetRecipes = [] }
            return
        }
        let ids = (try? await APIService.shared.fetchFavoriteIDs())
            ?? Array(FavoritesManager.shared.favoriteIDs)
        guard !ids.isEmpty else {
            await MainActor.run { self.carnetRecipes = [] }
            return
        }
        let recipes = (try? await APIService.shared.fetchRecipesByIDs(ids)) ?? []
        await MainActor.run { self.carnetRecipes = Self.ordered(recipes, by: ids) }
    }

    /// Réordonne les recettes selon l'ordre des IDs (l'API `include` ne le garantit pas).
    private static func ordered(_ recipes: [Recipe], by ids: [Int]) -> [Recipe] {
        let byID = Dictionary(recipes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }
}

// MARK: - Destinations de navigation de l'accueil (par valeur)

/// Cibles de navigation **hors recette** de l'accueil, résolues par
/// `navigationDestination(for: HomeLink.self)`. Les recettes utilisent
/// directement `Recipe` comme valeur de navigation.
enum HomeLink: Hashable {
    case notifications
    case allRecipes
    case list(title: String, categorySlug: String?, seasonSlug: String?, publicationSlug: String?)
}

// MARK: - En-tête de section (réutilisé par SearchView)

struct SectionHeader: View {
    let title: String
    var destination: AnyView? = nil

    var body: some View {
        if let destination = destination {
            NavigationLink(destination: destination) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(AppFont.oswald(20, weight: .semibold))
                        .foregroundColor(.primary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
            }
        } else {
            Text(title)
                .font(AppFont.oswald(20, weight: .semibold))
                .padding(.horizontal)
        }
    }
}

// MARK: - Instrumentation hit-testing (DEBUG uniquement, désactivée par défaut)

#if DEBUG
/// Interrupteur de diagnostic du hit-testing de l'accueil. **N'existe qu'en build
/// DEBUG.** Passer `enabled = true` (breakpoint / lldb `expr HomeHitTestDebug.enabled = true`)
/// pour visualiser les zones tactiles (bordures colorées) et logger les
/// coordonnées des taps. Aucun effet, aucun code actif, en Release.
enum HomeHitTestDebug {
    static var enabled = false
}
#endif

extension View {
    /// Décoration de diagnostic : bordure + fond optionnels et log de la position
    /// du tap. Active **uniquement** en build DEBUG quand `HomeHitTestDebug.enabled`
    /// vaut `true`. En Release — ou en Debug avec le flag à `false` — renvoie la
    /// vue **inchangée** (comportement strictement identique à la prod).
    @ViewBuilder
    func homeHitDebug(_ zone: String, border: Color? = nil, fill: Color? = nil) -> some View {
        #if DEBUG
        if HomeHitTestDebug.enabled {
            self
                .background(fill ?? .clear)
                .border(border ?? .clear, width: border == nil ? 0 : 2)
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { value in
                        print("[HIT] \(zone) @ \(value.location)")
                    }
                )
        } else {
            self
        }
        #else
        self
        #endif
    }
}
