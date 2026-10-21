import AppKit
import Foundation
import Network
import Testing
@testable import MyAgent

struct NativeToolsTests {
    @Test
    @MainActor
    func testHTTPURLValidationAndOriginNormalization() async throws {
        for address in ["https://example.com/path", "http://127.0.0.1:4381/", "http://localhost:8080/"] {
            _ = try NativeBrowser.validatedURL(address)
        }
        for address in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,hi", "ftp://example.com/",
                        "https://user:password@example.com", "https://user@example.com", "example.com", "https://"] {
            expectThrows { _ = try NativeBrowser.validatedURL(address) }
        }
        #expect(NativeBrowser.origin(for: try NativeBrowser.validatedURL("HTTPS://Example.COM:443/a")) == "https://example.com")
        #expect(NativeBrowser.origin(for: try NativeBrowser.validatedURL("http://example.com:80/a")) == "http://example.com")
        #expect(NativeBrowser.origin(for: try NativeBrowser.validatedURL("http://localhost:4381/a")) == "http://localhost:4381")
        #expect(NativeBrowser.origin(for: try NativeBrowser.validatedURL("http://[::1]:4381/a")) == "http://[::1]:4381")
    }

    @Test
    @MainActor
    func testSensitiveMetadataAndOrdinaryFields() async throws {
        for label in ["AXSecureTextField", "Account password", "one-time-code", "OTP", "信用卡", "验证码", "CVV", "card number", "Payment"] {
            #expect(NativeDesktop.isSensitiveMetadata(label))
        }
        for label in ["AXTextField Name", "Document title", "Search query", "Project description"] {
            #expect(!NativeDesktop.isSensitiveMetadata(label))
        }
    }

    @Test
    @MainActor
    func testScreenshotDestinationStaysInWorkspaceAndRejectsSymlink() async throws {
        let manager = FileManager.default
        let root = temporaryFolder()
        let outside = temporaryFolder()
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root); try? manager.removeItem(at: outside) }
        let destination = try NativeBrowser.screenshotURL(workspace: root.path)
        #expect(destination.deletingLastPathComponent().path == root.appendingPathComponent("deliverables").path)
        #expect(destination.pathExtension == "png")
        #expect(!manager.fileExists(atPath: destination.path))
        try manager.removeItem(at: root.appendingPathComponent("deliverables"))
        try manager.createSymbolicLink(at: root.appendingPathComponent("deliverables"), withDestinationURL: outside)
        expectThrows { _ = try NativeBrowser.screenshotURL(workspace: root.path) }
        expectThrows { _ = try NativeBrowser.screenshotURL(workspace: root.appendingPathComponent("missing").path) }
    }

    @Test
    @MainActor
    func testIndependentBrowserWithLocalFixture() async throws {
        // This process's private WebKit view is the only UI under test. No user
        // browser or other application is inspected, activated, or controlled.
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = temporaryFolder()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try BrowserFixture()
        let address = try await fixture.start()
        defer { fixture.stop() }
        let browser = NativeBrowser()
        defer { browser.stop() }

        let opened = try await browser.perform(["action": "open", "url": address], workspace: root.path)
        #expect(opened["title"] as? String == "MyAgent Local Fixture")
        let body = try #require(opened["bodyText"] as? String)
        #expect(body.contains("Independent browser fixture"))
        #expect(!body.contains("do-not-leak-secret"))
        #expect(!body.contains("123456"))
        let imagePath = try #require(opened["screenshotPath"] as? String)
        let imageData = try Data(contentsOf: URL(fileURLWithPath: imagePath))
        #expect(Array(imageData.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
        let bitmap = try #require(NSBitmapImageRep(data: imageData))
        #expect(bitmap.pixelsWide > 500)
        #expect(bitmap.pixelsHigh > 300)
        #expect(browser.snapshot != nil)
        // A real rendered fixture contains both its blue header and white page;
        // a wholly blank offscreen snapshot does not satisfy this test.
        let colors = stride(from: 20, to: bitmap.pixelsHigh, by: 60).flatMap { y in
            stride(from: 20, to: bitmap.pixelsWide, by: 60).compactMap { x in
                bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
            }
        }
        #expect(colors.contains { $0.blueComponent > 0.5 && $0.redComponent < 0.4 })
        #expect(colors.contains { $0.redComponent > 0.9 && $0.greenComponent > 0.9 })

        var elements = try #require(opened["elements"] as? [[String: Any]])
        #expect(elements.filter { $0["sensitive"] as? Bool == true }.count >= 3)
        let nameSelector = try selector(label: "Name", in: elements)
        let filled = try await browser.perform(["action": "fill", "selector": nameSelector, "text": "Ada"], workspace: root.path)
        elements = try #require(filled["elements"] as? [[String: Any]])
        #expect(try selector(label: "Name", in: elements) == nameSelector)
        let safeButton = try selector(label: "Reveal result", in: elements)
        let clicked = try await browser.perform(["action": "click", "selector": safeButton], workspace: root.path)
        #expect((clicked["bodyText"] as? String ?? "").contains("Hello Ada"))

        elements = try #require(clicked["elements"] as? [[String: Any]])
        let external = try selector(label: "External", in: elements)
        await expectFailure { try await browser.perform(["action": "click", "selector": external], workspace: root.path) }
        let submit = try selector(label: "Submit", in: elements)
        await expectFailure { try await browser.perform(["action": "click", "selector": submit], workspace: root.path) }
        await expectFailure { try await browser.perform(["action": "fill", "selector": "#name", "text": "injected"], workspace: root.path) }
        let sameOrigin = try selector(label: "Continue", in: elements)
        let next = try await browser.perform(["action": "click", "selector": sameOrigin], workspace: root.path)
        #expect(next["title"] as? String == "Next Local Page")
        await expectFailure { try await browser.perform(["action": "fill", "selector": nameSelector, "text": "stale"], workspace: root.path) }
        #expect(fixture.submissionCount == 0)

        // A blocked response and cancellation must not leave a continuation
        // hanging or resume it a second time when WebKit reports its failure.
        await expectFailure { try await browser.perform(["action": "open", "url": address + "download"], workspace: root.path) }
        let pending = Task { try await browser.perform(["action": "open", "url": address + "slow"], workspace: root.path) }
        try await Task.sleep(nanoseconds: 150_000_000)
        pending.cancel()
        do { _ = try await pending.value; Issue.record("Cancelled browser load reported success") }
        catch is CancellationError { }
        catch { Issue.record("Unexpected cancellation error: \(error)") }
        let reopened = try await browser.perform(["action": "open", "url": address], workspace: root.path)
        #expect(reopened["title"] as? String == "MyAgent Local Fixture")
    }

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("myagent-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func selector(label: String, in elements: [[String: Any]]) throws -> String {
        let element = try #require(elements.first { $0["label"] as? String == label })
        return try #require(element["selector"] as? String)
    }

    @MainActor
    private func expectThrows(_ action: () throws -> Void) {
        do { try action(); Issue.record("Expected operation to throw") } catch { }
    }

    @MainActor
    private func expectFailure(_ action: () async throws -> [String: Any]) async {
        do { _ = try await action(); Issue.record("Expected operation to be refused") } catch { }
    }

}

private final class BrowserFixture {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "myagent.local-browser-fixture")
    private let lock = NSLock()
    private var submissions = 0
    private var connections: [NWConnection] = []
    private var didResumeStart = false // Accessed only on the fixture's serial queue.
    var submissionCount: Int { lock.lock(); defer { lock.unlock() }; return submissions }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.didResumeStart else { return }
                switch state {
                case .ready:
                    self.didResumeStart = true
                    continuation.resume(returning: "http://127.0.0.1:\(self.listener.port!.rawValue)/")
                case .failed(let error): self.didResumeStart = true; continuation.resume(throwing: error)
                case .cancelled: self.didResumeStart = true; continuation.resume(throwing: CancellationError())
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        queue.async { [self] in connections.forEach { $0.cancel() }; connections.removeAll() }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            if request.hasPrefix("POST ") { self.lock.lock(); self.submissions += 1; self.lock.unlock() }
            if path == "/slow" { return }
            let html: String
            var extra = ""
            if path == "/next" { html = "<html><head><title>Next Local Page</title></head><body>Reached next page.</body></html>" }
            else if path == "/download" { html = "download denied"; extra = "Content-Disposition: attachment; filename=fixture.txt\r\n" }
            else { html = Self.page }
            let body = Data(html.utf8)
            let header = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\(extra)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: header + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private static let page = #"""
    <!doctype html><html><head><title>MyAgent Local Fixture</title>
    <style>body{margin:0;background:white;color:#171717;font:20px -apple-system}h1{background:#145cde;color:white;margin:0;padding:40px}main{padding:30px}label{display:block;margin:16px 0}button,a{margin:14px;padding:8px}input{font:20px -apple-system}</style></head>
    <body><h1>Independent browser fixture</h1><main>
    <label>Name<input id="name" type="text" value="Initial"></label>
    <label>Password<input type="password" value="do-not-leak-secret"></label>
    <label>验证码<input type="text" autocomplete="one-time-code" value="123456"></label>
    <label>银行卡<input type="text" value="4012888888881881"></label>
    <form method="post" action="/submitted"><button>Submit</button><button type="button" id="safe">Reveal result</button></form>
    <div id="result">Not clicked</div>
    <a href="/next">Continue</a><a href="https://example.com/">External</a><a href="/download" download>Download</a>
    <script>document.querySelector('#safe').addEventListener('click',()=>{document.querySelector('#result').innerText='Hello '+document.querySelector('#name').value;});</script>
    </main></body></html>
    """#
}
