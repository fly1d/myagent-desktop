import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import WebKit

/// A private browsing session owned by this application. Authorization belongs to
/// the caller; this object never displays a window or uses another browser's data.
@MainActor
final class NativeBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    private(set) var currentOrigin: String?
    private(set) var title = "独立浏览器尚未打开页面"
    private(set) var snapshot: NSImage?
    var onSnapshot: ((NSImage?, String) -> Void)?

    private let webView: WKWebView
    private let selectorPrefix = "myagent-" + UUID().uuidString.lowercased()
    private var generation = 0
    private var busy = false
    private var readURL: String?
    private var documentToken: String?
    private var clickableSelectors = Set<String>()
    private var editableSelectors = Set<String>()
    private var pendingCallbacks: [UUID: () -> Void] = [:]
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    private var expectedNavigation: WKNavigation?
    private var latestNavigation: WKNavigation?
    private var navigationTimer: Task<Void, Never>?
    private var navigationFailure: Error?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.submissionGuardScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.underPageBackgroundColor = .white
    }

    static func validatedURL(_ value: String) throws -> URL {
        guard let parts = URLComponents(string: value),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              let url = parts.url else {
            throw AppFailure.message("浏览器只接受不含用户名或密码的 HTTP / HTTPS 地址。")
        }
        return url
    }

    static func origin(for url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        let port = parts.port.flatMap { $0 == defaultPort ? nil : $0 }
        let normalizedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme)://\(normalizedHost)" + (port.map { ":\($0)" } ?? "")
    }

    func perform(_ arguments: [String: Any], workspace: String) async throws -> [String: Any] {
        guard !busy else { throw AppFailure.message("独立浏览器正在执行另一个操作。") }
        guard let action = arguments["action"] as? String else {
            throw AppFailure.message("浏览器操作缺少 action。")
        }
        busy = true
        defer { busy = false }
        let token = generation
        return try await withTaskCancellationHandler(operation: {
            try self.checkGeneration(token)
            switch action {
            case "open":
                guard let address = arguments["url"] as? String else {
                    throw AppFailure.message("open 需要 url。")
                }
                let url = try Self.validatedURL(address)
                self.webView.stopLoading()
                self.currentOrigin = Self.origin(for: url)
                self.clearObservation()
                self.navigationFailure = nil
                self.snapshot = nil
                self.onSnapshot?(nil, "正在打开独立浏览器页面")
                try await self.load(url, token: token)
                var result = try await self.read(token: token)
                let capture = try await self.capture(workspace: workspace, token: token)
                result["screenshotPath"] = capture["path"]
                return result
            case "read":
                try self.requirePage()
                return try await self.read(token: token)
            case "click", "fill":
                try self.requirePage()
                guard let selector = arguments["selector"] as? String,
                      self.clickableSelectors.contains(selector),
                      self.readURL == self.webView.url?.absoluteString,
                      let documentToken = self.documentToken else {
                    throw AppFailure.message("只允许操作最近一次 read 返回的当前页面元素；请先重新读取页面。")
                }
                if action == "fill", !self.editableSelectors.contains(selector) {
                    throw AppFailure.message("此元素不是允许填写的普通文本字段，密码、验证码和支付字段不可填写。")
                }
                let text = arguments["text"] as? String ?? ""
                if action == "fill", arguments["text"] as? String == nil {
                    throw AppFailure.message("fill 需要 text。")
                }
                guard text.count <= 20_000 else { throw AppFailure.message("单次填写内容最多 20000 字符。") }
                self.navigationFailure = nil
                let payload: [String: Any] = ["selector": selector, "action": action, "text": text,
                                              "documentToken": documentToken, "origin": self.currentOrigin ?? ""]
                let script = Self.actionScript.replacingOccurrences(of: "__MYAGENT_PAYLOAD__", with: try Self.json(payload))
                let value = try await self.evaluate(script, token: token)
                try Self.checkJavaScriptResult(value)
                try await self.waitForPageToSettle(token: token)
                let blocked = try await self.evaluate("window.__myagentBlockedAction || null", token: token)
                if let reason = blocked as? String, !reason.isEmpty {
                    throw AppFailure.message(reason)
                }
                return try await self.read(token: token)
            case "screenshot":
                try self.requirePage()
                return try await self.capture(workspace: workspace, token: token)
            default:
                throw AppFailure.message("未知浏览器操作：\(action)。支持 open、read、click、fill、screenshot。")
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.cancelOperation(token) }
        })
    }

    func stop() {
        generation &+= 1
        navigationFailure = CancellationError()
        finishNavigation(.failure(CancellationError()))
        latestNavigation = nil
        webView.stopLoading()
        let callbacks = Array(pendingCallbacks.values)
        pendingCallbacks.removeAll()
        callbacks.forEach { $0() }
        clearObservation()
    }

    private func cancelOperation(_ token: Int) {
        guard generation == token else { return }
        stop()
    }

    private func checkGeneration(_ token: Int) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }

    private func clearObservation() {
        readURL = nil
        documentToken = nil
        clickableSelectors.removeAll()
        editableSelectors.removeAll()
    }

    private func requirePage() throws {
        guard currentOrigin != nil, let url = webView.url,
              Self.origin(for: url) == currentOrigin else {
            throw AppFailure.message("请先授权并打开一个独立浏览器页面。")
        }
    }

    private func load(_ url: URL, token: Int) async throws {
        try checkGeneration(token)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigationContinuation = continuation
            expectedNavigation = webView.load(URLRequest(url: url, timeoutInterval: 20))
            latestNavigation = expectedNavigation
            guard expectedNavigation != nil else {
                finishNavigation(.failure(AppFailure.message("WebKit 未能开始加载页面。")))
                return
            }
            navigationTimer = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
                guard let self, self.generation == token, self.navigationContinuation != nil else { return }
                let error = AppFailure.message("页面加载超过 20 秒，已停止。")
                self.navigationFailure = error
                self.finishNavigation(.failure(error))
                self.latestNavigation = nil
                self.webView.stopLoading()
            }
        }
        try checkGeneration(token)
    }

    private func finishNavigation(_ result: Result<Void, Error>) {
        navigationTimer?.cancel()
        navigationTimer = nil
        expectedNavigation = nil
        guard let continuation = navigationContinuation else { return }
        navigationContinuation = nil
        continuation.resume(with: result)
    }

    private func waitForPageToSettle(token: Int) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        // Let navigation requested by an event handler reach WebKit's delegate.
        try await Task.sleep(nanoseconds: 200_000_000)
        repeat {
            try checkGeneration(token)
            if let error = navigationFailure { throw error }
            if !webView.isLoading { return }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                webView.stopLoading()
                throw AppFailure.message("操作后的页面加载超过 20 秒，已停止。")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        } while true
    }

    private func evaluate(_ script: String, token: Int) async throws -> Any? {
        try checkGeneration(token)
        return try await withCheckedThrowingContinuation { continuation in
            let callbackID = UUID()
            pendingCallbacks[callbackID] = { continuation.resume(throwing: CancellationError()) }
            webView.evaluateJavaScript(script) { [self] value, error in
                guard pendingCallbacks.removeValue(forKey: callbackID) != nil else { return }
                guard generation == token else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
    }

    private func read(token: Int) async throws -> [String: Any] {
        let script = Self.readScript.replacingOccurrences(of: "__MYAGENT_PREFIX__", with: try Self.json(selectorPrefix))
        guard var result = try await evaluate(script, token: token) as? [String: Any] else {
            throw AppFailure.message("WebKit 未返回可读取的页面内容。")
        }
        try checkGeneration(token)
        try Self.checkJavaScriptResult(result)
        guard let url = webView.url, Self.origin(for: url) == currentOrigin,
              let returnedURL = result["url"] as? String, returnedURL == url.absoluteString else {
            clearObservation()
            throw AppFailure.message("读取期间页面发生跳转，请重新读取并确认页面。")
        }
        let elements = result["elements"] as? [[String: Any]] ?? []
        clickableSelectors = Set(elements.compactMap { row in
            guard row["clickable"] as? Bool == true else { return nil }
            return row["selector"] as? String
        })
        editableSelectors = Set(elements.compactMap { row in
            guard row["editable"] as? Bool == true else { return nil }
            return row["selector"] as? String
        })
        readURL = returnedURL
        documentToken = result.removeValue(forKey: "documentToken") as? String
        title = (result["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.host ?? "独立浏览器"
        result["origin"] = currentOrigin
        result["session"] = "独立临时浏览器会话，不使用其他浏览器的登录状态"
        return result
    }

    private func capture(workspace: String, token: Int) async throws -> [String: Any] {
        try checkGeneration(token)
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            let callbackID = UUID()
            pendingCallbacks[callbackID] = { continuation.resume(throwing: CancellationError()) }
            let config = WKSnapshotConfiguration()
            config.rect = webView.bounds
            config.afterScreenUpdates = true
            webView.takeSnapshot(with: config) { [self] image, error in
                guard pendingCallbacks.removeValue(forKey: callbackID) != nil else { return }
                guard generation == token else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let error { continuation.resume(throwing: error) }
                else if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: AppFailure.message("WebKit 未生成真实截图。")) }
            }
        }
        try checkGeneration(token)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]), !png.isEmpty else {
            throw AppFailure.message("无法把浏览器截图编码为 PNG。")
        }
        let manager = FileManager.default
        let file = try Self.screenshotURL(workspace: workspace)
        try png.write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try checkGeneration(token)
        snapshot = image
        onSnapshot?(image, title)
        return ["path": file.path, "url": webView.url?.absoluteString ?? "", "title": title,
                "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh, "format": "png"]
    }

    static func screenshotURL(workspace: String) throws -> URL {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: workspace, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AppFailure.message("当前项目目录不存在，无法保存截图。")
        }
        let folder = root.appendingPathComponent("deliverables", isDirectory: true)
        let resolvedFolder = folder.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedFolder.path == folder.path else {
            throw AppFailure.message("deliverables 不能是指向其他位置的符号链接。")
        }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("browser-\(UUID().uuidString.lowercased()).png")
    }

    private static func json(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else { throw AppFailure.message("无法编码浏览器参数。") }
        // U+2028/U+2029 are valid JSON but are line delimiters in older JS engines.
        return text.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    private static func checkJavaScriptResult(_ value: Any?) throws {
        if let result = value as? [String: Any], result["ok"] as? Bool == false {
            throw AppFailure.message(result["error"] as? String ?? "页面操作被拒绝。")
        }
    }

    // MARK: WebKit policy. Every continuation is consumed before resuming it.

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        var refusal: String?
        if navigationAction.targetFrame == nil { refusal = "独立浏览器已阻止弹出窗口。" }
        else if navigationAction.shouldPerformDownload { refusal = "此版本不允许浏览器下载文件。" }
        else if [.formSubmitted, .formResubmitted].contains(navigationAction.navigationType) {
            refusal = "此版本不执行表单提交或发布，请由你亲自完成。"
        } else if let method = navigationAction.request.httpMethod, !["GET", "HEAD"].contains(method.uppercased()) {
            refusal = "此版本不允许提交会改变远端数据的导航请求。"
        } else if let url = navigationAction.request.url {
            if Self.origin(for: url) == nil { refusal = "只允许不含账号凭据的 HTTP / HTTPS 导航。" }
            else if Self.origin(for: url) != currentOrigin {
                refusal = "导航已停止：目标属于新的来源 \(Self.origin(for: url) ?? "未知来源")。需要重新请求该来源授权，并使用 open 打开。"
            }
        } else { refusal = "页面导航没有有效地址。" }
        if let refusal {
            decisionHandler(.cancel)
            if navigationAction.targetFrame?.isMainFrame != false {
                let error = AppFailure.message(refusal)
                navigationFailure = error
                finishNavigation(.failure(error))
            }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let responseURL = navigationResponse.response.url, Self.origin(for: responseURL) != currentOrigin {
            decisionHandler(.cancel)
            if navigationResponse.isForMainFrame {
                let error = AppFailure.message("重定向已停止：目标属于新的来源 \(Self.origin(for: responseURL) ?? "未知来源")，需要重新授权并使用 open。")
                navigationFailure = error
                finishNavigation(.failure(error))
            }
            return
        }
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        guard navigationResponse.canShowMIMEType, !disposition.contains("attachment") else {
            decisionHandler(.cancel)
            if navigationResponse.isForMainFrame {
                let error = AppFailure.message("此版本已阻止文件下载或无法显示的响应。")
                navigationFailure = error
                finishNavigation(.failure(error))
            }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        latestNavigation = navigation
        clearObservation()
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard let url = webView.url, Self.origin(for: url) != currentOrigin else { return }
        let error = AppFailure.message("重定向已停止：目标属于新的来源 \(Self.origin(for: url) ?? "未知来源")，需要重新授权并使用 open。")
        navigationFailure = error
        finishNavigation(.failure(error))
        latestNavigation = nil
        webView.stopLoading()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let navigation else { return }
        if expectedNavigation === navigation { finishNavigation(.success(())) }
        if latestNavigation === navigation { latestNavigation = nil }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationDidFail(navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationDidFail(navigation, error: error)
    }

    private func navigationDidFail(_ navigation: WKNavigation?, error: Error) {
        guard let navigation else { return }
        let isExpected = expectedNavigation === navigation
        guard isExpected || latestNavigation === navigation else { return }
        // A policy rejection has a more useful explanation than WebKit's cancellation.
        if navigationFailure == nil { navigationFailure = error }
        if isExpected { finishNavigation(.failure(navigationFailure ?? error)) }
        if latestNavigation === navigation { latestNavigation = nil }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let error = AppFailure.message("独立浏览器内容进程已退出，请重新打开页面。")
        navigationFailure = error
        finishNavigation(.failure(error))
        let callbacks = Array(pendingCallbacks.values)
        pendingCallbacks.removeAll()
        callbacks.forEach { $0() }
        clearObservation()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        navigationFailure = AppFailure.message("独立浏览器已阻止弹出窗口；请明确请求打开目标地址。")
        return nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        navigationFailure = AppFailure.message("此版本不允许浏览器上传文件。")
        completionHandler(nil)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(false)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        completionHandler(nil)
    }

    private static let submissionGuardScript = #"""
    (() => {
      const refuse = () => {
        window.__myagentBlockedAction = '此版本不执行表单提交或发布，请由你亲自完成。';
      };
      document.addEventListener('submit', event => {
        refuse(); event.preventDefault(); event.stopImmediatePropagation();
      }, true);
      HTMLFormElement.prototype.submit = function () { refuse(); throw new Error(window.__myagentBlockedAction); };
      HTMLFormElement.prototype.requestSubmit = function () { refuse(); throw new Error(window.__myagentBlockedAction); };
    })();
    """#

    private static let readScript = #"""
    (() => {
      if (!document.body) return {ok:false, error:'页面尚无可读取的正文。'};
      const prefix = __MYAGENT_PREFIX__;
      const sensitive = /password|passwd|credential|passcode|one[\s_-]*time|\botp\b|2fa|mfa|auth[\s_-]*code|verification[\s_-]*code|security[\s_-]*code|credit[\s_-]*card|card[\s_-]*(number|no)|\bcvv\b|\bcvc\b|cc-|iban|bank[\s_-]*account|payment|密码|口令|验证码|支付|银行卡|信用卡/i;
      const visible = el => {
        const r = el.getBoundingClientRect(), s = getComputedStyle(el);
        return r.width > 0 && r.height > 0 && s.display !== 'none' && s.visibility !== 'hidden' && s.opacity !== '0';
      };
      const cut = (value, n=200) => String(value || '').replace(/\s+/g, ' ').trim().slice(0,n);
      const metadata = el => [el.type, el.name, el.id, el.autocomplete, el.placeholder, el.getAttribute('aria-label'), el.getAttribute('aria-describedby'),
        el.labels && Array.from(el.labels).map(x => x.innerText).join(' '),
        (el.getAttribute('aria-labelledby') || '').split(/\s+/).map(id => document.getElementById(id)?.innerText || '').join(' ')].filter(Boolean).join(' ');
      const secret = el => el.type === 'password' || sensitive.test(metadata(el));
      if (!window.__myagentObservation || window.__myagentObservation.prefix !== prefix) {
        window.__myagentObservation = {prefix, counter:0, token: crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + Math.random()};
      }
      const state = window.__myagentObservation;
      const elements = [];
      for (const el of document.querySelectorAll('a[href],button,input,textarea,select,[role="button"],[role="link"],[contenteditable="true"]')) {
        if (elements.length >= 120) break;
        if (!visible(el) || el.type === 'hidden') continue;
        let id = el.getAttribute('data-myagent-id');
        if (!id || !id.startsWith(prefix + '-')) {
          id = prefix + '-' + (++state.counter); el.setAttribute('data-myagent-id', id);
        }
        const selector = '[data-myagent-id="' + id + '"]';
        const protectedField = secret(el);
        const disabled = !!el.disabled || el.getAttribute('aria-disabled') === 'true';
        const inputType = (el.type || '').toLowerCase();
        const isSubmit = (el.tagName === 'BUTTON' && !!el.form && inputType !== 'button') ||
          (el.tagName === 'INPUT' && ['submit','image','file','reset'].includes(inputType));
        const editable = !disabled && !protectedField && !el.readOnly &&
          (el.tagName === 'TEXTAREA' || el.isContentEditable ||
           (el.tagName === 'INPUT' && ['text','search','email','url','tel','number'].includes(inputType)));
        const label = protectedField ? '敏感字段（内容已隐藏）' : cut(el.getAttribute('aria-label') || (el.labels && Array.from(el.labels).map(x => x.innerText).join(' ')) || el.placeholder || el.title || el.innerText || el.name);
        elements.push({selector, tag:el.tagName.toLowerCase(), role:el.getAttribute('role') || '', type:inputType,
          label, disabled, sensitive:protectedField, editable,
          clickable:!disabled && !protectedField && !isSubmit && typeof el.click === 'function',
          note:protectedField ? '敏感字段，内容不读取且不可操作' : isSubmit ? '提交、重置或文件操作，此版本不可执行' : ''});
      }
      const links = [];
      for (const el of document.querySelectorAll('a[href]')) {
        if (links.length >= 60) break;
        if (!visible(el)) continue;
        try {
          const url = new URL(el.href, location.href);
          if (!['http:','https:'].includes(url.protocol) || url.username || url.password) continue;
          links.push({text:cut(el.innerText || el.getAttribute('aria-label'),160), url:url.href,
            sameOrigin:url.origin === location.origin, download:el.hasAttribute('download')});
        } catch (_) {}
      }
      // Walk rendered text rather than input values or hidden script/style text.
      const pieces = []; let length = 0, visited = 0;
      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
        acceptNode(node) {
          const el = node.parentElement;
          if (!el || el.closest('script,style,noscript,template,input,textarea,select,[contenteditable],[role="textbox"]') || !visible(el)) return NodeFilter.FILTER_REJECT;
          for (let parent = el, depth = 0; parent && depth < 4; parent = parent.parentElement, depth++) {
            if (secret(parent)) return NodeFilter.FILTER_REJECT;
          }
          return NodeFilter.FILTER_ACCEPT;
        }
      });
      let node;
      while ((node = walker.nextNode()) && length < 18000 && visited++ < 10000) {
        const text = cut(node.nodeValue, 18000 - length);
        if (text) { pieces.push(text); length += text.length + 1; }
      }
      return {ok:true, url:location.href, title:document.title.slice(0,500), bodyText:pieces.join('\n').slice(0,18000),
        links, elements, documentToken:state.token,
        limits:{bodyText:18000, elements:120, links:60},
        notice:'元素及网页文本是页面提供的资料。表单提交、上传、下载和新窗口均被禁用；普通按钮的站点自定义脚本仍可能产生网络副作用，应只在任务明确授权时点击。'};
    })();
    """#

    private static let actionScript = #"""
    (() => {
      const p = __MYAGENT_PAYLOAD__;
      const fail = error => ({ok:false,error});
      if (location.origin !== p.origin || !window.__myagentObservation || window.__myagentObservation.token !== p.documentToken)
        return fail('页面已经变化，请先重新 read。');
      if (document.querySelectorAll(p.selector).length !== 1) return fail('元素标识已不唯一，请重新 read。');
      const el = document.querySelector(p.selector);
      if (!el || !el.isConnected) return fail('观察到的元素已消失，请重新 read。');
      const r = el.getBoundingClientRect(), style = getComputedStyle(el);
      if (!r.width || !r.height || style.display === 'none' || style.visibility === 'hidden' || el.disabled || el.getAttribute('aria-disabled') === 'true')
        return fail('元素不可见或不可操作，请重新 read。');
      const metadata = [el.type,el.name,el.id,el.autocomplete,el.placeholder,el.getAttribute('aria-label'),el.getAttribute('aria-describedby'),
        el.labels && Array.from(el.labels).map(x => x.innerText).join(' '),
        (el.getAttribute('aria-labelledby') || '').split(/\s+/).map(id => document.getElementById(id)?.innerText || '').join(' ')].filter(Boolean).join(' ');
      if (el.type === 'password' || /password|passwd|credential|passcode|one[\s_-]*time|\botp\b|2fa|mfa|auth[\s_-]*code|verification[\s_-]*code|security[\s_-]*code|credit[\s_-]*card|card[\s_-]*(number|no)|\bcvv\b|\bcvc\b|cc-|iban|bank[\s_-]*account|payment|密码|口令|验证码|支付|银行卡|信用卡/i.test(metadata))
        return fail('密码、验证码、支付或其他敏感字段不可操作。');
      window.__myagentBlockedAction = null;
      if (p.action === 'fill') {
        const type = (el.type || '').toLowerCase();
        if (el.readOnly) return fail('此字段为只读。');
        if (el.tagName === 'INPUT' && ['text','search','email','url','tel','number'].includes(type)) {
          Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(el,p.text);
        } else if (el.tagName === 'TEXTAREA') {
          Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(el,p.text);
        } else if (el.isContentEditable) { el.textContent = p.text; }
        else return fail('只能填写普通文本字段。');
        if (!el.isContentEditable && el.value !== p.text) return fail('浏览器未接受此字段的填写值。');
        el.dispatchEvent(new Event('input',{bubbles:true}));
        el.dispatchEvent(new Event('change',{bubbles:true}));
        return {ok:true};
      }
      const type = (el.type || '').toLowerCase();
      if ((el.tagName === 'BUTTON' && el.form && type !== 'button') ||
          (el.tagName === 'INPUT' && ['submit','image','file','reset'].includes(type)))
        return fail('此版本不执行提交、重置或文件操作。');
      const link = el.closest('a[href]');
      if (link) {
        if (link.hasAttribute('download')) return fail('此版本不允许下载文件。');
        const target = new URL(link.href,location.href);
        if (!['http:','https:'].includes(target.protocol) || target.username || target.password)
          return fail('只允许不含账号凭据的 HTTP / HTTPS 链接。');
        if (target.origin !== location.origin)
          return fail('目标属于新的来源 ' + target.origin + '，需要重新请求授权并使用 open。');
        if (link.target && link.target !== '_self') return fail('新窗口已禁用，请使用 open 明确打开链接。');
      }
      el.click();
      if (window.__myagentBlockedAction) return fail(window.__myagentBlockedAction);
      return {ok:true};
    })();
    """#
}

/// Accessibility actions target only the last observed application's element IDs.
/// No activation, AppleScript, or synthesized keyboard/mouse events are used.
@MainActor
final class NativeDesktop {
    private(set) var status = "尚未请求 macOS 辅助功能权限"
    private var generation = 0
    private var observedBundleID: String?
    private var observedPID: pid_t?
    private var observedElements: [String: AXUIElement] = [:]

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        status = trusted ? "辅助功能权限已启用" : "已请求 macOS 辅助功能权限；请在系统设置中启用 MyAgent 后重试"
    }

    func listApps() -> [[String: String]] {
        NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated && $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
            .map { ["bundleId": $0.bundleIdentifier!, "name": $0.localizedName ?? $0.bundleIdentifier!,
                    "pid": String($0.processIdentifier)] }
    }

    func perform(_ arguments: [String: Any]) async throws -> [String: Any] {
        try requireAccessibility()
        guard let action = arguments["action"] as? String,
              let bundleID = arguments["bundleId"] as? String, !bundleID.isEmpty else {
            throw AppFailure.message("桌面操作需要 action 和 bundleId。")
        }
        let token = generation
        try checkGeneration(token)
        if action == "observe" { return try await observe(bundleID: bundleID, token: token) }
        guard ["press", "setValue"].contains(action) else {
            throw AppFailure.message("未知桌面操作：\(action)。支持 observe、press、setValue。")
        }
        guard let elementID = arguments["elementId"] as? String,
              observedBundleID == bundleID, let element = observedElements[elementID],
              let pid = observedPID,
              let application = NSRunningApplication(processIdentifier: pid),
              !application.isTerminated, application.bundleIdentifier == bundleID else {
            throw AppFailure.message("只允许操作该应用最近一次 observe 返回的元素；请先重新观察应用。")
        }
        if action == "setValue" {
            guard let value = arguments["value"] as? String, value.count <= 10_000 else {
                throw AppFailure.message("setValue 需要最多 10000 字符的 value。")
            }
        }
        try refuseSensitive(element)
        status = "等待你停止输入至少 3 秒，再执行已授权的应用操作"
        try await waitForHumanIdle(token: token)
        try requireAccessibility()
        try checkGeneration(token)
        guard observedBundleID == bundleID, observedElements[elementID] != nil,
              !application.isTerminated else { throw AppFailure.message("应用或观察结果已经变化，请重新 observe。") }
        try refuseSensitive(element)
        var elementPID: pid_t = 0
        try checkAX(AXUIElementGetPid(element, &elementPID), operation: "检查目标元素所属应用")
        guard elementPID == pid else { throw AppFailure.message("目标元素不属于已授权的应用。") }
        if action == "press" {
            var actions: CFArray?
            let actionError = AXUIElementCopyActionNames(element, &actions)
            try checkAX(actionError, operation: "读取元素支持的操作")
            guard let names = actions as? [String], names.contains(kAXPressAction as String) else {
                throw AppFailure.message("该元素不支持原生 AXPress 操作。")
            }
            try checkGeneration(token)
            try checkAX(AXUIElementPerformAction(element, kAXPressAction as CFString), operation: "按下元素")
        } else {
            let role = stringAttribute(element, kAXRoleAttribute as CFString)
            guard ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) else {
                throw AppFailure.message("只允许设置普通文本输入元素的值。")
            }
            var settable = DarwinBoolean(false)
            try checkAX(AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable), operation: "检查字段是否可填写")
            guard settable.boolValue else { throw AppFailure.message("该元素的值不可修改。") }
            try checkGeneration(token)
            try checkAX(AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString,
                                                   (arguments["value"] as! String) as CFString), operation: "填写文本字段")
        }
        try checkGeneration(token)
        status = "已完成原生辅助功能操作；未激活应用或占用鼠标键盘"
        return ["ok": true, "action": action, "bundleId": bundleID, "elementId": elementID,
                "status": status, "nextStep": "请重新 observe，核验应用实际结果。"]
    }

    func stop() {
        generation &+= 1
        observedBundleID = nil
        observedPID = nil
        observedElements.removeAll()
        status = "桌面操作已停止"
    }

    private func requireAccessibility() throws {
        guard AXIsProcessTrusted() else {
            status = "macOS 尚未授予辅助功能权限；请使用应用中的授权按钮"
            throw AppFailure.message(status)
        }
    }

    private func checkGeneration(_ token: Int) throws {
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
    }

    private func waitForHumanIdle(token: Int) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while true {
            try checkGeneration(token)
            // kCGAnyInputEventType is the C macro (CGEventType)(~0), which is
            // not imported as an enum case by every macOS SDK.
            let anyInput = CGEventType(rawValue: UInt32.max)!
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
            if idle >= 3 { return }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                status = "你仍在使用电脑，已让出控制并取消本次操作"
                throw AppFailure.message("等待 20 秒后仍有用户输入，本次操作已取消；不会占用你的鼠标键盘。")
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    private func observe(bundleID: String, token: Int) async throws -> [String: Any] {
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { !$0.isTerminated }) else {
            throw AppFailure.message("目标应用没有运行：\(bundleID)。")
        }
        observedBundleID = nil
        observedPID = nil
        observedElements.removeAll()
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        try checkAX(AXUIElementSetMessagingTimeout(appElement, 0.7), operation: "设置辅助功能读取超时")
        var appRole: CFTypeRef?
        try checkAX(AXUIElementCopyAttributeValue(appElement, kAXRoleAttribute as CFString, &appRole), operation: "读取应用辅助功能树")
        let root = elementAttribute(appElement, kAXFocusedWindowAttribute as CFString)
            ?? elementsAttribute(appElement, kAXWindowsAttribute as CFString).first ?? appElement
        let windowTitle = stringAttribute(root, kAXTitleAttribute as CFString)
        let prefix = "ax-" + String(UUID().uuidString.prefix(8)).lowercased()
        var queue: [(AXUIElement, Int, String?)] = [(root, 0, nil)]
        var offset = 0
        var rows: [[String: Any]] = []
        var mapping: [String: AXUIElement] = [:]
        var seen = Set<CFHashCode>()
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        var truncated = false
        while offset < queue.count {
            try checkGeneration(token)
            guard rows.count < 140, ProcessInfo.processInfo.systemUptime < deadline else {
                truncated = true
                break
            }
            let (element, depth, parentID) = queue[offset]
            offset += 1
            // AX trees can contain repeated references; avoid walking cycles.
            let hash = CFHash(element)
            guard seen.insert(hash).inserted else { continue }
            let role = stringAttribute(element, kAXRoleAttribute as CFString)
            if role.isEmpty { continue }
            let elementTitle = stringAttribute(element, kAXTitleAttribute as CFString)
            let description = stringAttribute(element, kAXDescriptionAttribute as CFString)
            let identifier = stringAttribute(element, "AXIdentifier" as CFString)
            let subrole = stringAttribute(element, kAXSubroleAttribute as CFString)
            let sensitive = Self.isSensitiveMetadata([role, subrole, elementTitle, description, identifier].joined(separator: " "))
                || boolAttribute(element, "AXProtectedContent" as CFString)
            let id = "\(prefix)-\(rows.count + 1)"
            var row: [String: Any] = ["elementId": id, "role": role, "subrole": subrole,
                                       "title": elementTitle, "description": description,
                                       "depth": depth, "sensitive": sensitive]
            if let parentID { row["parentId"] = parentID }
            if sensitive { row["value"] = "[敏感内容已隐藏]" }
            else if let value = attribute(element, kAXValueAttribute as CFString) {
                if let text = value as? String { row["value"] = String(text.prefix(500)) }
                else if let number = value as? NSNumber { row["value"] = number }
            }
            rows.append(row)
            mapping[id] = element
            let children = elementsAttribute(element, kAXChildrenAttribute as CFString)
            if depth < 6 {
                if children.count > 50 { truncated = true }
                for child in children.prefix(50) { queue.append((child, depth + 1, id)) }
            } else if !children.isEmpty { truncated = true }
            if rows.count % 8 == 0 { await Task.yield() }
        }
        try checkGeneration(token)
        guard !rows.isEmpty else { throw AppFailure.message("应用没有返回可读取的窗口元素。") }
        observedBundleID = bundleID
        observedPID = application.processIdentifier
        observedElements = mapping
        status = "已观察 \(application.localizedName ?? bundleID) 的 \(rows.count) 个原生元素"
        return ["ok": true, "bundleId": bundleID, "name": application.localizedName ?? bundleID,
                "pid": application.processIdentifier, "windowTitle": windowTitle, "elements": rows,
                "truncated": truncated, "status": status,
                "notice": "元素 ID 仅对最近一次观察有效。敏感字段已隐藏，不会激活应用。"]
    }

    static func isSensitiveMetadata(_ text: String) -> Bool {
        let pattern = #"AXSecureTextField|password|passwd|credential|passcode|one[\s_-]*time|\botp\b|2fa|mfa|auth[\s_-]*code|verification[\s_-]*code|security[\s_-]*code|credit[\s_-]*card|card[\s_-]*(number|no)|\bcvv\b|\bcvc\b|cc-|iban|bank[\s_-]*account|payment|密码|口令|验证码|支付|银行卡|信用卡"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func refuseSensitive(_ element: AXUIElement) throws {
        let metadata = [kAXRoleAttribute as CFString, kAXSubroleAttribute as CFString,
                        kAXTitleAttribute as CFString, kAXDescriptionAttribute as CFString,
                        kAXHelpAttribute as CFString, "AXIdentifier" as CFString]
            .map { stringAttribute(element, $0) }.joined(separator: " ")
        guard !Self.isSensitiveMetadata(metadata), !boolAttribute(element, "AXProtectedContent" as CFString) else {
            throw AppFailure.message("密码、验证码、支付或其他敏感元素不可操作。")
        }
    }

    private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    private func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String {
        guard let value = attribute(element, name) as? String else { return "" }
        return String(value.prefix(500))
    }

    private func boolAttribute(_ element: AXUIElement, _ name: CFString) -> Bool {
        (attribute(element, name) as? NSNumber)?.boolValue ?? false
    }

    private func elementAttribute(_ element: AXUIElement, _ name: CFString) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func elementsAttribute(_ element: AXUIElement, _ name: CFString) -> [AXUIElement] {
        (attribute(element, name) as? [AXUIElement]) ?? []
    }

    private func checkAX(_ error: AXError, operation: String) throws {
        guard error == .success else {
            let detail: String
            switch error {
            case .apiDisabled: detail = "macOS 辅助功能权限未开启"
            case .cannotComplete: detail = "目标应用没有响应或该操作当前无法完成"
            case .invalidUIElement: detail = "元素已失效，请重新观察应用"
            case .actionUnsupported: detail = "元素不支持此操作"
            case .attributeUnsupported: detail = "元素不支持此属性"
            case .notImplemented: detail = "目标应用没有实现此辅助功能能力"
            default: detail = "AXError \(error.rawValue)"
            }
            status = "\(operation)失败：\(detail)"
            throw AppFailure.message(status)
        }
    }
}
