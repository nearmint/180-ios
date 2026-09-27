import Testing
import Foundation
@testable import _80

/// Découpage des IDs en pages `wp/v2`.
///
/// Ce n'est pas un détail d'implémentation : un `per_page` supérieur à 100 fait
/// répondre 400 au serveur, donc échouer le chargement entier du carnet.
struct RecipePagingTests {

    @Test("Une liste vide ne produit aucune page")
    func emptyYieldsNoPage() {
        #expect(RecipePaging.chunk([]).isEmpty)
    }

    @Test("Une liste plus courte que la borne tient en une page")
    func shortListFitsOnePage() {
        let pages = RecipePaging.chunk(Array(1...37))
        #expect(pages.count == 1)
        #expect(pages[0].count == 37)
    }

    @Test("Exactement cent ids tiennent en une seule page")
    func exactlyHundredFitsOnePage() {
        let pages = RecipePaging.chunk(Array(1...100))
        #expect(pages.count == 1)
        #expect(pages[0].count == 100)
    }

    @Test("Cent-et-un ids basculent sur deux pages")
    func hundredAndOneSplits() {
        let pages = RecipePaging.chunk(Array(1...101))
        #expect(pages.map(\.count) == [100, 1])
    }

    @Test("Au-delà de cent, découpage sans perte ni réordonnancement")
    func largeListIsPagedLosslessly() {
        let ids = Array(1...250)

        let pages = RecipePaging.chunk(ids)

        #expect(pages.map(\.count) == [100, 100, 50])
        #expect(pages.flatMap { $0 } == ids, "ordre et contenu doivent être préservés")
        #expect(pages.allSatisfy { $0.count <= RecipePaging.maxPerPage },
                "aucune page ne doit dépasser la borne serveur")
    }

    @Test("La borne est paramétrable pour les tests")
    func customBoundIsHonoured() {
        let pages = RecipePaging.chunk(Array(1...7), maxPerPage: 3)
        #expect(pages.map(\.count) == [3, 3, 1])
        #expect(pages.flatMap { $0 } == Array(1...7))
    }

    @Test("Les doublons ne sont pas dédupliqués — ce n'est pas le rôle du découpage")
    func duplicatesArePreserved() {
        // La déduplication appartient à l'appelant : le découpage doit rester une
        // transformation strictement mécanique, sans décision sur le contenu.
        let pages = RecipePaging.chunk([5, 5, 7], maxPerPage: 2)
        #expect(pages.flatMap { $0 } == [5, 5, 7])
    }
}
