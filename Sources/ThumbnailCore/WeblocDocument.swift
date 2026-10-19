import Foundation

public enum ThumbnailError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

public struct WeblocDocument: Equatable, Sendable {
    public let fileURL: URL
    public let websiteURL: URL

    public init(fileURL: URL) throws {
        guard fileURL.isFileURL, fileURL.pathExtension.lowercased() == "webloc" else {
            throw ThumbnailError.message("Choose a .webloc file.")
        }
        // URL resource metadata can be stale after an edit or atomic replacement.
        let values = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard values[.type] as? FileAttributeType == .typeRegular,
              (values[.size] as? Int ?? Int.max) <= 1_048_576 else {
            throw ThumbnailError.message("This isn’t a readable .webloc file smaller than 1 MB.")
        }
        let data = try Data(contentsOf: fileURL)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any], let value = dictionary["URL"] as? String,
              let websiteURL = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(websiteURL.scheme?.lowercased() ?? ""),
              let host = websiteURL.host, !host.isEmpty,
              websiteURL.user == nil, websiteURL.password == nil else {
            throw ThumbnailError.message("The file must contain an HTTP or HTTPS website URL without embedded credentials.")
        }
        self.fileURL = fileURL.standardizedFileURL
        self.websiteURL = websiteURL
    }
}
