import XCTest
import AppKit
@testable import ThumbnailCore

final class ThumbnailCoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func shortcut(_ value: Any, format: PropertyListSerialization.PropertyListFormat = .xml,
                          name: String = "Example.webloc") throws -> URL {
        let path = directory.appendingPathComponent(name)
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: format, options: 0)
        try data.write(to: path)
        return path
    }

    func testReadsXMLAndBinaryAndPreservesFragments() throws {
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            let file = try shortcut(["URL": "https://example.com/collection#map.html"], format: format)
            let document = try WeblocDocument(fileURL: file)
            XCTAssertEqual(document.websiteURL.absoluteString, "https://example.com/collection#map.html")
        }
    }

    func testRejectsNonWebURLsAndMalformedFiles() throws {
        for raw in ["file:///etc/hosts", "javascript:alert(1)", "ftp://example.com", "https:///", "https://user:password@example.com"] {
            let file = try shortcut(["URL": raw])
            XCTAssertThrowsError(try WeblocDocument(fileURL: file), raw)
        }
        XCTAssertThrowsError(try WeblocDocument(fileURL: shortcut(["Other": "https://example.com"])))
        XCTAssertThrowsError(try WeblocDocument(fileURL: shortcut(["URL": 123])))
        XCTAssertThrowsError(try WeblocDocument(fileURL: shortcut(["URL": "https://example.com"], name: "Example.txt")))
        let invalid = directory.appendingPathComponent("broken.webloc")
        try Data("not a property list".utf8).write(to: invalid)
        XCTAssertThrowsError(try WeblocDocument(fileURL: invalid))
    }

    func testCacheSeparatesFragmentsAndExpires() throws {
        let cache = ThumbnailCache(directory: directory, lifetime: 60)
        let first = URL(string: "https://example.com/#first")!
        let second = URL(string: "https://example.com/#second")!
        let bytes = Data([1, 2, 3])
        try cache.write(bytes, for: first)
        XCTAssertEqual(cache.read(for: first), bytes)
        XCTAssertNil(cache.read(for: second))
        XCTAssertNil(cache.read(for: first, now: Date().addingTimeInterval(120)))
    }

    func testIconHasRealPixels() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1280, height: 960, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1280, height: 960))
        let icon = try IconRenderer.render(screenshot: XCTUnwrap(context.makeImage()), websiteURL: URL(string: "https://example.com")!)
        let data = try IconRenderer.pngData(icon)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(bitmap.pixelsWide, 512)
        XCTAssertEqual(bitmap.pixelsHigh, 512)
        let pixel = try XCTUnwrap(bitmap.colorAt(x: 256, y: 200)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(pixel.redComponent, pixel.greenComponent + 0.5)
        XCTAssertGreaterThan(pixel.alphaComponent, 0.99)
    }
}
