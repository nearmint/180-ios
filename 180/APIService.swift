import Foundation

/// Service qui communique avec l'API REST de WordPress.
///
/// Les recettes sont servies par le CPT `recipe` (`wp/v2/recipe`) avec champs
/// ACF structurés et taxonomies `recipe_category` / `recipe_season` /
/// `recipe_publication`. Plus aucun appel `wp/v2/posts` ni ID de terme en dur.
class APIService {

    static let shared = APIService()

    private let baseURL = APIConfig.shared.wpV2

    /// Vide le cache d'images (bitmaps). À appeler au pull-to-refresh pour forcer
    /// le rechargement des visuels.
    func clearImageCaches() {
        ImageCacheManager.shared.clear()
    }

    private func authenticatedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let token = AuthService.shared.getToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // MARK: - Couche réseau (session bornée + retry léger sur GET)

    /// Backoff entre tentatives sur erreur transitoire : 1 s après la 1re, 3 s
    /// après la 2e (2 retries max = 3 tentatives au total).
    private static let retryBackoff: [UInt64] = [1_000_000_000, 3_000_000_000]

    /// GET via `AppHTTP.session` (timeouts bornés) avec **2 retries à backoff
    /// croissant** (1 s puis 3 s) sur erreur transitoire (timeout / hors-ligne /
    /// 5xx). Renvoie le corps d'une 2xx. Ce sont les GET idempotents : rejouer
    /// une requête de lecture est sûr, et absorbe les micro-coupures réseau
    /// avant d'exposer le message d'erreur à l'utilisateur.
    private func getData(_ url: URL, authenticated: Bool = false) async throws -> Data {
        let request = authenticated ? authenticatedRequest(url: url) : URLRequest(url: url)
        var lastError: APIError = .serverError
        for attempt in 0...Self.retryBackoff.count {
            do {
                return try await Self.send(request)
            } catch {
                let mapped = APIError.from(error)
                lastError = mapped
                if attempt < Self.retryBackoff.count && mapped.isTransient {
                    try? await Task.sleep(nanoseconds: Self.retryBackoff[attempt])
                    continue
                }
                throw mapped
            }
        }
        throw lastError
    }

    /// Exécute une requête et renvoie le corps d'une réponse 2xx, sinon `APIError`.
    /// Pas de retry ici : utilisé tel quel pour les écritures (POST/DELETE).
    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await AppHTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.serverError }
        guard (200...299).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
        return data
    }

    // MARK: - Récupérer les recettes (filtrables par taxonomie via slugs)

    /// Liste de recettes, filtrable par catégorie culinaire, saison et/ou
    /// publication. Les slugs sont résolus en IDs de termes au runtime ; un slug
    /// introuvable renvoie `[]` (le filtre ne peut matcher aucune recette).
    /// - Parameter showToastOnError: affiche un toast d'erreur en cas d'échec.
    ///   Mettre `false` pour les chargements **résilients** (accueil
    ///   stale-while-revalidate) qui gèrent l'échec par le cache et un état
    ///   d'erreur dédié — sinon un simple hoquet réseau lors d'un rafraîchissement
    ///   en arrière-plan afficherait le toast « Impossible de charger… » alors
    ///   que l'écran a déjà du contenu.
    func fetchRecipes(
        categorySlug: String? = nil,
        seasonSlug: String? = nil,
        publicationSlug: String? = nil,
        page: Int = 1,
        perPage: Int = 20,
        orderby: String = "date",
        order: String = "desc",
        showToastOnError: Bool = true
    ) async throws -> [Recipe] {
        var query = "_embed&per_page=\(perPage)&page=\(page)&orderby=\(orderby)&order=\(order)"

        let filters: [(taxonomy: String, slug: String)] = [
            categorySlug.map { (RecipeTaxonomy.category, $0) },
            seasonSlug.map { (RecipeTaxonomy.season, $0) },
            publicationSlug.map { (RecipeTaxonomy.publication, $0) },
        ].compactMap { $0 }

        for filter in filters {
            guard let termID = await RecipeTaxonomyResolver.shared.termID(
                taxonomy: filter.taxonomy, slug: filter.slug
            ) else {
                return []
            }
            query += "&\(filter.taxonomy)=\(termID)"
        }

        return try await fetchRecipeList(query: query, showToastOnError: showToastOnError)
    }

    /// Liste de recettes filtrée par ID de terme déjà connu (recommandations).
    func fetchRecipes(taxonomy: String, termID: Int, page: Int = 1, perPage: Int = 20) async throws -> [Recipe] {
        let query = "_embed&per_page=\(perPage)&page=\(page)&\(taxonomy)=\(termID)"
        return try await fetchRecipeList(query: query)
    }

    /// Exécute une requête `wp/v2/recipe` et décode le tableau de recettes.
    private func fetchRecipeList(query: String, showToastOnError: Bool = false) async throws -> [Recipe] {
        let urlString = "\(baseURL)/recipe?\(query)"

        guard let url = URL(string: urlString) else {
            throw APIError.invalidURL
        }

        do {
            let data = try await getData(url, authenticated: true)
            return try JSONDecoder().decode([Recipe].self, from: data)
        } catch {
            let apiError = APIError.from(error)
            if showToastOnError {
                ToastManager.shared.show(apiError.userMessage)
            }
            throw apiError
        }
    }

    // MARK: - Termes de taxonomie (résolution slug -> ID, filtres)

    /// Récupère les termes d'une taxonomie `recipe_*`.
    /// `_fields` (incompatible avec `_embed`) limite la charge utile.
    func fetchTerms(taxonomy: String, perPage: Int = 100) async throws -> [Term] {
        let urlString = "\(baseURL)/\(taxonomy)?per_page=\(perPage)&_fields=id,name,slug,count,parent"

        guard let url = URL(string: urlString) else {
            throw APIError.invalidURL
        }

        let data = try await getData(url)
        return try JSONDecoder().decode([Term].self, from: data)
    }

    /// Catégories culinaires de recettes (`recipe_category`), triées par usage.
    func fetchRecipeCategories() async throws -> [Term] {
        let terms = try await fetchTerms(taxonomy: RecipeTaxonomy.category)
        return terms.sorted { $0.count > $1.count }
    }

    // MARK: - Récupérer des recettes par IDs (pour les favoris)

    /// Recettes correspondant aux IDs demandés, **paginées par 100**.
    ///
    /// `per_page` était auparavant calé sur `ids.count` : au-delà de 100,
    /// `wp/v2` répondait 400 et le carnet entier restait vide. Un utilisateur
    /// n'a pas à voir sa collection cesser de se charger parce qu'elle a
    /// franchi un seuil qu'aucun écran ne mentionne.
    ///
    /// L'ordre de retour n'est pas garanti par l'API (`include` ne trie pas) :
    /// les appelants qui en dépendent re-mappent déjà par ID
    /// (`FavoritesView.swift:247-249`, `HomeView.ordered(_:by:)`). Concaténer
    /// les pages ne change donc rien pour eux.
    ///
    /// Une page en échec propage son erreur et abandonne le lot — même
    /// sémantique « tout ou rien » qu'avant la pagination.
    func fetchRecipesByIDs(_ ids: [Int]) async throws -> [Recipe] {
        guard !ids.isEmpty else { return [] }

        var out: [Recipe] = []
        out.reserveCapacity(ids.count)
        for page in RecipePaging.chunk(ids) {
            let idsString = page.map { String($0) }.joined(separator: ",")
            let query = "_embed&include=\(idsString)&per_page=\(page.count)"
            out += try await fetchRecipeList(query: query)
        }
        return out
    }

    // MARK: - Sonde de fraîcheur (réconciliation hors ligne)

    /// Dates de dernière modification des recettes demandées, sans leur contenu.
    ///
    /// `_fields=id,modified` réduit la réponse à quelques dizaines d'octets par
    /// recette (contre ~10 Ko avec `_embed`) : la réconciliation du carnet hors
    /// ligne peut ainsi décider **quoi** re-télécharger sans rapatrier ce qu'elle
    /// possède déjà. Les IDs sont découpés en pages de 100 (limite `wp/v2`).
    ///
    /// - Returns: `[id: modified]`. Un ID absent du résultat est une recette que
    ///   le serveur ne sert plus (dépubliée) ou dont la date est indisponible.
    func fetchRecipeModifiedDates(ids: [Int]) async throws -> [Int: String] {
        guard !ids.isEmpty else { return [:] }

        var out: [Int: String] = [:]
        for chunk in RecipePaging.chunk(ids) {
            let idsString = chunk.map(String.init).joined(separator: ",")
            let urlString = "\(baseURL)/recipe?include=\(idsString)&per_page=\(chunk.count)&_fields=id,modified"
            guard let url = URL(string: urlString) else { throw APIError.invalidURL }

            let data = try await getData(url, authenticated: true)
            let entries = try JSONDecoder().decode([RecipeFreshness].self, from: data)
            for entry in entries {
                if let modified = entry.modified { out[entry.id] = modified }
            }
        }
        return out
    }

    // MARK: - Recette aléatoire (Shake to Random)

    /// Tire une recette au hasard **côté app**.
    ///
    /// `orderby=rand` n'appartient pas à l'énum `orderby` autorisée par
    /// `wp/v2/recipe` (WordPress rejette la requête en 400) : le shake échouait
    /// donc silencieusement. On récupère un lot de recettes récentes et on en
    /// choisit une localement — aucune dépendance à un tri serveur non standard.
    func fetchRandomRecipe() async throws -> Recipe? {
        let pool = try await fetchRecipeList(query: "_embed&per_page=100&orderby=date&order=desc")
        return pool.randomElement()
    }

    // MARK: - Recherche

    func searchRecipes(query: String, page: Int = 1) async throws -> [Recipe] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return try await fetchRecipeList(query: "_embed&search=\(encoded)&per_page=20&page=\(page)")
    }

    // MARK: - Carnet (favoris serveur, namespace 180c/v1)

    /// `GET /180c/v1/favorites` — IDs des favoris du user authentifié.
    func fetchFavoriteIDs() async throws -> [Int] {
        guard let url = URL(string: "\(APIConfig.shared.restV1)/favorites") else {
            throw APIError.invalidURL
        }
        let data = try await getData(url, authenticated: true)
        return try JSONDecoder().decode(FavoritesListResponse.self, from: data).ids
    }

    /// `POST /180c/v1/favorites` — ajoute une recette aux favoris.
    func addFavorite(_ recipeID: Int) async throws {
        guard let url = URL(string: "\(APIConfig.shared.restV1)/favorites") else {
            throw APIError.invalidURL
        }
        var request = authenticatedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["recipe_id": recipeID])
        _ = try await Self.send(request)
    }

    /// `DELETE /180c/v1/favorites/{recipe_id}` — retire une recette des favoris.
    func deleteFavorite(_ recipeID: Int) async throws {
        guard let url = URL(string: "\(APIConfig.shared.restV1)/favorites/\(recipeID)") else {
            throw APIError.invalidURL
        }
        var request = authenticatedRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try await Self.send(request)
    }

    /// `POST /180c/v1/favorites/sync` — réconciliation last-write-wins.
    /// - Parameter items: `[{ recipe_id, favorited, updated_at }]`.
    /// - Returns: IDs de l'état serveur réconcilié.
    func syncFavorites(_ items: [[String: Any]]) async throws -> [Int] {
        guard let url = URL(string: "\(APIConfig.shared.restV1)/favorites/sync") else {
            throw APIError.invalidURL
        }
        var request = authenticatedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["favorites": items])

        let data = try await Self.send(request)
        return try JSONDecoder().decode(FavoritesSyncResponse.self, from: data).favorites.map { $0.id }
    }
}

/// Réponse allégée de la sonde de fraîcheur (`_fields=id,modified`).
private struct RecipeFreshness: Decodable {
    let id: Int
    let modified: String?
}
