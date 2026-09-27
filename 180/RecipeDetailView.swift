import SwiftUI
import os

/// Écran de détail d'une recette.
///
/// Le contenu est lu directement depuis les champs ACF structurés du CPT
/// `recipe` (intro, portions, groupes d'ingrédients, étapes) — plus aucun
/// parsing HTML.
struct RecipeDetailView: View {
    /// Recette telle que fournie par l'écran appelant (déjà décodée, donc avec
    /// le `recipe_locked` de la session en cours au moment de ce fetch).
    private let initialRecipe: Recipe

    /// Version refetchée après un changement de session (cf. `contentGeneration`).
    @State private var refreshed: Recipe?

    /// Copie téléchargée pour la consultation hors ligne, si elle existe.
    @State private var offlineRecipe: Recipe?

    /// Recette affichée. Le **réseau reste prioritaire** : la copie locale ne
    /// prend la main que si la version reçue de l'écran appelant n'a rien à
    /// rendre (liste servie depuis un cache antérieur au téléchargement, fiche
    /// décodée pendant une session non abonnée…).
    private var recipe: Recipe {
        if let refreshed { return refreshed }
        if let offlineRecipe, !Self.hasRenderableContent(initialRecipe) { return offlineRecipe }
        return initialRecipe
    }

    /// Une fiche « rendable » porte au moins des ingrédients ou des étapes. Une
    /// fiche verrouillée n'en a aucun (gating serveur) — c'est le paywall qui la
    /// prend en charge, pas l'état hors ligne.
    private static func hasRenderableContent(_ recipe: Recipe) -> Bool {
        !recipe.ingredientGroups.isEmpty || !recipe.preparationSteps.isEmpty
    }

    /// Hors ligne, sans copie locale et sans contenu en mémoire : il n'y a
    /// strictement rien à afficher. On le dit, plutôt que de rendre une fiche
    /// vide qui passerait pour une recette sans ingrédients.
    private var isUnavailableOffline: Bool {
        !monitor.isConnected && !recipe.isLocked && !Self.hasRenderableContent(recipe)
    }

    init(recipe: Recipe) {
        self.initialRecipe = recipe
    }

    @ObservedObject var favorites = FavoritesManager.shared
    @StateObject private var auth = AuthService.shared
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    /// Optionnel : une fiche présentée en sheet hors hiérarchie injectée retombe
    /// sur le singleton plutôt que de faire crasher l'écran.
    @Environment(NetworkMonitor.self) private var injectedMonitor: NetworkMonitor?
    @State private var showLogin = false
    @State private var recommendations: [Recipe] = []

    private var monitor: NetworkMonitor { injectedMonitor ?? .shared }

    var body: some View {
        Group {
            if isUnavailableOffline {
                TypedErrorView(error: .offline) {
                    await reloadRecipe()
                }
            } else if horizontalSizeClass == .regular {
                iPadLayout
            } else {
                iPhoneLayout
            }
        }
        .task {
            AnalyticsService.viewRecipe(id: recipe.id, title: recipe.cleanTitle, isPremium: recipe.isPremium)
            if recipe.isLocked {
                AnalyticsService.paywallView(id: recipe.id, title: recipe.cleanTitle)
            }
            await loadOfflineCopy()
            await loadRecommendations()
        }
        // Changement de session (login / logout) : la recette en mémoire porte
        // encore l'ancien `recipe_locked`. On la refetche avec le nouveau jeton
        // pour que le paywall se réévalue **sans redémarrage de l'app**.
        // `contentGeneration == 0` = premier affichage, déjà couvert par le fetch
        // d'origine → pas d'appel réseau superflu.
        .task(id: auth.contentGeneration) {
            guard auth.contentGeneration > 0 else { return }
            await reloadRecipe()
        }
        .sheet(isPresented: $showLogin) {
            LoginView()
        }
        // Url calquée sur le site (`/recette/{slug}`) ; repli sur l'id quand le
        // slug manque (fiche relue d'un cache antérieur à son décodage).
        .onAppear {
            UmamiTracker.shared.trackScreen(
                path: "/recette/\(recipe.slug ?? String(recipe.id))",
                title: recipe.cleanTitle
            )
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                ShareLink(
                    item: URL(string: APIConfig.shared.webLink("/?p=\(recipe.id)")) ?? URL(string: APIConfig.shared.webLink("/"))!
                ) {
                    Image(systemName: "square.and.arrow.up")
                }
                // `ShareLink` n'expose aucun rappel de fin : l'event est émis à
                // l'OUVERTURE de la feuille de partage, et `channel` vaut donc
                // `share_sheet` (iOS ne dit pas quelle destination a été
                // choisie). Cf. compte-rendu, point d'incertitude.
                .simultaneousGesture(TapGesture().onEnded {
                    UmamiTracker.shared.trackEvent(name: "recipe_share", data: ["channel": "share_sheet"])
                })
            }
        }
    }

    // MARK: - iPhone : layout existant (scroll vertical)

    private var iPhoneLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                imagePanel
                contentPanel
                    .padding(20)
                recommendationsSection
            }
        }
    }

    // MARK: - iPad : layout deux colonnes

    private var iPadLayout: some View {
        HStack(alignment: .top, spacing: 0) {
            // Colonne gauche : image fixe
            imagePanel
                .frame(width: 400)
                .clipped()

            // Colonne droite : contenu scrollable
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    contentPanel
                        .padding(28)
                    recommendationsSection
                }
            }
        }
        .ignoresSafeArea(edges: .top)
    }

    /// Favori **du point de vue de l'affichage** : hors session un résidu local
    /// ne doit pas afficher un cœur plein et rouge sur un bouton par ailleurs
    /// désactivé. Cf. `FavoriteGate` (RecipeCards.swift).
    private var showsAsFavorite: Bool {
        auth.isLoggedIn && favorites.isFavorite(recipe.id)
    }

    // MARK: - Panneau image (partagé iPhone / iPad)

    private var imagePanel: some View {
        ZStack(alignment: .bottomTrailing) {
            CachedAsyncImage(
                url: recipe.imageURL.flatMap({ URL(string: $0) }),
                maxRenderWidth: horizontalSizeClass == .regular ? 800 : 450  // hero détail
            )
                .frame(maxWidth: .infinity)
                .frame(minHeight: horizontalSizeClass == .regular ? 500 : 300,
                       maxHeight: horizontalSizeClass == .regular ? .infinity : 300)
                .clipped()
                .accessibilityHidden(true)

            // Bouton favori
            Button {
                favorites.toggle(recipe.id, title: recipe.cleanTitle, slug: recipe.slug)
            } label: {
                Image(systemName: showsAsFavorite ? "heart.fill" : "heart")
                    .font(.title2)
                    .foregroundColor(showsAsFavorite ? .red : .white)
                    .padding(12)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .accessibilityLabel(showsAsFavorite ? "Retirer des favoris" : "Ajouter aux favoris")
            .modifier(FavoriteGate(isLoggedIn: auth.isLoggedIn))
            .padding(16)
        }
    }

    // MARK: - Panneau contenu (partagé iPhone / iPad)

    @ViewBuilder
    private var contentPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Titre
            Text(recipe.cleanTitle)
                .font(AppFont.playfair(28, weight: .bold))

            Divider()

            // Contenu — source de vérité = recipe_locked (gating serveur).
            if recipe.isLocked {
                paywall
            } else {
                fullContent
            }
        }
    }

    // MARK: Contenu complet (abonné)

    @ViewBuilder
    private var fullContent: some View {
        // Introduction
        if !recipe.introText.isEmpty {
            Text(recipe.introText)
                .font(AppFont.playfair(17))
                .bold()
                .lineSpacing(4)
                .padding(.bottom, 8)

            Divider()
        }

        // Nombre de portions
        if let servingsText = recipe.servingsText {
            HStack {
                Image(systemName: "person.2")
                    .foregroundColor(.accent180)
                Text(servingsText)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .padding(.vertical, 8)
        }

        // Ingrédients
        if !recipe.ingredientGroups.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ingrédients")
                    .font(.title3)
                    .fontWeight(.bold)

                ForEach(recipe.ingredientGroups) { group in
                    if !group.groupLabel.isEmpty {
                        Text(group.groupLabel)
                            .font(AppFont.playfair(16, weight: .bold))
                            .padding(.top, 4)
                    }

                    ForEach(Array(group.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(Color.accent180)
                                .frame(width: 6, height: 6)
                                .padding(.top, 6)
                            Text(line)
                                .font(AppFont.playfair(16))
                        }
                    }
                }
            }
            .padding(.vertical, 8)

            Divider()
        }

        // Étapes
        if !recipe.preparationSteps.isEmpty {
            VStack(alignment: .leading, spacing: 20) {
                Text("Préparation")
                    .font(.title3)
                    .fontWeight(.bold)

                ForEach(Array(recipe.preparationSteps.enumerated()), id: \.offset) { index, step in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.accent180)
                                .clipShape(Circle())

                            if !step.cleanTitle.isEmpty {
                                Text(step.cleanTitle)
                                    .font(AppFont.playfair(17, weight: .bold))
                            }
                        }

                        if !step.cleanContent.isEmpty {
                            Text(step.cleanContent)
                                .font(AppFont.playfair(16))
                                .lineSpacing(4)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: Paywall (non abonné)

    // MARK: Paywall (non abonné) — recentré sur le LOGIN
    //
    // Conformité App Store 3.1.1 : aucun bouton/lien d'achat web, aucune URL
    // tappable, aucun prix. Le paywall propose la connexion (contenu réservé aux
    // abonnés) et se contente d'une allusion douce, NON cliquable, à l'existence
    // d'un abonnement sur le site.
    @ViewBuilder
    private var paywall: some View {
        // Aperçu éditorial (intro / extrait) — pas un CTA.
        Text(recipe.introText.isEmpty ? recipe.cleanExcerpt : recipe.introText)
            .font(.body)
            .lineSpacing(6)

        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.title)
                .foregroundColor(.accent180)

            Text("Contenu réservé aux abonnés")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("Connectez-vous pour accéder à cette recette en intégralité.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // CTA principal : le flux de connexion existant.
            if !auth.isLoggedIn {
                Button {
                    showLogin = true
                } label: {
                    Text("Se connecter")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accent180)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
            }

            // Ligne secondaire discrète, NON cliquable (Text(verbatim:) → aucun
            // rendu markdown/lien, « 180c.fr » reste du texte inerte). Wording
            // produit exact, aucun prix, aucune URL tappable.
            Text(verbatim: "L'abonnement est disponible sur notre site 180c.fr.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }

    // MARK: - Section recommandations

    @ViewBuilder
    private var recommendationsSection: some View {
        if !recommendations.isEmpty {
            Divider()
                .padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 12) {
                Text("Vous aimerez aussi")
                    .font(.title3)
                    .fontWeight(.bold)
                    .padding(.horizontal, 20)

                ScrollView(.horizontal, showsIndicators: false) {
                    // Ancrage `.top` : cf. `HomeView.recipeRail`, les cartes ont
                    // des hauteurs libres (labels conditionnels, titre sur une ou
                    // deux lignes) et un alignement centré désaligne leurs bords
                    // supérieurs.
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(recommendations) { rec in
                            NavigationLink(destination: RecipeDetailView(recipe: rec)) {
                                RecipeCard(recipe: rec)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 20)
        }
    }

    // MARK: - Rechargement après changement de session

    /// Refetche la recette courante avec le jeton actuel. En cas d'échec on
    /// conserve la version affichée (jamais d'écran vide).
    private func reloadRecipe() async {
        guard let updated = try? await APIService.shared.fetchRecipesByIDs([initialRecipe.id]).first else {
            return
        }
        await MainActor.run { refreshed = updated }
    }

    // MARK: - Copie hors ligne

    /// Charge la fiche téléchargée si elle existe. Toujours tentée, y compris en
    /// ligne : elle ne sert de source que si la version en mémoire n'a rien à
    /// rendre, mais l'avoir sous la main évite un écran vide si le réseau tombe
    /// pendant la consultation.
    private func loadOfflineCopy() async {
        guard OfflineStore.shared.has(initialRecipe.id) else { return }
        let local = await OfflineStore.shared.load(initialRecipe.id)
        await MainActor.run { offlineRecipe = local }
    }

    // MARK: - Chargement recommandations

    private func loadRecommendations() async {
        // Hors ligne, les recommandations ne sont pas téléchargées : inutile de
        // consommer trois requêtes vouées à expirer.
        guard monitor.isConnected else { return }
        do {
            var recommended: [Recipe] = []

            // Même catégorie culinaire en priorité.
            if let firstCategory = recipe.recipeCategory?.first {
                let catRecipes = try await APIService.shared.fetchRecipes(
                    taxonomy: RecipeTaxonomy.category, termID: firstCategory, perPage: 6
                )
                recommended.append(contentsOf: catRecipes)
            }

            // Complète par la même saison si besoin.
            if recommended.count < 5, let firstSeason = recipe.recipeSeason?.first {
                let seasonRecipes = try await APIService.shared.fetchRecipes(
                    taxonomy: RecipeTaxonomy.season, termID: firstSeason, perPage: 6
                )
                recommended.append(contentsOf: seasonRecipes)
            }

            var seen = Set<Int>([recipe.id])
            recommended = recommended.filter { r in
                guard !seen.contains(r.id) else { return false }
                seen.insert(r.id)
                return true
            }

            await MainActor.run {
                self.recommendations = Array(recommended.prefix(6))
            }
        } catch {
            AppLogger.api.error("Erreur recommandations: \(error)")
        }
    }
}
