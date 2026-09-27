import SwiftUI
import os

/// Cible présentée en sheet suite à un tap de notification.
enum DeepLinkPresentation: Identifiable {
    case recipe(Recipe)
    case web(URL)
    /// Page produit en webview **authentifiée** : `autologin` amorce la session,
    /// `fallback` est la page publique chargée si l'amorçage échoue.
    case productWeb(autologin: URL, fallback: URL)
    case center

    var id: String {
        switch self {
        case .recipe(let recipe):        return "recipe-\(recipe.id)"
        case .web(let url):              return "web-\(url.absoluteString)"
        case .productWeb(_, let fb):     return "product-\(fb.absoluteString)"
        case .center:                    return "center"
        }
    }
}

struct ContentView: View {

    @StateObject private var router = TabRouter.shared
    @StateObject private var softAsk = PushSoftAskPresenter.shared
    @StateObject private var notifRouter = NotificationRouter.shared
    @State private var deepLink: DeepLinkPresentation?
    @AppStorage("appearanceMode") private var appearanceMode: Int = 0
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(NetworkMonitor.self) private var injectedMonitor: NetworkMonitor?
    @ObservedObject private var shakeDetector = ShakeDetectorService.shared

    private var monitor: NetworkMonitor { injectedMonitor ?? .shared }
    @State private var randomRecipe: Recipe? = nil
    @State private var isLoadingRandom = false

    // Binding Int? pour List(selection:) sur iPad
    private var sidebarSelection: Binding<Int?> {
        Binding(get: { router.selected }, set: { router.selected = $0 ?? 0 })
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                iPadLayout
            } else {
                iPhoneLayout
            }
        }
        .tint(.accent180)
        .preferredColorScheme(appearanceMode == 0 ? nil : (appearanceMode == 1 ? .light : .dark))
        .withToast()
        .task {
            await AuthService.shared.refreshTokenIfNeeded()
            await FavoritesManager.shared.refreshFromServer()
            await refreshSubscriptionAndReconcile()
            ShakeDetectorService.shared.start()
            // Point d'entrée 2 du soft ask : comptage de lancement.
            softAsk.registerLaunchAndMaybePrompt()
            // Cold start : appliquer une destination de notification déjà en attente.
            if let dest = notifRouter.pendingDestination { handleNotification(dest) }
        }
        .onChange(of: notifRouter.pendingDestination) { _, dest in
            if let dest { handleNotification(dest) }
        }
        // Retour du réseau : on revérifie le statut d'abonnement (seul moment
        // légitime pour retirer l'accès hors ligne) et on rattrape les
        // téléchargements manqués pendant la coupure.
        .onChange(of: monitor.isConnected) { _, connected in
            guard connected else { return }
            Task { await refreshSubscriptionAndReconcile() }
        }
        .onAppear {
            setupAnalytics()
        }
        .onChange(of: shakeDetector.didShake) { _, didShake in
            guard didShake, !isLoadingRandom else { return }
            shakeDetector.reset()
            // Retour haptique léger déclenché à la détection du shake, avant même
            // le tirage réseau, pour confirmer le geste immédiatement.
            Haptics.light()
            Task { await fetchRandomRecipe() }
        }
        .sheet(item: $randomRecipe) { recipe in
            NavigationStack {
                RecipeDetailView(recipe: recipe)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Fermer") { randomRecipe = nil }
                        }
                    }
            }
        }
        .sheet(isPresented: $softAsk.isShown) {
            PushSoftAskSheet(
                onActivate: { softAsk.activate() },
                onDismiss: { softAsk.decline() }
            )
        }
        .sheet(item: $deepLink) { presentation in
            switch presentation {
            case .recipe(let recipe):
                NavigationStack {
                    RecipeDetailView(recipe: recipe)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("Fermer") { deepLink = nil }
                            }
                        }
                }
            case .web(let url):
                InAppBrowserView(url: url)
            case .productWeb(let autologin, let fallback):
                InAppBrowserView(authenticating: autologin, fallback: fallback)
            case .center:
                NavigationStack {
                    NotificationsView()
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("Fermer") { deepLink = nil }
                            }
                        }
                }
            }
        }
    }

    /// Applique une destination de notification. Une destination inconnue ou
    /// introuvable ouvre le centre de notifications (jamais de crash).
    private func handleNotification(_ destination: NotificationDestination) {
        switch destination {
        case .recipe(let id):
            Task {
                let recipe = try? await APIService.shared.fetchRecipesByIDs([id]).first
                await MainActor.run { deepLink = recipe.map { .recipe($0) } ?? .center }
            }
        case .article(let id):
            // Pas de vue article native : ouverture web via le permalien `?p=ID`.
            deepLink = URL(string: APIConfig.shared.webLink("/?p=\(id)")).map { .web($0) } ?? .center
        case .url(let url):
            deepLink = .web(url)
        case .product(_, let productURL):
            // `productURL` est déjà normalisée sur le domaine canonique par le
            // routeur.
            let token = AuthService.shared.getToken()
            if let token, !token.isEmpty {
                // Connecté : webview authentifiée. On amorce la session via
                // l'endpoint autologin (POST du JWT hors URL, cf. `WebSession` /
                // « Mon compte »), avec repli sur la page publique si l'amorçage
                // échoue.
                let link = APIConfig.shared.autoLoginLink(relativeTarget(of: productURL), token: token)
                let autologin = URL(string: link) ?? productURL
                deepLink = .productWeb(autologin: autologin, fallback: productURL)
            } else {
                // Non connecté : une page produit est publique. On l'ouvre
                // directement, sans amorçage ni blocage — une notification tapée
                // doit toujours ouvrir quelque chose ; l'utilisateur pourra se
                // connecter depuis le web pour acheter.
                deepLink = .web(productURL)
            }
        case .none:
            deepLink = .center
        }
        notifRouter.pendingDestination = nil
    }

    /// Chemin relatif (chemin + requête + fragment) d'une URL du site, tel
    /// qu'attendu par `APIConfig.autoLoginLink` (qui le place en `redirect=`).
    private func relativeTarget(of url: URL) -> String {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.path
        }
        var target = comps.path.isEmpty ? "/" : comps.path
        if let query = comps.query { target += "?\(query)" }
        if let fragment = comps.fragment { target += "#\(fragment)" }
        return target
    }

    // MARK: - iPhone : TabView existant

    private var iPhoneLayout: some View {
        TabView(selection: $router.selected) {
            HomeView()
                .tabItem { Label("Accueil", systemImage: "house") }
                .tag(0)
            SearchView()
                .tabItem { Label("Recherche", systemImage: "magnifyingglass") }
                .tag(1)
            FavoritesView()
                .tabItem { Label("Favoris", systemImage: "heart") }
                .tag(2)
            AccountView()
                .tabItem { Label("Compte", systemImage: "person") }
                .tag(3)
        }
    }

    // MARK: - iPad : NavigationSplitView

    private var iPadLayout: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                Label("Accueil", systemImage: "house").tag(0)
                Label("Recherche", systemImage: "magnifyingglass").tag(1)
                Label("Favoris", systemImage: "heart").tag(2)
                Label("Compte", systemImage: "person").tag(3)
            }
            .navigationTitle("180°C")
        } detail: {
            switch router.selected {
            case 1: SearchView()
            case 2: FavoritesView()
            case 3: AccountView()
            default: HomeView()
            }
        }
    }

    // MARK: - Abonnement & carnet hors ligne

    /// Rafraîchit le statut d'abonnement puis lance la réconciliation du carnet
    /// hors ligne. **En ligne uniquement.**
    ///
    /// Avant cette feature, `checkSubscriptionStatus()` n'était appelé qu'après
    /// un login : au lancement, `isSubscriber` venait du cache `UserDefaults` et
    /// une fin d'abonnement pouvait n'être jamais constatée. C'est ce
    /// rafraîchissement qui donne son déclencheur à la règle de vie du carnet
    /// hors ligne — et il ne coûte rien pour un visiteur (l'appel sort tout de
    /// suite en l'absence de jeton).
    private func refreshSubscriptionAndReconcile() async {
        guard monitor.isConnected else { return }
        await AuthService.shared.checkSubscriptionStatus()
        OfflineSyncService.shared.reconcileIfNeeded()
    }

    // MARK: - Shake to Random

    private func fetchRandomRecipe() async {
        isLoadingRandom = true
        do {
            if let recipe = try await APIService.shared.fetchRandomRecipe() {
                await MainActor.run { randomRecipe = recipe }
            }
        } catch {
            AppLogger.api.error("Erreur recette aléatoire: \(error)")
        }
        await MainActor.run { isLoadingRandom = false }
    }

    // MARK: - Analytics

    private func setupAnalytics() {
        let auth = AuthService.shared
        let notifManager = NotificationManager.shared
        let modeName = appearanceMode == 0 ? "auto" : appearanceMode == 1 ? "light" : "dark"
        let newsletterSubscribed = UserDefaults.standard.bool(forKey: "newsletter_cahiers")
        AnalyticsService.setUserProperties(
            isLoggedIn: auth.isLoggedIn,
            isSubscriber: auth.isSubscriber,
            newsletterSubscribed: newsletterSubscribed,
            darkMode: modeName,
            notificationsEnabled: notifManager.isAuthorized,
            favoritesCount: FavoritesManager.shared.favoriteIDs.count
        )
    }
}

#Preview {
    ContentView()
}
