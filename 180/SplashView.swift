import SwiftUI
import UIKit

struct SplashView: View {
    @State private var isActive = false
    @State private var logoOpacity: Double = 0
    @State private var progress: Double = 0
    @State private var forceUpdateMessage: String? = nil
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Accent jaune très discret de la barre de progression (#FFAE3A).
    private static let progressTint = Color(red: 1.0, green: 0.682, blue: 0.227)

    /// Délai de grâce : au-delà, on entre dans l'app même si le préchargement
    /// n'est pas terminé (jamais de blocage indéfini).
    private static let graceTimeout: UInt64 = 6_000_000_000
    /// Durée minimale d'affichage du splash (laisse respirer le logo).
    private static let minDisplay: TimeInterval = 1.2

    var body: some View {
        if isActive {
            if let message = forceUpdateMessage {
                ForceUpdateView(message: message)
            } else if !hasCompletedOnboarding {
                OnboardingView()
            } else {
                ContentView()
            }
        } else {
            ZStack {
                (colorScheme == .dark ? Color.black : Color.white)
                    .ignoresSafeArea()

                Image("logo")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(colorScheme == .dark ? .white : .black)
                    .frame(height: 80)
                    .opacity(logoOpacity)
                    .onAppear {
                        if reduceMotion {
                            logoOpacity = 1.0
                        } else {
                            withAnimation(.easeIn(duration: 0.8)) { logoOpacity = 1.0 }
                        }
                    }

                // Barre de progression fine et discrète, ancrée en bas.
                VStack {
                    Spacer()
                    progressBar
                        .padding(.horizontal, 60)
                        .padding(.bottom, 60)
                }
            }
            .onAppear {
                Task {
                    await preloadWithGrace()
                    enterApp()
                }
            }
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 3)
                Capsule()
                    .fill(Self.progressTint)
                    .frame(width: max(0, geo.size.width * progress), height: 3)
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }

    // MARK: - Préchargement

    /// Précharge l'accueil pendant le splash, borné par le délai de grâce et une
    /// durée d'affichage minimale.
    private func preloadWithGrace() async {
        let start = Date()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await runPreload() }
            group.addTask { try? await Task.sleep(nanoseconds: Self.graceTimeout) }
            // Entrer dès que le PREMIER se termine (préchargement fini OU grâce
            // écoulée), puis annuler l'autre.
            await group.next()
            group.cancelAll()
        }

        // Laisser le logo visible au moins `minDisplay` si le préchargement a été
        // très rapide (cache chaud) — évite un flash désagréable.
        let elapsed = Date().timeIntervalSince(start)
        if elapsed < Self.minDisplay {
            try? await Task.sleep(nanoseconds: UInt64((Self.minDisplay - elapsed) * 1_000_000_000))
        }
    }

    private func runPreload() async {
        // 1. Version minimale (peut imposer une mise à jour forcée).
        let result = await AppVersionService.shared.checkMinimumVersion()
        setProgress(0.3)
        if case .forceUpdate(let message) = result {
            await MainActor.run { forceUpdateMessage = message }
            setProgress(1.0)
            return
        }

        // 2. Accueil : warme le cache disque (snapshot stale-while-revalidate).
        let snapshot = await HomeService.shared.loadAndCache()
        setProgress(0.75)

        // 3. Images above-the-fold (à-la-une + premières cartes).
        if let snapshot {
            await prefetchAboveTheFold(snapshot)
        }
        setProgress(1.0)
    }

    /// Précharge les premiers visuels visibles pour qu'ils soient affichés dès
    /// l'entrée dans l'app.
    private func prefetchAboveTheFold(_ snapshot: HomeCacheSnapshot) async {
        let scale = await MainActor.run { UIScreen.main.scale }

        // Cible : hero (à-la-une) au format large, puis premières cartes.
        var targets: [(url: URL, maxPixel: CGFloat)] = []
        let heroURL = (snapshot.hydrated.first ?? snapshot.recent.first)?.imageURL
        if let heroURL, let url = URL(string: heroURL) {
            targets.append((url, 450 * scale))
        }
        let cards = snapshot.hydrated.isEmpty ? snapshot.recent : snapshot.hydrated
        for recipe in cards.dropFirst().prefix(4) {
            if let str = recipe.imageURL, let url = URL(string: str) {
                targets.append((url, 240 * scale))
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for target in targets {
                group.addTask {
                    await ImageCacheManager.shared.prefetch(target.url, maxPixelSize: target.maxPixel)
                }
            }
        }
    }

    @MainActor
    private func setProgress(_ value: Double) {
        if reduceMotion {
            progress = value
        } else {
            withAnimation(.easeInOut(duration: 0.3)) { progress = value }
        }
    }

    @MainActor
    private func enterApp() {
        if reduceMotion {
            isActive = true
        } else {
            withAnimation(.easeInOut(duration: 0.3)) { isActive = true }
        }
    }
}
