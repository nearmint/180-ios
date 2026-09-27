import SwiftUI

struct NotificationsView: View {
    @StateObject private var manager = NotificationManager.shared
    @State private var bannerDismissed = false

    var body: some View {
        Group {
            if manager.loadState == .failed && manager.notifications.isEmpty {
                errorState
            } else if manager.notifications.isEmpty {
                if manager.isAuthorized {
                    emptyAuthorizedState
                } else {
                    inactiveState
                }
            } else {
                listState
            }
        }
        .navigationTitle("Notifications")
        .task { await manager.loadInitial() }
        .onAppear {
            manager.checkStatus()
            UmamiTracker.shared.trackScreen(path: "/notifications", title: "Notifications")
        }
    }

    // MARK: - États

    /// Permission absente ET feed vide — écran d'invitation (apparence inchangée).
    private var inactiveState: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "bell.slash")
                .font(.system(size: 60))
                .foregroundColor(.accent180)

            Text("Restez informé")
                .font(.title)
                .fontWeight(.bold)

            Text("Activez les notifications pour être prévenu de la publication des nouvelles recettes.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                Task { await manager.handleActivationCTA() }
            } label: {
                Text("Activer les notifications")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accent180)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 40)

            if manager.isDenied {
                Text("Vous avez refusé les notifications. Vous pouvez les activer depuis les Réglages de votre iPhone.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Spacer()
        }
    }

    /// Permission accordée mais aucune notification.
    private var emptyAuthorizedState: some View {
        ContentUnavailableView(
            "Aucune notification pour le moment",
            systemImage: "bell",
            description: Text("Vous recevrez ici les alertes de nouvelles recettes et les actualités 180°C.")
        )
    }

    /// Erreur réseau et rien en cache.
    private var errorState: some View {
        ContentUnavailableView {
            Label("Connexion impossible", systemImage: "wifi.slash")
        } description: {
            Text("Impossible de charger les notifications pour le moment.")
        } actions: {
            Button("Réessayer") { Task { await manager.loadInitial() } }
                .buttonStyle(.borderedProminent)
                .tint(.accent180)
        }
    }

    /// Liste des notifications (avec bandeau inline si permission absente).
    private var listState: some View {
        List {
            // Même notion que la pastille de la cloche : le bandeau s'affiche aussi
            // après un opt-out depuis Mon compte, pas seulement sur autorisation absente.
            if !manager.pushEffectivelyEnabled && !bannerDismissed {
                inlineActivationBanner
                    .listRowSeparator(.hidden)
            }

            if manager.notifications.contains(where: { !$0.isRead }) {
                Button {
                    withAnimation { manager.markAllAsRead() }
                    Haptics.light()
                } label: {
                    Text("Tout marquer comme lu")
                        .font(.caption)
                        .foregroundColor(.accent180)
                }
                .listRowSeparator(.hidden)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            ForEach(manager.notifications) { notification in
                NotificationRow(notification: notification)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation { manager.markAsRead(notification.id) }
                        AnalyticsService.notificationOpened(id: String(notification.id), type: notification.target.type)
                        Haptics.selection()
                        NotificationRouter.shared.route(to: NotificationRouter.destination(for: notification.target))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(notification.isRead ? "" : "Appuyer pour marquer comme lu")
                    .task { await manager.loadMoreIfNeeded(current: notification) }
            }
        }
        .listStyle(.plain)
        .refreshable { await manager.refresh() }
    }

    /// Bandeau discret proposant d'activer, quand un feed existe sans permission.
    private var inlineActivationBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.badge")
                .foregroundColor(.accent180)
            VStack(alignment: .leading, spacing: 2) {
                Text("Activez les notifications")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("Soyez alerté en direct des nouvelles recettes.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Activer") { Task { await manager.handleActivationCTA() } }
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.accent180)
            Button {
                withAnimation { bannerDismissed = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Masquer le bandeau")
        }
        .padding(.vertical, 8)
    }
}

struct NotificationRow: View {
    let notification: AppNotification

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Icône
            ZStack {
                Circle()
                    .fill(notification.isRead ? Color(.systemGray5) : Color.accent180.opacity(0.15))
                    .frame(width: 44, height: 44)

                Image(systemName: notification.iconName)
                    .font(.body)
                    .foregroundColor(notification.isRead ? .gray : .accent180)
            }

            // Contenu
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(notification.title)
                        .font(.subheadline)
                        .fontWeight(notification.isRead ? .regular : .bold)

                    Spacer()

                    Text(notification.sentAt.timeAgoDisplay())
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Text(notification.body)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            // Pastille non lu
            if !notification.isRead {
                Circle()
                    .fill(Color.accent180)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 4)
        .opacity(notification.isRead ? 0.7 : 1)
    }
}

// Extension pour afficher le temps relatif
extension Date {
    func timeAgoDisplay() -> String {
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.minute, .hour, .day], from: self, to: now)

        if let day = components.day, day > 0 {
            return day == 1 ? "Hier" : "Il y a \(day) j"
        }
        if let hour = components.hour, hour > 0 {
            return "Il y a \(hour) h"
        }
        if let minute = components.minute, minute > 0 {
            return "Il y a \(minute) min"
        }
        return "À l'instant"
    }
}
