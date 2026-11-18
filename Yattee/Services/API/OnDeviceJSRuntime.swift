//
//  OnDeviceJSRuntime.swift
//  Yattee
//
//  Hidden WKWebView that runs the bundled YouTube.js (ondevice.js, built from ondevice-js/)
//  and bridges its network requests to URLSession.
//

#if canImport(WebKit)
import Foundation
import WebKit

@MainActor
final class OnDeviceJSRuntime: NSObject {
    static let shared = OnDeviceJSRuntime()

    /// Kept for the app's lifetime so YouTube.js keeps its session and player script cached.
    private var webViewTask: Task<WKWebView, Error>?
    private var loadContinuation: CheckedContinuation<Void, Error>?

    func search(query: String, page: Int) async throws -> Data {
        try await call("return await YT.search(query, page)", ["query": query, "page": page])
    }

    func video(id: String) async throws -> Data {
        try await call("return await YT.video(id)", ["id": id])
    }

    /// Calls `YT.<function>(...arguments)`; the dictionary keys become JS parameter names, in sorted order.
    func invoke(_ function: String, _ arguments: [String: any Sendable]) async throws -> Data {
        let names = arguments.keys.sorted()
        return try await call("return await YT.\(function)(\(names.joined(separator: ", ")))", arguments.mapValues { $0 as Any })
    }

    // MARK: - Private

    private func call(_ body: String, _ arguments: [String: Any], retried: Bool = false) async throws -> Data {
        let webView = try await loadedWebView()
        attachToWindow(webView)
        do {
            let result = try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
            guard let json = result as? String else { throw APIError.decodingError("On-device source returned no data") }
            return Data(json.utf8)
        } catch let error as APIError {
            throw error
        } catch {
            // WKError carries the JS exception message in userInfo.
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            // iOS kills the web content process in the background; the page comes back without YT. Start over once.
            if !retried, message.contains("YT") || (error as? WKError)?.code == .webContentProcessTerminated {
                discardWebView()
                return try await call(body, arguments, retried: true)
            }
            throw APIError.serverError(message)
        }
    }

    private func discardWebView() {
        let task = webViewTask
        webViewTask = nil
        Task { (try? await task?.value)?.removeFromSuperview() }
    }

    private func loadedWebView() async throws -> WKWebView {
        if let webViewTask { return try await webViewTask.value }
        let task = Task { try await makeWebView() }
        webViewTask = task
        do {
            return try await task.value
        } catch {
            webViewTask = nil
            throw error
        }
    }

    private func makeWebView() async throws -> WKWebView {
        guard let url = Bundle.main.url(forResource: "ondevice", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw APIError.unknown("ondevice.js is missing from the app bundle")
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "ytFetch")
        config.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        webView.navigationDelegate = self
        #if DEBUG
        webView.isInspectable = true
        #endif
        #if os(iOS)
        webView.alpha = 0
        webView.isUserInteractionEnabled = false
        #endif
        attachToWindow(webView)
        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            webView.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: URL(string: "https://www.youtube.com/"))
            // A suspended web view never finishes loading; fail instead of spinning forever.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(15))
                self?.finishLoading(APIError.unknown("On-device source took too long to start"))
            }
        }
        return webView
    }

    /// iOS suspends the web content process of a web view that is not in a window,
    /// and there may be no key window yet when the web view is created.
    private func attachToWindow(_ webView: WKWebView) {
        #if os(iOS)
        guard webView.window == nil else { return }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        (windows.first(where: \.isKeyWindow) ?? windows.first)?.addSubview(webView)
        #endif
    }

    private func finishLoading(_ error: Error?) {
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}

// MARK: - Page load

extension OnDeviceJSRuntime: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoading(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishLoading(APIError.unknown("On-device source stopped"))
        discardWebView()
    }
}

// MARK: - fetch bridge

extension OnDeviceJSRuntime: WKScriptMessageHandlerWithReply {
    /// Performs one `fetch` for YouTube.js. Body in and out is base64 so binary payloads survive the bridge.
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any],
              let urlString = body["url"] as? String,
              let url = URL(string: urlString) else {
            return (nil, "Invalid fetch request")
        }
        var request = URLRequest(url: url)
        request.httpMethod = body["method"] as? String ?? "GET"
        for (field, value) in body["headers"] as? [String: String] ?? [:] {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let encoded = body["body"] as? String {
            request.httpBody = Data(base64Encoded: encoded)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            for case let (field as String, value as String) in http?.allHeaderFields ?? [:] {
                // URLSession already decoded the body, so these no longer describe it.
                if ["content-encoding", "content-length"].contains(field.lowercased()) { continue }
                headers[field] = value
            }
            return (["status": http?.statusCode ?? 200, "headers": headers, "body": data.base64EncodedString()], nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }
}
#endif
