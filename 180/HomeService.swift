import Foundation
import os

// MARK: - Contrat 180c/v1/home-recettes

/// Portée d'affichage d'un module de la home, décidée dans le Home Builder et
/// exposée par le champ `visibility` du contrat `180c/v1/home-recettes`.
///
/// La **source de vérité reste le serveur** : le payload par défaut de
/// `/home-recettes` exclut déjà les modules `web_only` (le paramètre `?all=1`,
/// qui les réintègre, n'est pas utilisé par l'app). Le filtre client posé au
/// décodage n'est qu'une sécurité de robustesse, utile pour deux cas réels :
/// un instantané disque écrit avant l'arrivée du filtre serveur, et une
/// régression côté web qui laisserait passer un module `web_only`.
enum ModuleVisibility: String, Decodable {
    case webOnly = "web_only"
    case appOnly = "app_only"
    case webAndApp = "web_app"

    /// Valeur retenue quand `visibility` est absent, d'un autre type, ou porte
    /// une valeur inconnue (`web_only_v2`…) : on **n'exclut rien**. Un champ
    /// qu'on ne sait pas lire ne doit jamais faire disparaître un module.
    static let fallback: ModuleVisibility = .webAndApp

    /// Le module doit-il être rendu par l'app ? Seul `web_only` est exclu — la
    /// règle est identique côté Android (parité stricte).
    var isVisibleInApp: Bool { self != .webOnly }
}

/// Payload de la home Recettes (composition du Home Builder de `/recettes/`).
///
/// Décodage **tolérant** : `page_id` peut manquer, et un bloc malformé est
/// **ignoré** (via `FailableDecodable`) plutôt que de faire échouer toute la
/// home — un seul bloc cassé ne doit pas vider l'accueil.
///
/// Les modules `web_only` sont retirés **ici**, au décodage, et non au rendu :
/// c'est le seul point traversé par les trois chemins (réponse réseau,
/// instantané disque relu par `HomeView.applySnapshot`, hydratation des
/// `recipe_ids` dans `loadAndCache`). Les vues n'ont donc rien à savoir de
/// `visibility`.
struct HomePayload: Decodable {
    let pageId: Int?
    let blocks: [HomeBlock]

    enum CodingKeys: String, CodingKey {
        case pageId = "page_id"
        case blocks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageId = try container.decodeIfPresent(Int.self, forKey: .pageId)
        let raw = try container.decodeIfPresent([FailableDecodable<HomeBlock>].self, forKey: .blocks) ?? []
        blocks = raw.compactMap { $0.value }.filter { $0.visibility.isVisibleInApp }
    }
}

/// Enveloppe de décodage qui n'échoue jamais : un élément invalide devient `nil`
/// (et le curseur du conteneur avance quand même). Permet un tableau « lossy ».
struct FailableDecodable<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(Wrapped.self)
    }
}

/// Descripteur d'un bloc de la home (ordonné). Les champs présents dépendent du
/// `type` ; l'app rend ce qu'elle gère et ignore le reste (passthrough).
struct HomeBlock: Decodable {
    let type: String
    let anchor: String?
    let title: String

    /// Portée d'affichage du module (`web_only` / `app_only` / `web_app`).
    /// Toujours renseignée après décodage : `ModuleVisibility.fallback` couvre
    /// l'absence du champ et les valeurs inconnues. Le filtrage est fait par
    /// `HomePayload.init` ; ici la valeur est aussi exploitable pour du debug.
    let visibility: ModuleVisibility

    // rail
    /// Présentation demandée par le serveur pour un `rail`. `"slider"` (module
    /// `recipes_slider`) ⇒ carrousel plein format ; absent ⇒ rail dense. Champ
    /// **additif** : un `variant` inconnu retombe sur le rendu par défaut.
    let variant: String?
    let source: String?
    let taxonomy: String?
    let termSlug: String?
    let count: Int?
    let viewAllUrl: String?
    let recipeIds: [Int]?

    // category_tiles
    let terms: [HomeTile]?

    // cta_subscribe
    let body: String?
    let ctaText: String?
    let ctaUrl: String?
    let loginUrl: String?

    // search
    let placeholder: String?

    enum CodingKeys: String, CodingKey {
        case type, anchor, title, visibility, variant, source, taxonomy, count, terms, body, placeholder
        case termSlug = "term_slug"
        case viewAllUrl = "view_all_url"
        case recipeIds = "recipe_ids"
        case ctaText = "cta_text"
        case ctaUrl = "cta_url"
        case loginUrl = "login_url"
    }

    /// Décodage tolérant : seul `type` est requis (un bloc sans type est rejeté
    /// par `FailableDecodable`). `title` absent ⇒ "" ; tout le reste est optionnel
    /// pour rester forward-compatible avec de nouveaux types de bloc serveur.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        title = (try c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        anchor = try c.decodeIfPresent(String.self, forKey: .anchor)
        // `try?` (et non `decodeIfPresent`) : un `visibility` absent **ou** d'un
        // type inattendu (nombre, objet) doit retomber sur le fallback, jamais
        // faire échouer le bloc — un module ne disparaît pas sur un champ illisible.
        let rawVisibility = try? c.decode(String.self, forKey: .visibility)
        visibility = rawVisibility.flatMap(ModuleVisibility.init(rawValue:)) ?? .fallback
        variant = try c.decodeIfPresent(String.self, forKey: .variant)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        taxonomy = try c.decodeIfPresent(String.self, forKey: .taxonomy)
        termSlug = try c.decodeIfPresent(String.self, forKey: .termSlug)
        count = try c.decodeIfPresent(Int.self, forKey: .count)
        viewAllUrl = try c.decodeIfPresent(String.self, forKey: .viewAllUrl)
        recipeIds = try c.decodeIfPresent([Int].self, forKey: .recipeIds)
        terms = try c.decodeIfPresent([HomeTile].self, forKey: .terms)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        ctaText = try c.decodeIfPresent(String.self, forKey: .ctaText)
        ctaUrl = try c.decodeIfPresent(String.self, forKey: .ctaUrl)
        loginUrl = try c.decodeIfPresent(String.self, forKey: .loginUrl)
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
    }
}

/// Tuile de terme d'un bloc `category_tiles` (déjà embarquée — pas de fetch).
struct HomeTile: Decodable, Identifiable {
    let slug: String
    let name: String
    let url: String?
    let count: Int

    var id: String { slug }

    enum CodingKeys: String, CodingKey { case slug, name, url, count }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        count = (try c.decodeIfPresent(Int.self, forKey: .count)) ?? 0
    }
}

/// Instantané complet de l'accueil, sérialisable sur disque.
///
/// Structure des blocs conservée en **JSON brut** (`HomePayload` n'est que
/// `Decodable`, on le redécode au chargement) + recettes nécessaires au rendu
/// (`Recipe` est `Codable` synthétisé → round-trip sûr). Permet un rendu
/// immédiat de l'accueil au lancement, même hors-ligne (stale-while-revalidate).
struct HomeCacheSnapshot: nonisolated Codable {
    let payload: Data       // réponse brute /home-recettes (blocs + recipe_ids)
    let recent: [Recipe]    // 16 dernières recettes (ordre serveur)
    let hydrated: [Recipe]  // recettes des rails/featured (réordonnées par ids)
}

/// Service de la home pilotée serveur.
final class HomeService {
    static let shared = HomeService()

    private static let snapshotKey = "home-snapshot-v1"
    /// TTL de l'accueil : 15 min (demande produit).
    static let snapshotTTL: TimeInterval = 15 * 60

    /// Réponse brute `/home-recettes` (session bornée) avec **retry à backoff**
    /// (1 s puis 3 s) sur erreur transitoire — absorbe un hoquet réseau au
    /// rafraîchissement avant de dégrader sur les recettes récentes.
    func fetchHomeData() async throws -> Data {
        guard let url = URL(string: "\(APIConfig.shared.restV1)/home-recettes") else {
            throw APIError.invalidURL
        }
        let backoff: [UInt64] = [1_000_000_000, 3_000_000_000]
        var lastError: APIError = .serverError
        for attempt in 0...backoff.count {
            do {
                let (data, response) = try await AppHTTP.session.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    throw APIError.http((response as? HTTPURLResponse)?.statusCode ?? 500)
                }
                return data
            } catch {
                let mapped = APIError.from(error)
                lastError = mapped
                if attempt < backoff.count && mapped.isTransient {
                    try? await Task.sleep(nanoseconds: backoff[attempt])
                    continue
                }
                throw mapped
            }
        }
        throw lastError
    }

    func fetchHome() async throws -> HomePayload {
        try JSONDecoder().decode(HomePayload.self, from: await fetchHomeData())
    }

    /// Dernier instantané pour affichage immédiat, `nil` s'il n'y en a pas.
    ///
    /// - Parameter ignoringTTL: hors connexion, l'âge de l'instantané ne doit
    ///   plus rien décider. Le TTL de 15 minutes existe pour éviter de servir du
    ///   contenu périmé **alors qu'on peut aller en chercher du frais** ; hors
    ///   réseau cette alternative n'existe pas, et l'appliquer quand même ne
    ///   produit qu'un mur d'erreur à la place d'un accueil légèrement daté. Le
    ///   bandeau hors ligne reste affiché au-dessus : l'utilisateur sait que le
    ///   contenu peut avoir vieilli.
    ///
    ///   La décision est passée en paramètre plutôt que lue ici : `HomeService`
    ///   n'a pas à dépendre de `NetworkMonitor`, isolé sur le `MainActor`, et la
    ///   règle reste visible à l'appel.
    func cachedSnapshot(ignoringTTL: Bool = false) -> HomeCacheSnapshot? {
        DiskCache.shared.load(
            HomeCacheSnapshot.self,
            forKey: Self.snapshotKey,
            maxAge: ignoringTTL ? .greatestFiniteMagnitude : Self.snapshotTTL
        )
    }

    /// Charge la home complète (blocs + recettes) et **réécrit le cache disque**.
    ///
    /// - Returns: l'instantané frais ; un repli « recettes récentes » si le
    ///   home-builder échoue mais que le CPT `recipe` répond ; `nil` si tout
    ///   échoue (l'appelant décide alors d'afficher un cache plus ancien ou le
    ///   mur d'erreur).
    @discardableResult
    func loadAndCache() async -> HomeCacheSnapshot? {
        // Recettes récentes en parallèle et indépendamment du home-builder.
        // `showToastOnError: false` : l'accueil gère l'échec par le cache + son
        // état d'erreur dédié ; pas de toast parasite lors d'un rafraîchissement.
        async let recentTask = (try? await APIService.shared.fetchRecipes(perPage: 16, showToastOnError: false)) ?? []
        do {
            let payloadData = try await fetchHomeData()
            let payload = try JSONDecoder().decode(HomePayload.self, from: payloadData)

            // Union dédupliquée des IDs des rails/featured → un seul fetch batché.
            let allIDs = Array(Set(payload.blocks.flatMap { block -> [Int] in
                guard block.type == "rail" || block.type == "featured",
                      let ids = block.recipeIds else { return [] }
                return ids
            }))
            let hydrated = (try? await APIService.shared.fetchRecipesByIDs(allIDs)) ?? []
            let recent = await recentTask

            let snapshot = HomeCacheSnapshot(payload: payloadData, recent: recent, hydrated: hydrated)
            DiskCache.shared.store(snapshot, forKey: Self.snapshotKey)
            return snapshot
        } catch {
            // Home-builder KO : repli sur les recettes récentes (sans réécrire le
            // cache, faute de blocs). `nil` seulement si même ce repli est vide.
            let recent = await recentTask
            AppLogger.api.error("Erreur chargement home: \(error)")
            guard !recent.isEmpty else { return nil }
            return HomeCacheSnapshot(payload: Data(), recent: recent, hydrated: [])
        }
    }
}
