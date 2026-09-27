import SwiftUI
import UIKit
import Combine
import ImageIO

struct CachedAsyncImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    /// Borne supérieure (en points) du plus grand côté rendu. Le téléchargement
    /// est downsamplé à `maxRenderWidth × scale` px — évite de décoder/garder en
    /// mémoire des originaux WP de plusieurs milliers de pixels.
    var maxRenderWidth: CGFloat = 600

    @ObservedObject private var cacheManager = ImageCacheManager.shared
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @State private var isLoading = true
    private let maxRetries = 2

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if isLoading {
                ZStack {
                    Rectangle().fill(Color(.systemGray5))
                    ProgressView()
                }
            } else {
                ZStack {
                    Rectangle().fill(Color(.systemGray5))
                    Image(systemName: "fork.knife")
                        .font(.title3)
                        .foregroundColor(.gray)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: image != nil)
        // La génération du cache fait partie de l'identité de la tâche : un flush
        // (pull-to-refresh) la fait évoluer → rechargement même à URL inchangée.
        .task(id: "\(url?.absoluteString ?? "")|\(cacheManager.generation)") {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let url = url else {
            isLoading = false
            return
        }

        let cacheKey = url.absoluteString
        // Cible de downsampling en pixels (côté max). Identique quelle que soit
        // la provenance des octets : réseau, cache disque ou store hors ligne
        // produisent donc **exactement** la même image.
        let maxPixelSize = maxRenderWidth * displayScale

        // 1. Cache mémoire (le plus rapide).
        if let cached = ImageCacheManager.shared.get(forKey: cacheKey) {
            self.image = cached
            self.isLoading = false
            return
        }

        // 2. Store hors ligne, AVANT le cache disque : ce dernier vit sous
        //    `Caches/`, que le système évince librement. Un visuel téléchargé
        //    explicitement par l'utilisateur doit primer sur une copie
        //    opportuniste qui peut avoir disparu.
        if let bytes = await OfflineStore.shared.imageData(for: url) {
            let decoded = await Task.detached(priority: .utility) {
                DownsampledImage(image: ImageCacheManager.downsample(bytes, maxPixelSize: maxPixelSize))
            }.value
            if let uiImage = decoded.image {
                ImageCacheManager.shared.cacheInMemory(uiImage, forKey: cacheKey)
                self.image = uiImage
                self.isLoading = false
                return
            }
        }

        // 3. Cache disque (persiste entre lancements) : évite un aller-retour
        //    réseau pour un visuel déjà téléchargé lors d'une session précédente.
        if let disk = await ImageCacheManager.shared.diskImage(forKey: cacheKey) {
            ImageCacheManager.shared.cacheInMemory(disk, forKey: cacheKey)
            self.image = disk
            self.isLoading = false
            return
        }

        // 4. Télécharger avec retry.
        isLoading = true

        for attempt in 0...maxRetries {
            do {
                let (data, response) = try await AppHTTP.session.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    if attempt == maxRetries { isLoading = false }
                    continue
                }

                // Décodage + redimensionnement hors du main thread (ImageIO).
                let downsampled = await Task.detached(priority: .utility) {
                    DownsampledImage(image: ImageCacheManager.downsample(data, maxPixelSize: maxPixelSize))
                }.value

                guard let uiImage = downsampled.image else {
                    if attempt == maxRetries { isLoading = false }
                    continue
                }

                ImageCacheManager.shared.set(uiImage, forKey: cacheKey)
                self.image = uiImage
                self.isLoading = false
                return
            } catch {
                if attempt < maxRetries {
                    try? await Task.sleep(nanoseconds: UInt64(500_000_000 * (attempt + 1)))
                }
            }
        }
        isLoading = false
    }
}

/// Transporte une `UIImage` (non-`Sendable`) hors d'une tâche détachée. L'image
/// est immuable après downsampling : le transfert est sûr.
private struct DownsampledImage: @unchecked Sendable {
    let image: UIImage?
}

@MainActor
final class ImageCacheManager: ObservableObject {
    static let shared = ImageCacheManager()

    /// Incrémentée à chaque flush : les vues `CachedAsyncImage` l'observent pour
    /// forcer un rechargement (pull-to-refresh) même à URL inchangée.
    @Published private(set) var generation = 0

    private let cache = NSCache<NSString, UIImage>()

    /// Répertoire de persistance disque des bitmaps downsamplés.
    private let diskDirectory: URL
    /// File d'E/S disque dédiée (hors main thread) partagée par lecture/écriture.
    private let ioQueue = DispatchQueue(label: "fr.thermostat6.app180.imagecache", qos: .utility)

    init() {
        cache.countLimit = 100
        cache.totalCostLimit = 50 * 1024 * 1024 // 50 MB

        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        diskDirectory = base.appendingPathComponent("image-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    func get(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    /// Enregistre en mémoire **et** sur disque (nouveau visuel téléchargé).
    func set(_ image: UIImage, forKey key: String) {
        cacheInMemory(image, forKey: key)
        writeToDisk(image, forKey: key)
    }

    /// Enregistre en mémoire uniquement (ex. visuel relu depuis le disque : nul
    /// besoin de le réécrire).
    func cacheInMemory(_ image: UIImage, forKey key: String) {
        // Coût ≈ taille du bitmap décodé : alimente `totalCostLimit` (50 Mo).
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    /// Nom de fichier disque sûr dérivé de la clé (URL du visuel).
    private nonisolated func diskURL(forKey key: String, in directory: URL) -> URL {
        let safe = Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return directory.appendingPathComponent(safe).appendingPathExtension("jpg")
    }

    private func writeToDisk(_ image: UIImage, forKey key: String) {
        let url = diskURL(forKey: key, in: diskDirectory)
        // JPEG 0.8 : les visuels recette sont opaques, la compression est un bon
        // compromis taille/qualité pour un cache.
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        ioQueue.async { try? data.write(to: url, options: .atomic) }
    }

    /// Relit un bitmap depuis le disque (décodage hors main thread), `nil` si
    /// absent. L'image immuable est transportée via `DownsampledImage`
    /// (`@unchecked Sendable`), comme le chemin de téléchargement.
    func diskImage(forKey key: String) async -> UIImage? {
        let url = diskURL(forKey: key, in: diskDirectory)
        let boxed: DownsampledImage = await withCheckedContinuation { continuation in
            ioQueue.async {
                let image = (try? Data(contentsOf: url)).flatMap { UIImage(data: $0) }
                continuation.resume(returning: DownsampledImage(image: image))
            }
        }
        return boxed.image
    }

    /// Décode **et** redimensionne une image via ImageIO, sans jamais matérialiser
    /// le bitmap pleine résolution. `nonisolated` : exécutable hors du main thread
    /// (appelé depuis une tâche détachée). Repli sur `UIImage(data:)` si l'API
    /// thumbnail échoue.
    nonisolated static func downsample(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return UIImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }

    /// Précharge un visuel (téléchargement + downsampling + mise en cache) s'il
    /// n'est pas déjà présent. Utilisé par le splash pour les images
    /// above-the-fold, afin qu'elles soient affichées d'emblée à l'entrée.
    func prefetch(_ url: URL, maxPixelSize: CGFloat) async {
        let key = url.absoluteString
        if get(forKey: key) != nil { return }
        // Déjà sur disque : on repeuple la mémoire pour un rendu instantané.
        if let disk = await diskImage(forKey: key) {
            cacheInMemory(disk, forKey: key)
            return
        }
        guard let (data, response) = try? await AppHTTP.session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return
        }
        let boxed = await Task.detached(priority: .utility) {
            DownsampledImage(image: ImageCacheManager.downsample(data, maxPixelSize: maxPixelSize))
        }.value
        guard let image = boxed.image else { return }
        set(image, forKey: key)
    }

    /// Vide le cache (mémoire + disque) et invalide les vues image (pull-to-refresh).
    func clear() {
        cache.removeAllObjects()
        let dir = diskDirectory
        ioQueue.async {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        generation += 1
    }
}
