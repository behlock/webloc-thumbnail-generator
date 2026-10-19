import Foundation
import CryptoKit

public struct ThumbnailCache {
    private let directory: URL
    private let lifetime: TimeInterval
    // Change this when the viewport or icon design changes.
    private static let version = "desktop-1280x960-icon-v1"

    public init(directory: URL, lifetime: TimeInterval = 7 * 24 * 60 * 60) {
        self.directory = directory
        self.lifetime = lifetime
    }

    private func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data((Self.version + "\n" + url.absoluteString).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".png")
    }

    public func read(for url: URL, now: Date = Date()) -> Data? {
        let path = fileURL(for: url)
        guard let values = try? path.resourceValues(forKeys: [.contentModificationDateKey]),
              let modified = values.contentModificationDate, now.timeIntervalSince(modified) <= lifetime else { return nil }
        return try? Data(contentsOf: path)
    }

    public func write(_ png: Data, for url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: fileURL(for: url), options: .atomic)
    }

    public func prune() {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        let entries = files.filter { $0.pathExtension == "png" }.compactMap { url -> (URL, Date, Int)? in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        var bytes = 0
        for (index, entry) in entries.enumerated() {
            bytes += entry.2
            if index >= 200 || bytes > 100 * 1024 * 1024 { try? manager.removeItem(at: entry.0) }
        }
    }
}
