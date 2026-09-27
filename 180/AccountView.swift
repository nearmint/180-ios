import SwiftUI

struct AccountView: View {
    @StateObject private var auth = AuthService.shared
    @StateObject private var newsletter = NewsletterStore()
    @StateObject private var notifManager = NotificationManager.shared
    @State private var offline = OfflineSyncService.shared
    @State private var showLogin = false
    @State private var showLogoutConfirmation = false
    @State private var showLogoutDialog = false
    @State private var showOfflineDisableDialog = false
    @State private var showOfflineClearDialog = false
    @AppStorage("appearanceMode") private var appearanceMode: Int = 0
    @Environment(\.horizontalSizeClass) var horizontalSizeClass

    /// Position du toggle push dérivée de l'état **réel** (`pushEffectivelyEnabled`),
    /// jamais d'un `@State` optimiste. Le setter délègue toute la matrice de
    /// comportement à `NotificationManager.setPushSubscription`.
    private var pushSubscriptionBinding: Binding<Bool> {
        Binding(
            get: { notifManager.pushEffectivelyEnabled },
            set: { newValue in
                Task { await notifManager.setPushSubscription(enabled: newValue) }
            }
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if horizontalSizeClass == .regular {
                    HStack {
                        Spacer()
                        accountList
                            .frame(maxWidth: 600)
                        Spacer()
                    }
                } else {
                    accountList
                }
            }
            .navigationTitle("Mon compte")
            .sheet(isPresented: $showLogin) { LoginView() }
            .overlay { logoutOverlay }
        }
        .offlineBanner()
        // Rejoué à chaque changement de session **et** quand l'e-mail du compte
        // arrive (résolu de façon asynchrone après le login). Toute la logique de
        // lecture/écriture vit dans `NewsletterStore` (cf. ce fichier).
        .task(id: "\(auth.isLoggedIn)|\(auth.email)|\(auth.contentGeneration)") {
            await newsletter.hydrate()
        }
        // Pas de page vue `/reglages` distincte : les réglages de l'app sont une
        // section de « Mon compte », pas un écran à part.
        .onAppear { UmamiTracker.shared.trackScreen(path: "/compte", title: "Compte") }
    }

    private var accountList: some View {
        List {
                if auth.isLoggedIn {

                    // MARK: 1 - Profil
                    Section {
                        HStack(spacing: 16) {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 50))
                                .foregroundColor(.gray)
                                .background(Color(.systemGray5))
                                .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(auth.firstName) \(auth.lastName)".trimmingCharacters(in: .whitespaces).isEmpty ? auth.username : "\(auth.firstName) \(auth.lastName)")
                                    .font(.headline)
                                Text(auth.isSubscriber ? "Abonné" : "Non abonné")
                                    .font(.caption)
                                    .foregroundColor(auth.isSubscriber ? .green : .secondary)
                            }
                        }
                        .padding(.vertical, 8)

                        if auth.isSubscriber {
                            WebLink(url: URL(string: APIConfig.shared.autoLoginLink("/mon-compte/#abonnement", token: auth.getToken()))!) {
                                HStack {
                                    Image(systemName: "creditcard")
                                        .foregroundColor(.accent180)
                                    Text("Gérer mon abonnement")
                                        .foregroundColor(.primary)
                                }
                            }
                        } else {
                            WebLink(url: URL(string: APIConfig.shared.webLink("/abonnement/"))!, onOpen: { AnalyticsService.signupClick(source: "account") }) {
                                HStack {
                                    Image(systemName: "star")
                                        .foregroundColor(.accent180)
                                    Text("S'abonner")
                                        .foregroundColor(.primary)
                                }
                            }
                        }

                        WebLink(url: URL(string: APIConfig.shared.webLink("/boutique/"))!, onOpen: { AnalyticsService.boutiqueClick() }) {
                            HStack {
                                Image(systemName: "bag")
                                    .foregroundColor(.accent180)
                                Text("Boutique 180°C")
                                    .foregroundColor(.primary)
                            }
                        }
                    }

                    // MARK: 2 - Notifications et newsletters
                    Section("Notifications et newsletters") {
                        // Toggle d'abonnement push (tête de section). iOS interdit de
                        // révoquer l'autorisation depuis l'app : ce contrôle pilote
                        // l'abonnement OneSignal, jamais la permission système.
                        Toggle(isOn: pushSubscriptionBinding) {
                            HStack {
                                Image(systemName: "bell.badge")
                                    .foregroundColor(.accent180)
                                Text("Notifications push")
                            }
                        }
                        .tint(.accent180)
                        .disabled(notifManager.isDenied)
                        // Rafraîchi à l'apparition ; le foreground est couvert par
                        // l'observateur `willEnterForeground` de NotificationManager.
                        .onAppear { notifManager.checkStatus() }

                        if notifManager.isDenied {
                            Button {
                                Task { await notifManager.openNotificationSettings() }
                            } label: {
                                Text("Activer dans les Réglages")
                                    .font(.caption2)
                                    .foregroundColor(.accent180)
                            }
                        }

                        // Toggle piloté par `NewsletterStore` : le setter du
                        // binding n'est appelé que sur geste utilisateur, jamais
                        // par les mises à jour serveur → plus d'écho parasite.
                        Toggle(isOn: newsletter.binding) {
                            HStack {
                                Image(systemName: "envelope")
                                    .foregroundColor(auth.isSubscriber ? .accent180 : .gray)
                                Text("Les Cahiers de Delphine")
                                    .foregroundColor(auth.isSubscriber ? .primary : .gray)
                                // Indicateur de chargement pendant la mutation (E5).
                                if newsletter.isBusy {
                                    Spacer()
                                    ProgressView().controlSize(.small)
                                }
                            }
                        }
                        .disabled(newsletter.isBusy || !auth.isSubscriber)
                        .tint(.accent180)

                        if !auth.isSubscriber {
                            Text("Réservé aux abonnés 180°C")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    // MARK: 3 - Recettes hors ligne (abonnés uniquement)
                    if offline.isAvailable {
                        offlineSection
                    }

                    // MARK: 4 - Centre d'aide
                    Section("Centre d'aide") {
                        Button {
                            if let mailURL = URL(string: "mailto:\(APIConfig.shared.editorialEmail)?subject=\("[App 180°C] Contact rédaction".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") {
                                UIApplication.shared.open(mailURL)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "envelope")
                                    .foregroundColor(.accent180)
                                Text("Contacter la rédaction")
                                    .foregroundColor(.primary)
                            }
                        }

                        Button {
                            AnalyticsService.contactSupport()
                            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                            let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
                            let iosVersion = UIDevice.current.systemVersion
                            let deviceModel = UIDevice.current.model
                            let isSubscriber = AuthService.shared.isSubscriber ? "Abonné" : "Non abonné"
                            let username = AuthService.shared.username
                            let email = AuthService.shared.email
                            let newsletterStatus = UserDefaults.standard.bool(forKey: "newsletter_cahiers") ? "Inscrit" : "Non inscrit"
                            // Dernier code de refus serveur newsletter, joint au
                            // diagnostic : rend la cause lisible même en Release
                            // (TestFlight), sans exposer de code dans l'UI courante.
                            let newsletterError = newsletter.lastErrorCode.map { " · dernier refus: \($0)" } ?? ""

                            let debugInfo = """


                            ---
                            ⚠️ Informations techniques – Ne pas effacer ⚠️
                            App : 180°C v\(appVersion) (\(buildNumber))
                            iOS : \(iosVersion)
                            Appareil : \(deviceModel)
                            Utilisateur : \(username) (\(email))
                            Abonnement : \(isSubscriber)
                            Newsletter : \(newsletterStatus)\(newsletterError)
                            ---
                            """

                            let subject = "[App 180°C] Demande de support"
                            let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
                            let encodedBody = debugInfo.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? debugInfo

                            if let url = URL(string: "mailto:\(APIConfig.shared.supportEmail)?subject=\(encodedSubject)&body=\(encodedBody)") {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "questionmark.bubble")
                                    .foregroundColor(.accent180)
                                Text("Contacter le support")
                                    .foregroundColor(.primary)
                            }
                        }

                        // Partage masqué tant que l'ID App Store n'est pas configuré
                        // (pas de lien factice). Réactivé automatiquement à la publication.
                        if let appStoreURL = AppStoreInfo.appStoreURL {
                            ShareLink(item: appStoreURL) {
                                HStack {
                                    Image(systemName: "square.and.arrow.up")
                                        .foregroundColor(.accent180)
                                    Text("Partager l'app")
                                        .foregroundColor(.primary)
                                }
                            }
                        }

                        // « Noter » masqué tant que l'app n'est pas publiée.
                        if AppStoreInfo.isConfigured {
                            Button {
                                AnalyticsService.rateAppClick()
                                if let url = AppStoreInfo.reviewURL {
                                    UIApplication.shared.open(url)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "star.bubble")
                                        .foregroundColor(.accent180)
                                    Text("Notez l'app")
                                        .foregroundColor(.primary)
                                }
                            }
                        }

                    }

                    // MARK: 5 - Paramètres
                    Section("Paramètres") {
                        Picker(selection: $appearanceMode) {
                            Text("Auto").tag(0)
                            Text("Clair").tag(1)
                            Text("Sombre").tag(2)
                        } label: {
                            HStack {
                                Image(systemName: "moon.fill")
                                    .foregroundColor(.accent180)
                                Text("Apparence")
                            }
                        }
                        .onChange(of: appearanceMode) { _, newValue in
                            let modeName = newValue == 0 ? "auto" : newValue == 1 ? "light" : "dark"
                            AnalyticsService.darkModeChanged(mode: modeName)
                        }

                        #if DEBUG
                        HStack {
                            Image(systemName: "ladybug.fill")
                                .foregroundColor(.secondary)
                            Text("Env push")
                            Spacer()
                            Text(PushNotificationService.shared.environmentTag)
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                        }
                        #endif

                        Button(role: .destructive) {
                            showLogoutDialog = true
                        } label: {
                            Label("Se déconnecter", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .confirmationDialog("Voulez-vous vous déconnecter ?", isPresented: $showLogoutDialog, titleVisibility: .visible) {
                            Button("Se déconnecter", role: .destructive) {
                                showLogoutConfirmation = true
                            }
                            Button("Annuler", role: .cancel) {}
                        }
                    }

                    // MARK: 6 - Informations légales
                    Section("Informations légales") {
                        WebLink(url: URL(string: APIConfig.shared.webLink("/mentions-legales/"))!) {
                            HStack {
                                Image(systemName: "doc.text")
                                    .foregroundColor(.accent180)
                                Text("Mentions légales")
                                    .foregroundColor(.primary)
                            }
                        }
                        WebLink(url: URL(string: APIConfig.shared.webLink("/cgv/"))!) {
                            HStack {
                                Image(systemName: "doc.text")
                                    .foregroundColor(.accent180)
                                Text("Conditions Générales d'Utilisation")
                                    .foregroundColor(.primary)
                            }
                        }
                        WebLink(url: URL(string: APIConfig.shared.webLink("/politique-confidentialite/"))!) {
                            HStack {
                                Image(systemName: "doc.text")
                                    .foregroundColor(.accent180)
                                Text("Politique de confidentialité")
                                    .foregroundColor(.primary)
                            }
                        }
                    }

                    Section {} footer: {
                        VStack(spacing: 4) {
                            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Tous droits réservés © 180°C, 2026")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                        .padding(.bottom, 20)
                    }

                } else {

                    // MARK: 1 - Non connecté
                    Section {
                        HStack(spacing: 16) {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 50))
                                .foregroundColor(.gray)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Non connecté")
                                    .font(.headline)
                                Text("Connectez-vous pour accéder à toutes les recettes")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 8)

                        Button {
                            showLogin = true
                        } label: {
                            HStack {
                                Image(systemName: "person.badge.key")
                                    .foregroundColor(.accent180)
                                Text("Se connecter")
                                    .foregroundColor(.primary)
                            }
                        }

                        WebLink(url: URL(string: APIConfig.shared.webLink("/abonnement/"))!, onOpen: { AnalyticsService.signupClick(source: "account") }) {
                            HStack {
                                Image(systemName: "star")
                                    .foregroundColor(.accent180)
                                Text("S'abonner")
                                    .foregroundColor(.primary)
                            }
                        }

                        WebLink(url: URL(string: APIConfig.shared.webLink("/boutique/"))!, onOpen: { AnalyticsService.boutiqueClick() }) {
                            HStack {
                                Image(systemName: "bag")
                                    .foregroundColor(.accent180)
                                Text("Boutique 180°C")
                                    .foregroundColor(.primary)
                            }
                        }
                    }

                    // MARK: 2 - Centre d'aide
                    Section("Centre d'aide") {
                        Button {
                            if let mailURL = URL(string: "mailto:\(APIConfig.shared.editorialEmail)?subject=\("[App 180°C] Contact rédaction".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") {
                                UIApplication.shared.open(mailURL)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "envelope")
                                    .foregroundColor(.accent180)
                                Text("Contacter la rédaction")
                                    .foregroundColor(.primary)
                            }
                        }

                        Button {
                            AnalyticsService.contactSupport()
                            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                            let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
                            let iosVersion = UIDevice.current.systemVersion
                            let deviceModel = UIDevice.current.model
                            let subject = "[App 180°C] Demande de support"
                            let debugInfo = "\n\n---\n⚠️ Informations techniques – Ne pas effacer ⚠️\nApp : 180°C v\(appVersion) (\(buildNumber))\niOS : \(iosVersion)\nAppareil : \(deviceModel)\n---"
                            let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
                            let encodedBody = debugInfo.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? debugInfo
                            if let url = URL(string: "mailto:\(APIConfig.shared.supportEmail)?subject=\(encodedSubject)&body=\(encodedBody)") {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "questionmark.bubble")
                                    .foregroundColor(.accent180)
                                Text("Contacter le support")
                                    .foregroundColor(.primary)
                            }
                        }

                        // Partage masqué tant que l'ID App Store n'est pas configuré
                        // (pas de lien factice). Réactivé automatiquement à la publication.
                        if let appStoreURL = AppStoreInfo.appStoreURL {
                            ShareLink(item: appStoreURL) {
                                HStack {
                                    Image(systemName: "square.and.arrow.up")
                                        .foregroundColor(.accent180)
                                    Text("Partager l'app")
                                        .foregroundColor(.primary)
                                }
                            }
                        }

                        // « Noter » masqué tant que l'app n'est pas publiée.
                        if AppStoreInfo.isConfigured {
                            Button {
                                AnalyticsService.rateAppClick()
                                if let url = AppStoreInfo.reviewURL {
                                    UIApplication.shared.open(url)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "star.bubble")
                                        .foregroundColor(.accent180)
                                    Text("Notez l'app")
                                        .foregroundColor(.primary)
                                }
                            }
                        }
                    }

                    // MARK: 3 - Paramètres
                    Section("Paramètres") {
                        Picker(selection: $appearanceMode) {
                            Text("Auto").tag(0)
                            Text("Clair").tag(1)
                            Text("Sombre").tag(2)
                        } label: {
                            HStack {
                                Image(systemName: "moon.fill")
                                    .foregroundColor(.accent180)
                                Text("Apparence")
                            }
                        }
                        .onChange(of: appearanceMode) { _, newValue in
                            let modeName = newValue == 0 ? "auto" : newValue == 1 ? "light" : "dark"
                            AnalyticsService.darkModeChanged(mode: modeName)
                        }
                    }

                    // MARK: 4 - Informations légales
                    Section("Informations légales") {
                        WebLink(url: URL(string: APIConfig.shared.webLink("/mentions-legales/"))!) {
                            HStack {
                                Image(systemName: "doc.text")
                                    .foregroundColor(.accent180)
                                Text("Mentions légales")
                                    .foregroundColor(.primary)
                            }
                        }
                        WebLink(url: URL(string: APIConfig.shared.webLink("/cgv/"))!) {
                            HStack {
                                Image(systemName: "doc.text")
                                    .foregroundColor(.accent180)
                                Text("Conditions Générales d'Utilisation")
                                    .foregroundColor(.primary)
                            }
                        }
                        WebLink(url: URL(string: APIConfig.shared.webLink("/politique-confidentialite/"))!) {
                            HStack {
                                Image(systemName: "doc.text")
                                    .foregroundColor(.accent180)
                                Text("Politique de confidentialité")
                                    .foregroundColor(.primary)
                            }
                        }
                    }

                    Section {} footer: {
                        VStack(spacing: 4) {
                            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Tous droits réservés © 180°C, 2026")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                        .padding(.bottom, 20)
                    }
                }
            }
    }

    // MARK: - Recettes hors ligne

    /// Position du toggle dérivée de l'état **réel** du service, jamais d'un
    /// `@State` optimiste (même parti pris que le toggle push).
    ///
    /// L'extinction n'est pas appliquée par le setter : elle ouvre une
    /// confirmation, car elle efface des fiches téléchargées. Tant que
    /// l'utilisateur n'a pas confirmé, `isEnabled` reste vrai et le toggle
    /// revient de lui-même en position haute.
    private var offlineBinding: Binding<Bool> {
        Binding(
            get: { offline.isEnabled },
            set: { newValue in
                if newValue {
                    offline.setEnabled(true)
                } else {
                    showOfflineDisableDialog = true
                }
            }
        )
    }

    @ViewBuilder
    private var offlineSection: some View {
        Section {
            Toggle(isOn: offlineBinding) {
                HStack {
                    Image(systemName: "arrow.down.circle")
                        .foregroundColor(.accent180)
                    Text("Télécharger mon carnet")
                }
            }
            .tint(.accent180)

            if case let .running(done, total) = offline.state, total > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(done), total: Double(total))
                        .tint(.accent180)
                    Text("Téléchargement… \(done)/\(total)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Téléchargement en cours, \(done) sur \(total)")
            }

            if offline.isEnabled {
                HStack {
                    Image(systemName: "internaldrive")
                        .foregroundColor(.accent180)
                    Text("Espace occupé")
                    Spacer()
                    Text(OfflineStore.formatted(offline.cacheSizeBytes))
                        .foregroundColor(.secondary)
                }

                Button(role: .destructive) {
                    showOfflineClearDialog = true
                } label: {
                    Label("Vider le cache", systemImage: "trash")
                }
            }
        } header: {
            Text("Recettes hors ligne")
        } footer: {
            Text("Les recettes de votre carnet sont téléchargées sur cet appareil, texte et photos, pour être consultées sans connexion.")
        }
        .onAppear { offline.refreshCacheSize() }
        .confirmationDialog(
            "Supprimer les recettes téléchargées ?",
            isPresented: $showOfflineDisableDialog,
            titleVisibility: .visible
        ) {
            Button("Désactiver et supprimer", role: .destructive) {
                offline.setEnabled(false)
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Votre carnet ne sera plus consultable hors connexion. Vos favoris, eux, sont conservés.")
        }
        .confirmationDialog(
            "Vider le cache hors ligne ?",
            isPresented: $showOfflineClearDialog,
            titleVisibility: .visible
        ) {
            Button("Vider", role: .destructive) {
                offline.disableAndPurge()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les fiches téléchargées sont supprimées de cet appareil et le téléchargement est désactivé.")
        }
    }

    // MARK: - Overlay déconnexion

    @ViewBuilder
    private var logoutOverlay: some View {
        if showLogoutConfirmation {
            VStack(spacing: 16) {
                Image(systemName: "hand.wave")
                    .font(.system(size: 50))
                    .foregroundColor(.accent180)

                Text("À bientôt !")
                    .font(.title3)
                    .fontWeight(.bold)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            .transition(.opacity)
            .onAppear {
                Haptics.success()
                AnalyticsService.logout()
                // Déconnexion **immédiate** : l'état (`isLoggedIn`, token, cookies)
                // est purgé tout de suite pour garantir la bascule UI, sans
                // dépendre du timer. Le délai ne sert plus qu'à laisser l'écran
                // « À bientôt ! » visible avant de le retirer.
                auth.logout()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation {
                        showLogoutConfirmation = false
                    }
                }
            }
        }
    }
}
