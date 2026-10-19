import AppKit
import WebKit
import ThumbnailCore

@MainActor
final class PageCapture: NSObject, WKNavigationDelegate {
    private let dataStore: WKWebsiteDataStore
    private static let readinessWorld = WKContentWorld.world(name: "WeblocThumbnailReadiness")
    private var webView: WKWebView?
    private var renderWindow: NSWindow?
    private var continuation: CheckedContinuation<RasterIcon, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var captureID: UUID?
    private var pageGeneration = UUID()

    init(dataStore: WKWebsiteDataStore) { self.dataStore = dataStore; super.init() }

    func capture(_ url: URL, timeout: TimeInterval = 25) async throws -> RasterIcon {
        try Task.checkCancellation()
        guard continuation == nil else { throw ThumbnailError.message("A page is already being captured.") }
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { pending in
                continuation = pending
                captureID = id
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = dataStore
                configuration.userContentController.addUserScript(WKUserScript(source: Self.readinessObserver,
                    injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.readinessWorld))
                configuration.mediaTypesRequiringUserActionForPlayback = .all
                configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
                let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 960), configuration: configuration)
                view.navigationDelegate = self
                view.underPageBackgroundColor = .white
                webView = view
                // Keep WebKit attached to an ordered rendering window. Detached/hidden
                // views can produce blank captures. The window never takes focus.
                let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.ignoresMouseEvents = true
                window.isExcludedFromWindowsMenu = true
                window.contentView = view
                window.setFrameOrigin(NSPoint(x: -16000, y: 0))
                window.orderBack(nil)
                renderWindow = window
                timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                    catch { return }
                    self?.finish(.failure(ThumbnailError.message("The website didn’t finish within \(Int(timeout)) seconds.")), id: id)
                }
                view.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: timeout))
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.finish(.failure(CancellationError()), id: id) }
        })
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        settleTask?.cancel()
        settleTask = nil
        captureWhenReady(webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if settleTask == nil { captureWhenReady(webView) }
    }

    private func captureWhenReady(_ webView: WKWebView) {
        guard let id = captureID else { return }
        let generation = UUID()
        pageGeneration = generation
        settleTask?.cancel()
        settleTask = Task { [weak self, weak webView] in
            do {
                guard let webView else { return }
                while true {
                    try Task.checkCancellation()
                    guard self?.captureID == id, self?.pageGeneration == generation else { return }
                    let ready = try? await webView.callAsyncJavaScript(Self.readinessCheck,
                        arguments: [:], in: nil, contentWorld: Self.readinessWorld)
                    if ready as? Bool == true { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try Task.checkCancellation()
                guard self?.captureID == id, self?.pageGeneration == generation else { return }
                let configuration = WKSnapshotConfiguration()
                configuration.rect = webView.bounds
                // The final icon is 512 px. Avoid rendering a 1280-point (often
                // 2560-pixel Retina) snapshot only to immediately downsample it.
                configuration.snapshotWidth = 512
                webView.takeSnapshot(with: configuration) { [weak self] image, error in
                    guard let self, self.captureID == id, self.pageGeneration == generation else { return }
                    if let error { self.finish(.failure(error), id: id) }
                    else if let bitmap = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        self.finish(.success(RasterIcon(image: bitmap)), id: id)
                    }
                    else { self.finish(.failure(ThumbnailError.message("WebKit returned no screenshot.")), id: id) }
                }
            } catch { /* Cancellation is completed by the capture cancellation handler. */ }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        fail(ThumbnailError.message("The website’s rendering process stopped. Try again."))
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let scheme = action.request.url?.scheme?.lowercased(),
              ["http", "https", "about"].contains(scheme), action.targetFrame != nil else {
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let http = response.response as? HTTPURLResponse, http.statusCode >= 400, response.isForMainFrame {
            fail(ThumbnailError.message("The website returned HTTP \(http.statusCode)."))
            return .cancel
        } else if !response.canShowMIMEType {
            if response.isForMainFrame {
                fail(ThumbnailError.message("The link points to a download rather than a viewable page."))
            }
            return .cancel
        }
        return .allow
    }

    private func fail(_ error: Error) {
        if (error as NSError).domain == NSURLErrorDomain, (error as NSError).code == NSURLErrorCancelled { return }
        guard let id = captureID else { return }
        finish(.failure(error), id: id)
    }

    private func finish(_ result: Result<RasterIcon, Error>, id: UUID) {
        guard captureID == id, let pending = continuation else { return }
        continuation = nil
        captureID = nil
        timeoutTask?.cancel(); timeoutTask = nil
        settleTask?.cancel(); settleTask = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        renderWindow?.orderOut(nil)
        renderWindow?.contentView = nil
        renderWindow?.close()
        renderWindow = nil
        webView = nil
        pending.resume(with: result)
    }

    // Isolated-world scripts cannot collide with the site's JavaScript. Start
    // after DOM parsing, not window.load: slow analytics and offscreen images
    // should not hold up a thumbnail that is already visibly ready.
    private static let readinessObserver = """
        const state = { start: performance.now(), changed: performance.now() };
        globalThis.thumbnailReadiness = state;
        new MutationObserver(() => { state.changed = performance.now(); })
          .observe(document.documentElement, {subtree: true, childList: true, attributes: true, characterData: true});
        """

    private static let readinessCheck = """
        const state = globalThis.thumbnailReadiness;
        if (!state || document.readyState === 'loading') return false;
        const elapsed = performance.now() - state.start;
        const visible = element => {
          const box = element.getBoundingClientRect();
          return box.width > 0 && box.height > 0 && box.top < innerHeight && box.bottom > 0 && box.left < innerWidth && box.right > 0;
        };
        const images = Array.from(document.images).filter(image => {
          if (visible(image)) return true;
          if (image.complete || image.getClientRects().length === 0) return false;
          // Images without width/height metadata can have zero height until
          // loaded. Their in-viewport anchors still need to be awaited.
          const box = image.getBoundingClientRect();
          return box.top < innerHeight && box.bottom >= 0 && box.left < innerWidth && box.right >= 0
            && getComputedStyle(image).visibility !== 'hidden';
        });
        const text = (document.body?.innerText || '').trim();
        const loading = text.length < 80 && /^(loading|please wait|just a moment)[.\\s…!]*$/i.test(text);
        const styles = Array.from(document.querySelectorAll('link[rel~="stylesheet"]'));
        const stylesReady = styles.every(link => link.disabled || !matchMedia(link.media || 'all').matches || link.sheet);
        // A short DOM-settling budget must not turn a slow stylesheet or hero
        // image into a blank thumbnail. Critical resources retain the overall
        // page deadline; offscreen images are deliberately excluded.
        if (!stylesReady || document.fonts.status !== 'loaded' || !images.every(image => image.complete)) return false;
        if (elapsed >= 2500) return true;
        const content = !loading && (text.length > 0 || images.some(image => image.complete && image.naturalWidth > 0)
          || Array.from(document.querySelectorAll('canvas,svg,video')).some(visible));
        const animating = document.getAnimations().some(animation => {
          const target = animation.effect?.target;
          const timing = animation.effect?.getComputedTiming();
          return animation.playState === 'running' && Number.isFinite(timing?.endTime)
            && target instanceof Element && visible(target);
        });
        return elapsed >= 200 && performance.now() - state.changed >= 180 && content && !animating;
        """
}
