import AppKit
import ImageIO

/// CGImage is immutable; no mutable NSImage crosses the worker/UI boundary.
public struct RasterIcon: @unchecked Sendable {
    public let image: CGImage
    public init(image: CGImage) { self.image = image }
}

public struct LoadedWebsite: Sendable {
    public let document: WeblocDocument
    public let icon: RasterIcon?
}

public final class IconWorker: @unchecked Sendable {
    private final class CachedIcon: NSObject {
        let icon: RasterIcon
        init(_ icon: RasterIcon) { self.icon = icon }
    }
    private let background = BackgroundQueue(label: "webloc-thumbnails.image-and-file-work")
    private let cache: ThumbnailCache
    // These objects are accessed only from the background queue.
    private let images = NSCache<NSURL, CachedIcon>()

    public init(cacheDirectory: URL) {
        cache = ThumbnailCache(directory: cacheDirectory)
        images.countLimit = 64
        images.totalCostLimit = 32 * 1024 * 1024
    }

    public func load(_ file: URL, refresh: Bool) async throws -> LoadedWebsite {
        try await background.perform { [self] cancellation in
            let document = try WeblocDocument(fileURL: file)
            try cancellation.check()
            if let cached = images.object(forKey: document.websiteURL as NSURL) {
                return LoadedWebsite(document: document, icon: cached.icon)
            }
            if !refresh, let data = cache.read(for: document.websiteURL),
               let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
               let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: 512
               ] as CFDictionary) {
                try cancellation.check()
                let icon = RasterIcon(image: image)
                remember(icon, for: document.websiteURL)
                return LoadedWebsite(document: document, icon: icon)
            }
            return LoadedWebsite(document: document, icon: nil)
        }
    }

    public func prepare(screenshot: RasterIcon, websiteURL: URL) async throws -> RasterIcon {
        try await background.perform { [self] cancellation in
            let icon = RasterIcon(image: try IconRenderer.render(screenshot: screenshot.image, websiteURL: websiteURL))
            try cancellation.check()
            remember(icon, for: websiteURL)
            // Encode directly to PNG once; no NSImage -> TIFF -> bitmap round trip.
            // Cache maintenance is deferred until the batch finishes.
            if let png = try? IconRenderer.pngData(icon.image) {
                try cancellation.check()
                try? cache.write(png, for: websiteURL)
            }
            return icon
        }
    }

    public func apply(_ icon: RasterIcon, to document: WeblocDocument) async throws {
        try await background.perform { cancellation in
            // NSWorkspace documents setIcon as thread-safe, but requiring serial
            // calls. This worker's queue also serializes the file revalidation.
            guard try WeblocDocument(fileURL: document.fileURL) == document else {
                throw ThumbnailError.message("The shortcut changed during capture. Run the action again.")
            }
            let image = NSImage(cgImage: icon.image, size: NSSize(width: 512, height: 512))
            try cancellation.check()
            guard NSWorkspace.shared.setIcon(image, forFile: document.fileURL.path, options: []) else {
                throw ThumbnailError.message("Couldn’t set the icon. Check that the file is writable.")
            }
            // Once setIcon succeeds, report success even if cancellation raced
            // with the OS call; the next file will observe cancellation.
        }
    }

    public func finish(report: RunReport, at url: URL) async throws {
        // Batch cleanup must still run after cancellation. It is called outside
        // the cancelled task group, before the app exits.
        try await Task.detached(priority: .utility) { [self] in
            try await background.perform { [self] _ in
                cache.prune()
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try report.data().write(to: url, options: .atomic)
            }
        }.value
    }

    private func remember(_ icon: RasterIcon, for url: URL) {
        images.setObject(CachedIcon(icon), forKey: url as NSURL, cost: icon.image.bytesPerRow * icon.image.height)
    }
}
