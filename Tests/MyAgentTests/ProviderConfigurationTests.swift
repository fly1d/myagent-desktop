import Foundation
import Testing
@testable import MyAgent

struct ProviderConfigurationTests {
    @Test(arguments: [
        "http://127.0.0.1:11434/v1", "http://127.9.8.7/v1", "http://localhost/v1",
        "https://LOCALHOST/v1", "http://[::1]:11434/v1", "http://[0:0:0:0:0:0:0:1]/v1"
    ])
    func noKeyModeAcceptsOnlyExplicitLoopbackEndpoints(_ address: String) throws {
        let provider = ProviderDraft(kind: "local", baseURL: address, model: "", authentication: .some(.none))
        #expect(provider.allowsNoKey)
        #expect(!provider.requiresAPIKey)
        #expect(try provider.endpoint().host != nil)
    }

    @Test(arguments: [
        "https://api.example.com/v1", "http://192.168.1.10/v1", "http://0.0.0.0/v1",
        "http://localhost.evil.example/v1", "http://evil.localhost/v1", "http://localhost./v1",
        "http://127.0.0.1.nip.io/v1", "http://[::ffff:127.0.0.1]/v1",
        "http://user@localhost/v1", "http://@localhost/v1", "http://user:password@localhost/v1",
        "http://localhost/v1?api_key=ignored", "http://localhost/v1#ignored", "file:///tmp/model"
    ])
    func noKeyModeRejectsRemoteAndMisleadingAddresses(_ address: String) {
        let provider = ProviderDraft(kind: "custom", baseURL: address, model: "fixture", authentication: .some(.none))
        #expect(!provider.allowsNoKey)
    }

    @Test
    func legacyProviderDefaultsToKeyAndCloudPresetsCannotOptOut() throws {
        let old = Data(#"{"kind":"deepseek","baseURL":"https://api.deepseek.com","model":"deepseek-chat"}"#.utf8)
        let decoded = try JSONDecoder().decode(ProviderDraft.self, from: old)
        #expect(decoded.authentication == nil)
        #expect(decoded.requiresAPIKey)
        #expect(decoded.authMode == .apiKey)
        var cloud = decoded
        cloud.baseURL = "http://127.0.0.1/v1"
        cloud.authentication = .some(.none)
        #expect(!cloud.allowsNoKey)
    }

    @Test @MainActor
    func connectionFormCanDiscoverWithoutModelButRequiresExplicitLocalNoKeyMode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("myagent-provider-form-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(dataDirectory: directory)
        model.providerDraft = ProviderDraft(kind: "local", baseURL: "http://localhost:11434/v1", model: "", authentication: .some(.none))
        #expect(model.canTestConnection)
        model.providerDraft.authentication = .apiKey
        #expect(!model.canTestConnection)
        model.apiKeyDraft = "fixture-only-not-a-real-key"
        #expect(model.canTestConnection)
        model.providerDraft.authentication = .some(.none)
        model.providerDraft.baseURL = "https://api.example.com/v1"
        #expect(!model.canTestConnection)
        model.providerDraft.authentication = .apiKey
        #expect(model.canTestConnection)
        model.providerDraft.baseURL = "http://api.example.com/v1"
        #expect(!model.canTestConnection)
    }
}
