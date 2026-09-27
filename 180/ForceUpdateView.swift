import SwiftUI

/// Écran bloquant affiché quand la version installée est trop ancienne
struct ForceUpdateView: View {
    let message: String
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundColor(.accent180)

            VStack(spacing: 12) {
                Text("Mise à jour requise")
                    .font(AppFont.playfair(28, weight: .bold))
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            // Lien store seulement si l'ID App Store est configuré ; sinon, on
            // invite à chercher l'app (aucun lien factice). Pré-publication, le
            // force-update ne se déclenche de toute façon pas.
            if let storeURL = AppStoreInfo.appStoreURL {
                Link(destination: storeURL) {
                    Text("Mettre à jour")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accent180)
                        .foregroundColor(.white)
                        .cornerRadius(14)
                }
                .padding(.horizontal, 30)
            } else {
                Text("Recherchez « 180°C » sur l'App Store pour mettre à jour.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()
        }
        .interactiveDismissDisabled(true)
    }
}
