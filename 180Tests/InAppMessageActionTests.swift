import Testing
import Foundation
@testable import _80

/// Traduction de l'`actionId` d'un bouton d'In-App Message en destination.
///
/// Ce n'est pas un détail d'implémentation : l'`actionId` est saisi à la main
/// dans le dashboard OneSignal, hors de toute validation à la compilation. Une
/// forme mal reconnue n'échoue pas bruyamment — elle envoie l'utilisateur au
/// mauvais endroit, ou nulle part.
///
/// Les cas `product` ne sont pas couverts ici : leur validation appartient à
/// `NotificationRouter.productDestination`, qui dépend d'`APIConfig` (donc de
/// l'Info.plist du bundle hôte) et sort du contrat de ce parseur.
struct InAppMessageActionTests {

    // MARK: - Forme abrégée

    @Test("La forme abrégée `recipe:<id>` cible la recette")
    func shorthandRecipe() {
        #expect(InAppMessageService.destination(fromActionID: "recipe:123") == .recipe(123))
    }

    @Test("La forme abrégée `article:<id>` cible l'article")
    func shorthandArticle() {
        #expect(InAppMessageService.destination(fromActionID: "article:456") == .article(456))
    }

    @Test("Le type est insensible à la casse")
    func shorthandIsCaseInsensitive() {
        #expect(InAppMessageService.destination(fromActionID: "Recipe:123") == .recipe(123))
    }

    @Test("Les espaces autour de l'actionId sont tolérés")
    func shorthandIsTrimmed() {
        #expect(InAppMessageService.destination(fromActionID: "  recipe:123  ") == .recipe(123))
    }

    /// Le découpage se fait sur le **premier** `:` : découper sur le dernier, ou
    /// sur tous, amputerait le schéma de l'URL.
    @Test("Une URL abrégée conserve son schéma malgré le `:` du séparateur")
    func shorthandURLKeepsScheme() {
        let expected = URL(string: "https://www.180c.fr/boutique?ref=iam")!
        #expect(
            InAppMessageService.destination(fromActionID: "url:https://www.180c.fr/boutique?ref=iam")
                == .url(expected)
        )
    }

    // MARK: - Forme requête

    @Test("La forme requête cible la recette")
    func queryFormRecipe() {
        #expect(InAppMessageService.destination(fromActionID: "type=recipe&id=123") == .recipe(123))
    }

    /// Seule la forme requête peut transporter une URL percent-encodée.
    @Test("La forme requête décode une URL percent-encodée")
    func queryFormDecodesURL() {
        let expected = URL(string: "https://www.180c.fr/page?a=b")!
        #expect(
            InAppMessageService.destination(
                fromActionID: "type=url&url=https%3A%2F%2Fwww.180c.fr%2Fpage%3Fa%3Db"
            ) == .url(expected)
        )
    }

    @Test("Un id non numérique en forme requête ne cible rien")
    func queryFormRejectsNonNumericID() {
        #expect(InAppMessageService.destination(fromActionID: "type=recipe&id=abc") == .none)
    }

    // MARK: - Dégradations

    @Test("Un actionId absent ou vide ne cible rien", arguments: [nil, "", "   "])
    func emptyYieldsNone(actionId: String?) {
        #expect(InAppMessageService.destination(fromActionID: actionId) == .none)
    }

    /// Cas le plus courant en production : un bouton « Fermer » sans intention de
    /// navigation. Il ne doit surtout pas router.
    @Test("Un actionId libre, sans séparateur, ne cible rien")
    func freeFormYieldsNone() {
        #expect(InAppMessageService.destination(fromActionID: "fermer") == .none)
    }

    @Test("Un type inconnu ne cible rien")
    func unknownTypeYieldsNone() {
        #expect(InAppMessageService.destination(fromActionID: "podcast:12") == .none)
        #expect(InAppMessageService.destination(fromActionID: "type=podcast&id=12") == .none)
    }

    @Test("Un id nul ou négatif ne cible rien")
    func nonPositiveIDYieldsNone() {
        #expect(InAppMessageService.destination(fromActionID: "recipe:0") == .none)
        #expect(InAppMessageService.destination(fromActionID: "recipe:-3") == .none)
    }
}
