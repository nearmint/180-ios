import SwiftUI
import WebKit
import Foundation
import os

/// Pont de session web ↔ app : un `WKWebView` neuf ne partage pas le JWT de
/// l'app, et le cookie WordPress posé lors du 302 d'autologin n'est pas conservé
/// de façon fiable par WebKit (notamment derrière le cert self-signed local).
///
/// On amorce donc la session côté `URLSession` — qui atteint déjà `180c.local`
/// pour tout le reste de l'API — afin de récupérer les cookies WP dans
/// `HTTPCookieStorage.shared`, puis on les injecte dans le cookie store du webview
/// avant le chargement. Le webview ouvre alors la page **déjà connecté**.
enum WebSession {

    /// Amorce la session web si `url` est un lien autologin `?180c_app_login=1`.
    ///
    /// Le JWT n'est **jamais** dans l'URL : il est envoyé en **corps POST**
    /// (`jwt=…`) à l'endpoint thème, qui valide et pose le cookie WP dans
    /// `HTTPCookieStorage.shared`. Renvoie l'URL de destination (`redirect=`) à
    /// charger. Pour un lien normal, renvoie l'URL telle quelle.
    ///
    /// Retourne `nil` si l'amorçage d'un lien authentifié **échoue** (token
    /// invalide/expiré, réseau) : l'appelant n'ouvre alors pas de webview (vide /
    /// déconnecté) et signale l'erreur. Le visiteur non connecté ouvre la page
    /// publique normalement.
    static func prime(_ url: URL) async -> URL? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems,
              items.contains(where: { $0.name == "180c_app_login" })
        else { return url }   // lien normal : pas d'amorçage

        // Destination = paramètre `redirect` (chemin relatif, pas un secret).
        let redirect = items.first(where: { $0.name == "redirect" })?.value
        let destination = redirect.flatMap { resolveTarget($0, base: url) } ?? url

        // Pas de token (visiteur) : on ouvre la page (logguée côté site si besoin).
        guard let token = AuthService.shared.getToken(), !token.isEmpty else {
            return destination
        }

        let primed = await postLogin(token: token, base: url)
        guard primed else {
            await MainActor.run {
                ToastManager.shared.show("Connexion à votre compte impossible. Réessayez.", type: .error)
            }
            return nil
        }
        return destination
    }

    /// POST `jwt=<token>` (form-urlencoded, **hors URL**) vers `?180c_app_login=1`.
    /// L'endpoint valide le jeton et répond `Set-Cookie` (stocké dans
    /// `HTTPCookieStorage.shared`).
    ///
    /// - Returns: `true` si le **cookie de session WordPress est effectivement
    ///   posé**. On ne statue volontairement PAS sur le code HTTP : l'endpoint
    ///   termine par une redirection, et `AppSessionDelegate` refuse de suivre un
    ///   3xx sur POST (garde-fou anti-dégradation POST→GET) — la réponse remonte
    ///   donc en 302, ce que l'ancien test `== 200` interprétait à tort comme un
    ///   échec. À l'inverse, un 200 peut être une page d'erreur sans cookie.
    ///   La présence du cookie est le seul critère fiable.
    private static func postLogin(token: String, base: URL) async -> Bool {
        guard let scheme = base.scheme, let host = base.host,
              let loginURL = URL(string: "\(scheme)://\(host)/?180c_app_login=1") else {
            return false
        }
        var request = URLRequest(url: loginURL)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = true
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = token.addingPercentEncoding(withAllowedCharacters: allowed) ?? token
        request.httpBody = Data("jwt=\(encoded)".utf8)

        guard let (_, response) = try? await AppHTTP.session.data(for: request) else {
            AppLogger.auth.error("[SSO web] échec de transport sur l'amorçage")
            return false
        }

        let established = hasSessionCookie(for: loginURL)
        #if DEBUG
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let names = (HTTPCookieStorage.shared.cookies(for: loginURL) ?? [])
            .map(\.name).joined(separator: ", ")
        AppLogger.auth.info("[SSO web] HTTP \(status) — cookie session: \(established) — cookies: [\(names)]")
        #endif
        return established
    }

    /// Cookie d'authentification WordPress (`wordpress_logged_in_<hash>`, et son
    /// pendant HTTPS `wordpress_sec_<hash>`). Sa présence prouve que la session
    /// web est réellement ouverte. `wordpress_test_cookie`, posé par WP sur
    /// n'importe quelle réponse, est volontairement exclu.
    private static func hasSessionCookie(for url: URL) -> Bool {
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        return cookies.contains {
            $0.name.hasPrefix("wordpress_logged_in_") || $0.name.hasPrefix("wordpress_sec_")
        }
    }

    /// Construit l'URL absolue de la cible `redirect` (chemin relatif) à partir
    /// du host du lien autologin.
    private static func resolveTarget(_ path: String, base: URL) -> URL? {
        if let absolute = URL(string: path), absolute.scheme != nil { return absolute }
        guard let scheme = base.scheme, let host = base.host else { return nil }
        let normalized = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: "\(scheme)://\(host)\(normalized)")
    }

    /// Purge la session web à la déconnexion : cookies WP du storage partagé
    /// (`HTTPCookieStorage.shared`, amorcé par `prime`) **et** données du
    /// `WKWebView` (cookies + stockage local/session du data store par défaut,
    /// celui qu'utilise `WebViewContainer`). Après ça, le webview compte rouvre
    /// **déconnecté**, cohérent avec l'état app après `logout()`.
    static func clearSession() {
        let shared = HTTPCookieStorage.shared
        shared.cookies?.forEach { shared.deleteCookie($0) }

        // WebKit doit être manipulé sur le main ; le data store par défaut est
        // partagé avec les `WKWebView` créés par `WebViewContainer`.
        DispatchQueue.main.async {
            let store = WKWebsiteDataStore.default()
            let types: Set<String> = [
                WKWebsiteDataTypeCookies,
                WKWebsiteDataTypeLocalStorage,
                WKWebsiteDataTypeSessionStorage,
            ]
            store.fetchDataRecords(ofTypes: types) { records in
                store.removeData(ofTypes: types, for: records) {}
            }
        }
    }

    /// Copie les cookies applicables à `url` depuis `HTTPCookieStorage.shared`
    /// vers le store du webview, puis exécute `completion` (le chargement).
    /// Sans cookie pertinent (lien public), `completion` s'exécute immédiatement.
    @MainActor
    static func injectCookies(into webView: WKWebView, for url: URL, then completion: @escaping () -> Void) {
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        guard !cookies.isEmpty else { completion(); return }

        let store = webView.configuration.websiteDataStore.httpCookieStore
        func setNext(_ remaining: ArraySlice<HTTPCookie>) {
            guard let cookie = remaining.first else { completion(); return }
            store.setCookie(cookie) { setNext(remaining.dropFirst()) }
        }
        setNext(cookies[...])
    }
}

/// Navigateur in-app basé sur `WKWebView` (jamais `SFSafariViewController`) :
/// barre de titre, bouton fermer, indicateur de chargement.
///
/// Pour les liens authentifiés, la session est amorcée en amont par `WebSession`
/// (voir `WebLink`) puis injectée ici dans le cookie store avant chargement, si
/// bien que la page s'ouvre déjà connectée.
struct InAppBrowserView: View {
    /// Source de chargement. `direct` = URL déjà prête (usage historique :
    /// `WebLink` après amorçage, deeplink `.web`). `authenticating` = amorce la
    /// session (`WebSession.prime`) **après** présentation, spinner affiché, puis
    /// charge la page ; en cas d'échec d'amorçage, charge `fallback` (page
    /// publique) plutôt que de bloquer.
    private enum Source {
        case direct(URL)
        case authenticating(autologin: URL, fallback: URL)
    }

    private let source: Source
    var title: String?

    @Environment(\.dismiss) private var dismiss
    /// URL effectivement chargée. `nil` tant que l'amorçage n'a pas résolu la
    /// cible (mode `authenticating`) : seul le spinner s'affiche alors.
    @State private var loadURL: URL?
    @State private var isLoading = true

    /// URL déjà prête à charger (comportement historique, inchangé).
    init(url: URL, title: String? = nil) {
        self.source = .direct(url)
        self.title = title
        self._loadURL = State(initialValue: url)
    }

    /// Amorce la session web puis charge la page, en présentant l'indicateur de
    /// chargement dès l'ouverture (pas d'écran figé). Échec d'amorçage → charge
    /// `fallback` : une notification tapée doit toujours ouvrir quelque chose.
    init(authenticating autologin: URL, fallback: URL, title: String? = nil) {
        self.source = .authenticating(autologin: autologin, fallback: fallback)
        self.title = title
        self._loadURL = State(initialValue: nil)
    }

    private var titleHost: String? {
        switch source {
        case .direct(let url):            return url.host
        case .authenticating(_, let fb):  return fb.host
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                if let loadURL {
                    WebViewContainer(url: loadURL, isLoading: $isLoading)
                        .ignoresSafeArea(edges: .bottom)
                }

                if isLoading {
                    ProgressView()
                        .padding(.top, 8)
                }
            }
            .navigationTitle(title ?? titleHost ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(Text("Fermer"))
                }
            }
            .task {
                // Mode direct : rien à amorcer (URL déjà chargée).
                guard case .authenticating(let autologin, let fallback) = source else { return }
                let resolved = await WebSession.prime(autologin)
                loadURL = resolved ?? fallback
            }
        }
    }
}

/// Pont `WKWebView` ↔ SwiftUI.
private struct WebViewContainer: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        // Injecte les cookies WP (posés en amont par WebSession.prime) avant de
        // charger : la page cible s'ouvre alors avec la session web établie.
        WebSession.injectCookies(into: webView, for: url) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(isLoading: $isLoading) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var isLoading: Bool

        init(isLoading: Binding<Bool>) {
            _isLoading = isLoading
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isLoading = false
        }
    }
}

/// Bouton ouvrant un lien interne au site dans le webview in-app (remplace `Link`
/// qui sortirait vers Safari). Pour un lien autologin, amorce la session web
/// (`WebSession.prime`) avant de présenter le webview sur la page cible.
struct WebLink<Label: View>: View {
    let url: URL
    /// Action optionnelle au tap (ex. analytics) — exécutée dans l'action du
    /// bouton plutôt que via `.simultaneousGesture` (qui avale le tap en `List`).
    var onOpen: (() -> Void)? = nil
    @ViewBuilder var label: () -> Label

    /// Cible résolue (après amorçage de session). Pilote la présentation via
    /// `.sheet(item:)` : le webview n'est construit qu'une fois l'URL prête —
    /// évite la feuille grise vide d'un `.sheet(isPresented:)` + `if let`.
    @State private var target: WebTarget?
    @State private var isPreparing = false

    var body: some View {
        Button {
            onOpen?()
            guard !isPreparing else { return }
            isPreparing = true
            Task {
                let resolved = await WebSession.prime(url)
                await MainActor.run {
                    isPreparing = false
                    // `nil` = amorçage autologin échoué (toast déjà affiché par
                    // prime) → on n'ouvre pas de webview déconnecté.
                    if let resolved { target = WebTarget(url: resolved) }
                }
            }
        } label: {
            label()
        }
        .sheet(item: $target) { item in
            InAppBrowserView(url: item.url)
        }
    }
}

/// Cible web identifiable pour `.sheet(item:)`.
private struct WebTarget: Identifiable {
    let id = UUID()
    let url: URL
}

extension WebLink where Label == Text {
    /// Variante à libellé texte simple.
    init(_ title: String, url: URL, onOpen: (() -> Void)? = nil) {
        self.init(url: url, onOpen: onOpen, label: { Text(title) })
    }
}
