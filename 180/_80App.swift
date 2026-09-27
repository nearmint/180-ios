//
//  _80App.swift
//  180
//
//

import SwiftUI
import CoreText
import Firebase
import os

@main
struct _80App: App {
    // AppDelegate dédié à OneSignal (init dans didFinishLaunchingWithOptions).
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        let fontFiles = ["Oswald-VariableFont_wght", "PlayfairDisplay-VariableFont_wght", "PlayfairDisplay-Italic-VariableFont_wght"]
        for fontName in fontFiles {
            if let url = Bundle.main.url(forResource: fontName, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }

        Self.configureFirebase()
    }

    /// Initialise Firebase de façon **défensive**. `GoogleService-Info.plist` est
    /// volontairement versionné (Xcode Cloud clone le dépôt tel quel, cf.
    /// `.gitignore`) ; il ne contient que les identifiants publics de l'app
    /// Firebase. S'il venait à manquer (fichier retiré, cible mal configurée),
    /// plutôt que de crasher au lancement (`FirebaseApp.configure()` lève une
    /// exception si le plist/les options sont absents), on dégrade proprement en
    /// « sans analytics ». Cf. `GoogleService-Info.sample.plist` + README.
    private static func configureFirebase() {
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let options = FirebaseOptions(contentsOfFile: path) else {
            AppLogger.data.error("[Firebase] GoogleService-Info.plist absent — analytics désactivé (voir README).")
            return
        }
        FirebaseApp.configure(options: options)
    }

    var body: some Scene {
        WindowGroup {
            SplashView()
                // Connectivité injectée à la racine : toute l'app lit le même
                // `NetworkMonitor` (source unique), y compris les écrans
                // présentés en sheet depuis `ContentView`.
                .environment(NetworkMonitor.shared)
        }
    }
}
