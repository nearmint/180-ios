import SwiftUI

// MARK: - Shimmer effect

struct SkeletonView: View {
    @State private var opacity: Double = 0.3

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(.systemGray4))
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    opacity = 0.7
                }
            }
    }
}

// MARK: - Skeleton RecipeCard (200x140 + texte)

struct SkeletonRecipeCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SkeletonView()
                .frame(width: 200, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            SkeletonView()
                .frame(width: 160, height: 14)
                .padding(.top, 10)
                .padding(.horizontal, 10)

            SkeletonView()
                .frame(width: 100, height: 14)
                .padding(.top, 6)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .frame(width: 200)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }
}

// MARK: - Skeleton ligne de liste (miroir de `RecipeCard(style: .row)`)

/// Squelette d'une ligne de liste : vignette au ratio 4:3 (96 × 72, aligné sur
/// le cadrage réel des cartes) puis trois lignes de texte.
struct SkeletonRowCard: View {
    var body: some View {
        HStack(spacing: 12) {
            SkeletonView()
                .frame(width: 96, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 6) {
                SkeletonView().frame(width: 70, height: 10)
                SkeletonView().frame(maxWidth: .infinity).frame(height: 14)
                SkeletonView().frame(width: 90, height: 12)
            }

            Spacer(minLength: 8)
        }
    }
}

/// Écran de chargement des listes verticales de recettes. Reprend la métrique
/// des lignes réelles (mêmes marges, même séparateur) pour éviter le saut de
/// mise en page au moment où le contenu arrive.
struct SkeletonRecipeList: View {
    var count: Int = 6

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { _ in
                SkeletonRowCard()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Divider().padding(.leading, 16)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Skeleton FeaturedCard (pleine largeur, hauteur 320)

struct SkeletonFeaturedCard: View {
    var body: some View {
        SkeletonView()
            .frame(maxWidth: .infinity)
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
    }
}
