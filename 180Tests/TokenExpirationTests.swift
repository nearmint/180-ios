import Testing
import Foundation
@testable import _80

/// Lecture de l'expiration d'un JWT — le seul critère qui décide si une session
/// est encore vivante, indépendamment de ce que répond le plugin serveur.
///
/// Un faux négatif ici (jeton valide jugé illisible) déconnecte un abonné à
/// tort ; un faux positif (jeton mort jugé lisible et vivant) le laisse envoyer
/// un `Authorization` que le middleware JWT rejette, ce qui fait échouer
/// **toutes** les lectures et vide l'accueil de ses rails.
struct TokenExpirationTests {

    /// Forge un JWT `header.payload.signature` en **base64url** (RFC 7515),
    /// comme les émet le serveur : `+`/`/` remplacés, padding `=` retiré.
    private func makeJWT(payload: String) -> String {
        let encode: (String) -> String = { raw in
            Data(raw.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(encode("{\"typ\":\"JWT\",\"alg\":\"HS256\"}")).\(encode(payload)).signature"
    }

    @Test("Jeton valide : la date d'expiration est restituée")
    func readsExpirationOfValidToken() throws {
        let exp = Date().addingTimeInterval(30 * 86400).timeIntervalSince1970.rounded()
        let token = makeJWT(payload: "{\"exp\":\(Int(exp)),\"id\":42}")

        let date = try #require(AuthService.tokenExpiration(of: token))
        #expect(abs(date.timeIntervalSince1970 - exp) < 1)
        #expect(date > Date())
    }

    @Test("Jeton expiré : la date renvoyée est bien dans le passé")
    func readsExpirationOfExpiredToken() throws {
        let exp = Date().addingTimeInterval(-86400).timeIntervalSince1970.rounded()
        let token = makeJWT(payload: "{\"exp\":\(Int(exp))}")

        let date = try #require(AuthService.tokenExpiration(of: token))
        #expect(date < Date())
    }

    /// Cœur de la régression : un payload contenant `-` ou `_` (base64url) était
    /// illisible avec un décodage base64 standard. Le jeton n'était alors ni
    /// rafraîchi ni purgé — il survivait indéfiniment en keychain.
    @Test("Payload base64url (`-` / `_`) : décodé, pas jugé illisible")
    func decodesBase64URLPayload() throws {
        // Ce payload produit des `-`/`_` une fois encodé en base64url.
        let exp = Date().addingTimeInterval(86400).timeIntervalSince1970.rounded()
        let token = makeJWT(payload: "{\"exp\":\(Int(exp)),\"email\":\"a+b/c?d=e@example.com\",\"n\":\"~ÿ\"}")

        let encodedPayload = token.split(separator: ".")[1]
        #expect(encodedPayload.contains("-") || encodedPayload.contains("_"))
        #expect(AuthService.tokenExpiration(of: token) != nil)
    }

    @Test("`exp` en chaîne numérique : accepté (repli de robustesse)")
    func acceptsStringExp() throws {
        let exp = Int(Date().addingTimeInterval(86400).timeIntervalSince1970)
        let date = try #require(AuthService.tokenExpiration(of: makeJWT(payload: "{\"exp\":\"\(exp)\"}")))
        #expect(date > Date())
    }

    @Test("Jetons illisibles ⇒ nil (la session sera purgée, pas subie)")
    func returnsNilForUnreadableTokens() {
        let cases: [(String, String)] = [
            ("chaîne vide", ""),
            ("pas trois segments", "abc.def"),
            ("payload non base64", "aaa.??????.ccc"),
            ("payload non JSON", makeJWT(payload: "pas du json")),
            ("JSON sans `exp`", makeJWT(payload: "{\"id\":42}")),
            ("`exp` non numérique", makeJWT(payload: "{\"exp\":\"jamais\"}")),
        ]

        for (nom, token) in cases {
            #expect(AuthService.tokenExpiration(of: token) == nil, "\(nom) devrait être illisible")
        }
    }
}
