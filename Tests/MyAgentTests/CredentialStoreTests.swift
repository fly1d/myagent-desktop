import Foundation
import Testing
@testable import MyAgent

@MainActor
struct CredentialStoreTests {
    @Test
    func isolatedSystemKeychainSavesUpdatesReadsAndRemovesOnlyItsOwnTestItem() throws {
        let store = KeychainCredentialStore(service: "dev.myagent.desktop.qa.\(UUID().uuidString)", allowsUserInteraction: false)
        let account = "fixture-account"
        let secret = "test-only-not-a-provider-key-\(UUID().uuidString)"
        defer { try? store.remove(account) }
        #expect(try store.read(account) == nil)
        try store.save(secret, account: account)
        #expect(try store.read(account) == secret)
        try store.save(secret + "-updated", account: account)
        #expect(try store.read(account) == secret + "-updated")
        #expect(try store.read("different-account") == nil)
        try store.remove(account)
        #expect(try store.read(account) == nil)
    }
}

@MainActor
final class MemoryCredentialStore: CredentialStore {
    var values: [String: String] = [:]
    var failWrites = false
    var onSave: (() -> Void)?
    var attemptedAccounts: [String] = []
    func read(_ account: String, allowInteraction: Bool) throws -> String? {
        attemptedAccounts.append(account)
        return values[account]
    }
    func save(_ secret: String, account: String) throws {
        if failWrites { throw AppFailure.message("模拟钥匙串拒绝保存") }
        values[account] = secret
        let callback = onSave
        onSave = nil
        callback?()
    }
    func remove(_ account: String) throws { values.removeValue(forKey: account) }
}
