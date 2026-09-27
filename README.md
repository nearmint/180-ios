# 180-ios

![iOS 17+](https://img.shields.io/badge/iOS-17%2B-000000?logo=apple) ![Swift 5](https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white) ![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-0D96F6) [![License: MIT](https://img.shields.io/badge/License-MIT-green)](LICENSE)

Native iOS app of [180°C](https://www.180c.fr), an independent French food magazine. Subscribers browse the recipe library, keep favorites offline and receive new recipes by push notification. Content and accounts come from the 180°C WordPress site through its REST API.

## Highlights

- **Recipe library**: editorial home, search, and filters by course, season and publication.
- **Offline favorites**: saved recipes and their images stay readable without a network.
- **Account**: JWT sign-in against WordPress; subscriptions are managed on the website, not in the app.
- **Push notifications**: OneSignal with recipe deep links and in-app messages.
- **Privacy**: Umami and Firebase Analytics without cross-app tracking; privacy manifest included.
- **Accessibility**: VoiceOver labels and Reduce Motion support.

## Stack

| Layer | Technology |
|---|---|
| Platform | iOS 17+, iPhone and iPad |
| UI | SwiftUI, async/await |
| Backend | WordPress REST API (`wp/v2`, `180c/v1`), Simple JWT Login |
| Dependencies | Swift Package Manager: OneSignal, Firebase Analytics |
| Tests | Swift Testing |
| CI/CD | Xcode Cloud |

## Getting started

Requirements: Xcode 16+, an Apple Developer account for device builds.

```bash
git clone https://github.com/nearmint/180-ios.git
cd 180-ios
open 180.xcodeproj
```

Two schemes are available:

- `180-Local`: Debug build against a local WordPress install (`Config/Local.xcconfig`).
- `180`: Release build against production (`Config/Release.xcconfig`).

All URLs are resolved in `180/APIConfig.swift`. Run the tests with **⌘U**.

### Firebase configuration

`180/GoogleService-Info.plist` is not versioned. Before building:

- **With access to the Firebase project**: download the real file from the Firebase console (Project settings → iOS app `fr.thermostat6.app180`) and drop it into `180/`.
- **Without access**: copy `GoogleService-Info.sample.plist` to `180/GoogleService-Info.plist`. The app runs; Firebase Analytics simply stays disabled.

The account screen's contact addresses default to the public ones in the xcconfig files. To override them locally, create the untracked `Config/Private.xcconfig` with `CONTACT_EDITORIAL_EMAIL` / `CONTACT_SUPPORT_EMAIL`.

## Development

- Network calls use async/await only; no URL is hard-coded outside `APIConfig`.
- Versions (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`) are set at project level, never per target.
- Recipe taxonomies are resolved by slug at runtime (`RecipeTaxonomyResolver`), never by ID.
- Commits follow [Conventional Commits](https://www.conventionalcommits.org/); `main` is merged with `--no-ff` only.

## Deployment

Xcode Cloud runs two workflows:

- **CI**: builds every `feat/*`, `fix/*` and `chore/*` branch.
- **Release**: archives every push to `main` and uploads it to TestFlight.

Xcode Cloud runs `ci_scripts/ci_post_clone.sh` after cloning: it rebuilds `180/GoogleService-Info.plist` from the secret environment variable `GOOGLE_SERVICE_INFO_PLIST_BASE64` (and, if set, writes `Config/Private.xcconfig` from `CONTACT_EDITORIAL_EMAIL` / `CONTACT_SUPPORT_EMAIL`). Both workflows must declare that variable.

App Store submission stays manual in App Store Connect.

## Project layout

```
180/            App sources: views, services, models, assets
180Tests/       Unit tests (Swift Testing)
OneSignalNotificationServiceExtension/   Rich push extension
Config/         xcconfig files and Info.plist per environment
fastlane/       App Store metadata and screenshots
ci_scripts/     Xcode Cloud hooks
docs/           Feature notes
```

Further reading: [`CLAUDE.md`](CLAUDE.md) for architecture rules, [`docs/`](docs) for feature notes.

## License

[MIT](LICENSE)
