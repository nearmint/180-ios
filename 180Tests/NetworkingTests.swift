import Testing
import Foundation
@testable import _80

/// Mapping d'erreurs réseau typées (`APIError.from`) + classification transitoire.
struct NetworkingTests {

    @Test("URLError → APIError")
    func mapsURLErrors() {
        #expect(APIError.from(URLError(.timedOut)) == .timeout)
        #expect(APIError.from(URLError(.notConnectedToInternet)) == .offline)
        #expect(APIError.from(URLError(.networkConnectionLost)) == .offline)
        #expect(APIError.from(URLError(.cannotConnectToHost)) == .offline)
        #expect(APIError.from(URLError(.badServerResponse)) == .serverError)
    }

    @Test("DecodingError → .decodingError")
    func mapsDecodingError() {
        let err = DecodingError.valueNotFound(
            String.self,
            DecodingError.Context(codingPath: [], debugDescription: "manquant")
        )
        #expect(APIError.from(err) == .decodingError)
    }

    @Test("APIError reste lui-même (idempotent)")
    func apiErrorPassthrough() {
        #expect(APIError.from(APIError.http(404)) == .http(404))
        #expect(APIError.from(APIError.offline) == .offline)
    }

    @Test("Classification transitoire (retry ciblé)")
    func transientClassification() {
        #expect(APIError.timeout.isTransient)
        #expect(APIError.offline.isTransient)
        #expect(APIError.http(503).isTransient)
        #expect(!APIError.http(404).isTransient)
        #expect(!APIError.decodingError.isTransient)
        #expect(!APIError.invalidURL.isTransient)
    }
}

/// Filtrage local du carnet (`RecipeFilterBar.apply`) — logique pure.
struct FilterBarTests {

    private func recipe(_ json: String) throws -> Recipe {
        try JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
    }

    @Test("Filtre par mot-clé (titre, insensible à la casse)")
    func filtersByKeyword() throws {
        let tarte = try recipe("""
        {"id":1,"date":"2026-01-01T00:00:00","title":{"rendered":"Tarte aux pommes"},"excerpt":{"rendered":""}}
        """)
        let soupe = try recipe("""
        {"id":2,"date":"2026-01-01T00:00:00","title":{"rendered":"Soupe"},"excerpt":{"rendered":""}}
        """)
        let result = RecipeFilterBar.apply([tarte, soupe], keyword: "TARTE", categorySlug: nil, seasonSlug: nil)
        #expect(result.map { $0.id } == [1])
    }

    @Test("Filtre par catégorie via termes embarqués, ordre préservé")
    func filtersByCategoryPreservingOrder() throws {
        let dessert = try recipe("""
        {"id":1,"date":"2026-01-01T00:00:00","title":{"rendered":"A"},"excerpt":{"rendered":""},
         "_embedded":{"wp:term":[[{"name":"Dessert","slug":"dessert","taxonomy":"recipe_category"}]]}}
        """)
        let plat = try recipe("""
        {"id":2,"date":"2026-01-01T00:00:00","title":{"rendered":"B"},"excerpt":{"rendered":""},
         "_embedded":{"wp:term":[[{"name":"Plat","slug":"plat","taxonomy":"recipe_category"}]]}}
        """)
        let result = RecipeFilterBar.apply([dessert, plat], keyword: "", categorySlug: "dessert", seasonSlug: nil)
        #expect(result.map { $0.id } == [1])
    }
}
