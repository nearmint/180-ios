import SwiftUI

/// Carrousel « Slider de recettes » — module home `recipes_slider`.
///
/// Le serveur expose ce module comme un `rail` porteur de `variant: "slider"`
/// (cf. `inc/rest/home-recettes.php`) : mêmes données qu'un rail « récents »,
/// seule la **présentation** change — une recette en vedette à la fois, au lieu
/// du rail dense de cartes 200 pt.
///
/// Le visuel d'un slide est **exactement** le hero de l'accueil
/// (`FeaturedRecipeCard`, donc `RecipeCard(style: .featured)`) : aucun langage
/// visuel n'est introduit ici, seule la mécanique de défilement l'est.
///
/// Défilement : `ScrollView` horizontale + `scrollTargetBehavior(.viewAligned)`
/// (iOS 17) plutôt qu'un `TabView(.page)`. Le `TabView` impose une hauteur fixe
/// à ses pages, or les cartes ont une hauteur libre (titre sur une ou deux
/// lignes) ; il aurait fallu figer une hauteur au jugé et rogner ou laisser du
/// vide selon la recette.
struct RecipeSlider: View {

    let recipes: [Recipe]
    /// Ouverture d'une recette — la pile de navigation appartient à l'accueil.
    let onSelect: (Recipe) -> Void

    /// Recette actuellement calée dans le viewport, pilotée **dans les deux
    /// sens** : mise à jour par le défilement au doigt, et écrite par un tap sur
    /// l'indicateur pour y faire défiler. `nil` tant qu'aucune position n'a été
    /// établie (premier rendu) ⇒ index 0.
    @State private var currentID: Int?

    /// Réduire les animations : défilement programmatique et pastille sans
    /// animation (saut direct), comme `SplashView` / `OnboardingView`.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var currentIndex: Int {
        guard let currentID,
              let index = recipes.firstIndex(where: { $0.id == currentID }) else { return 0 }
        return index
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            slides
            if recipes.count > 1 {
                indicator
            }
        }
    }

    // MARK: - Piste

    /// Piste de slides : chaque slide occupe **toute** la largeur du viewport et
    /// porte lui-même sa gouttière de 16 pt. Le padding est donc *dans* le
    /// slide, pas sur la piste : l'alignement de `viewAligned` cale le bord du
    /// slide sur le bord du viewport, ce qui recentre parfaitement la carte à
    /// chaque arrêt, et l'écart perçu entre deux cartes vaut deux gouttières.
    private var slides: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 0) {
                ForEach(recipes) { recipe in
                    Button {
                        onSelect(recipe)
                    } label: {
                        FeaturedRecipeCard(recipe: recipe)
                            // Zone tactile bornée au visuel de la carte, comme
                            // le hero de l'accueil.
                            .contentShape(Rectangle())
                            .padding(.horizontal, 16)
                    }
                    .buttonStyle(PressButtonStyle())
                    .containerRelativeFrame(.horizontal)
                    // Identité explicite du slide : c'est elle que lit et écrit
                    // `scrollPosition(id:)`. L'identité implicite du `ForEach`
                    // suffit à la lecture (défilement au doigt) mais pas au
                    // défilement **programmatique** (tap sur l'indicateur,
                    // action ajustable VoiceOver), qui reste sans effet sans ce
                    // `.id`.
                    .id(recipe.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $currentID)
    }

    // MARK: - Indicateur

    /// Frise de pagination : pastille allongée sur la position courante, points
    /// sur les autres — l'équivalent iOS de la frise du module web.
    ///
    /// La rangée est **un seul** élément d'accessibilité, ajustable : VoiceOver
    /// annonce « 2 sur 6 » et balaie d'un slide à l'autre au geste haut/bas.
    /// Exposer six boutons « aller à la recette N » alourdirait le parcours pour
    /// une navigation que le balayage de la piste elle-même permet déjà.
    private var indicator: some View {
        HStack(spacing: 8) {
            ForEach(recipes) { recipe in
                let isCurrent = recipe.id == recipes[currentIndex].id
                Capsule()
                    .fill(isCurrent ? Color.accent180 : Color(.systemGray4))
                    .frame(width: isCurrent ? 20 : 6, height: 6)
                    // Cible tactile élargie autour d'un point de 6 pt, sans
                    // écarter visuellement les pastilles.
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(reduceMotion ? nil : .snappy) { currentID = recipe.id }
                    }
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: currentIndex)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recettes en vedette")
        .accessibilityValue("\(currentIndex + 1) sur \(recipes.count)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: scroll(to: currentIndex + 1)
            case .decrement: scroll(to: currentIndex - 1)
            @unknown default: break
            }
        }
    }

    private func scroll(to index: Int) {
        guard recipes.indices.contains(index) else { return }
        withAnimation(reduceMotion ? nil : .snappy) { currentID = recipes[index].id }
    }
}
