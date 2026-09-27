//
//  PushSoftAskSheet.swift
//  180
//
//  « Soft ask » maison présenté avant le prompt système, au moment de plus forte
//  probabilité d'acceptation. N'utilise que les tokens du design system.
//

import SwiftUI

struct PushSoftAskSheet: View {
    /// « Activer les notifications » — déclenche le prompt système.
    let onActivate: () -> Void
    /// « Plus tard » — repousse (incrémente le compteur de refus).
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 52))
                .foregroundColor(.accent180)
                .padding(.top, 40)

            Text("Ne ratez plus une recette")
                .font(.title2)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            Text("Recevez les nouvelles recettes et les numéros de 180°C dès leur parution. Une notification par semaine, pas plus.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 12) {
                Button(action: onActivate) {
                    Text("Activer les notifications")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accent180)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }

                Button(action: onDismiss) {
                    Text("Plus tard")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
