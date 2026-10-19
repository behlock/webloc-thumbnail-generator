import Foundation

public struct FileResult: Encodable, Sendable {
    public enum Status: String, Encodable, Sendable { case success, failed, cancelled }
    public let file: String
    public let status: Status
    public let cached: Bool
    public let message: String?
    public init(file: URL, status: Status, cached: Bool = false, message: String? = nil) {
        self.file = file.path; self.status = status; self.cached = cached; self.message = message
    }
}

public struct RunReport: Encodable, Sendable {
    public let finishedAt: Date
    public let cancelled: Bool
    public let results: [FileResult]
    public var failures: [FileResult] { results.filter { $0.status == .failed } }
    public init(results: [FileResult], cancelled: Bool) {
        self.finishedAt = Date(); self.results = results; self.cancelled = cancelled
    }
    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
