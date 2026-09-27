import Testing
import Foundation
@testable import _80

/// Contrat `wp/v2/recipe?_embed` — décodage ACF + logique premium/locked + embed.
struct RecipeDecodingTests {

    private func decode(_ json: String) throws -> Recipe {
        try JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
    }

    @Test("Décodage complet : titre, intro, portions, ingrédients, étapes, image embed")
    func decodesFullRecipe() throws {
        let recipe = try decode("""
        {
          "id": 42,
          "date": "2026-01-01T00:00:00",
          "title": {"rendered": "Tarte &amp; co"},
          "excerpt": {"rendered": "<p>Résumé</p>"},
          "recipe_intro": "<p>Une intro</p>",
          "servings": 4,
          "servings_unit": "personnes",
          "recipe_is_premium": true,
          "recipe_locked": false,
          "ingredients_groups": [
            {"group_label": "Pâte", "items": [{"line": "200 g farine"}, {"line": "1 œuf"}]}
          ],
          "steps": [
            {"step_title": "Préparer", "step_content": "<p>Mélanger</p>"}
          ],
          "_embedded": {
            "wp:featuredmedia": [{"source_url": "https://180c.fr/img.jpg"}],
            "wp:term": [[{"name": "Dessert", "slug": "dessert", "taxonomy": "recipe_category"}]]
          }
        }
        """)

        #expect(recipe.id == 42)
        #expect(recipe.cleanTitle == "Tarte & co")          // entités HTML décodées
        #expect(recipe.cleanExcerpt == "Résumé")            // balises retirées
        #expect(recipe.introText == "Une intro")
        #expect(recipe.servingsText == "Pour 4 personnes")
        #expect(recipe.imageURL == "https://180c.fr/img.jpg")
        #expect(recipe.ingredientGroups.count == 1)
        #expect(recipe.ingredientGroups.first?.lines.count == 2)
        #expect(recipe.preparationSteps.count == 1)
        #expect(recipe.categoryName == "Dessert")
    }

    @Test("Premium par défaut si champ absent ; locked retombe sur premium")
    func premiumAndLockedFallbacks() throws {
        // recipe_is_premium absent ⇒ isPremium = true ; recipe_locked absent ⇒ isLocked = isPremium.
        let recipe = try decode("""
        {
          "id": 1, "date": "2026-01-01T00:00:00",
          "title": {"rendered": "X"}, "excerpt": {"rendered": ""}
        }
        """)
        #expect(recipe.isPremium == true)
        #expect(recipe.isLocked == true)
    }

    @Test("recipe_locked = false ouvre le contenu même si premium")
    func lockedOverridesPremium() throws {
        let recipe = try decode("""
        {
          "id": 1, "date": "2026-01-01T00:00:00",
          "title": {"rendered": "X"}, "excerpt": {"rendered": ""},
          "recipe_is_premium": true, "recipe_locked": false
        }
        """)
        #expect(recipe.isPremium == true)
        #expect(recipe.isLocked == false)
    }

    @Test("Champs optionnels absents : dégradation propre")
    func minimalRecipe() throws {
        let recipe = try decode("""
        { "id": 7, "date": "2026-01-01T00:00:00", "title": {"rendered": "Min"}, "excerpt": {"rendered": ""} }
        """)
        #expect(recipe.servingsText == nil)
        #expect(recipe.ingredientGroups.isEmpty)
        #expect(recipe.preparationSteps.isEmpty)
        #expect(recipe.imageURL == nil)
    }
}
