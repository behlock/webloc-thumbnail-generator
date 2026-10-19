import XCTest
import CoreGraphics
@testable import ThumbnailCore

final class BackgroundWorkTests: XCTestCase {
    @MainActor func testBlockingWorkLeavesMainActorAvailable() async throws {
        let queue = BackgroundQueue(label: "test.background-work")
        let task = Task {
            try await queue.perform { _ in
                let main = Thread.isMainThread
                Thread.sleep(forTimeInterval: 0.15)
                return main
            }
        }
        var ticks = 0
        let pulse = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 10_000_000) } catch { break }
                ticks += 1
            }
        }
        let usedMainThread = try await task.value
        pulse.cancel()
        XCTAssertFalse(usedMainThread)
        XCTAssertGreaterThan(ticks, 3, "The main actor should keep handling events while synchronous work runs.")
    }

    func testCancellingQueuedWorkPreventsItsSideEffects() async throws {
        let queue = BackgroundQueue(label: "test.cancelled-work")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let first = Task {
            try await queue.perform { _ in
                continuation.yield(())
                Thread.sleep(forTimeInterval: 0.15)
                return true
            }
        }
        for await _ in started { break }
        let second = Task {
            try await queue.perform { _ in
                try Data("must not be written".utf8).write(to: file)
                return true
            }
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        second.cancel()
        do { _ = try await second.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        _ = try await first.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        continuation.finish()
    }

    func testWorkerCacheAndFileRevalidation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Example.webloc")
        let url = URL(string: "https://example.com/#map")!
        try PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0).write(to: file)
        let worker = IconWorker(cacheDirectory: directory.appendingPathComponent("cache"))
        let loaded = try await worker.load(file, refresh: false)
        XCTAssertNil(loaded.icon)
        let context = CGContext(data: nil, width: 512, height: 384, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 512, height: 384))
        let icon = try await worker.prepare(screenshot: RasterIcon(image: context.makeImage()!), websiteURL: url)
        let reused = try await worker.load(file, refresh: false)
        XCTAssertNotNil(reused.icon)
        // Even a refresh reuses freshly generated pixels within this batch.
        let refreshed = try await worker.load(file, refresh: true)
        XCTAssertNotNil(refreshed.icon)
        try PropertyListSerialization.data(fromPropertyList: ["URL": "https://different.example"], format: .xml, options: 0).write(to: file)
        do { try await worker.apply(icon, to: loaded.document); XCTFail("Changed shortcut must not be overwritten") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
    }
}
