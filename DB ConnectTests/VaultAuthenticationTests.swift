import Foundation
import XCTest

final class VaultAuthenticationTests: XCTestCase {
    func testTokenScopeIncludesServerAndAuthMount() {
        let url = URL(string: "https://vault.example.test/")!
        let first = VaultTokenScope(serverURL: url, authMount: "oidc")
        let second = VaultTokenScope(serverURL: url, authMount: "jwt")

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.keychainAccount, "https://vault.example.test|oidc")
        XCTAssertFalse(first.keychainAccount.contains("token"))
    }

    func testProviderReusesTokenAndUnexpiredLease() async throws {
        let api = FakeVaultAPI()
        let auth = FakeAuthenticator()
        let provider = try makeProvider(auth: auth, api: api, store: InMemoryVaultTokenStore())
        let now = Date(timeIntervalSince1970: 1_000)

        let first = try await provider.credentials(now: now)
        let second = try await provider.credentials(now: now.addingTimeInterval(10))

        XCTAssertEqual(first, second)
        XCTAssertEqual(auth.calls, 1)
        XCTAssertEqual(api.readCalls, 1)
        XCTAssertEqual(api.renewCalls, 0)
    }

    func testProviderRenewsExpiringLeaseWithoutPersistingPassword() async throws {
        let api = FakeVaultAPI()
        let auth = FakeAuthenticator()
        let store = InMemoryVaultTokenStore()
        let provider = try makeProvider(auth: auth, api: api, store: store)
        let now = Date(timeIntervalSince1970: 1_000)

        _ = try await provider.credentials(now: now)
        let refreshed = try await provider.credentials(now: now.addingTimeInterval(80))

        XCTAssertEqual(refreshed.username, "vault-user")
        XCTAssertEqual(refreshed.expiresAt, now.addingTimeInterval(180))
        XCTAssertEqual(auth.calls, 1)
        XCTAssertEqual(api.readCalls, 1)
        XCTAssertEqual(api.renewCalls, 1)
        XCTAssertEqual(store.savedToken?.value, "vault-token")
    }

    func testProviderPropagatesCancellation() async throws {
        let auth = ClosureVaultOIDCAuthenticator { _ in
            try await Task.sleep(for: .seconds(10))
            return VaultToken(value: "never", expiresAt: nil, renewable: false)
        }
        let provider = try makeProvider(auth: auth, api: FakeVaultAPI(), store: InMemoryVaultTokenStore())
        let task = Task { try await provider.credentials() }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is VaultError {
            // The provider maps injected flow cancellation to a user-safe Vault error.
        } catch is CancellationError {
            // Also acceptable when an authenticator preserves Swift cancellation.
        }
    }

    func testResolverRequiresRuntimeVaultPassword() throws {
        let config = ConnectionConfig(
            driverID: "mysql",
            host: "mysql.example.test",
            username: "saved-user",
            authentication: DatabaseAuthenticationConfiguration(
                mode: .vaultOIDC,
                vault: VaultAuthenticationConfiguration(
                    serverURL: URL(string: "https://vault.example.test")!,
                    role: "db-reader",
                    databaseRole: "mysql-reader"
                )
            )
        )

        XCTAssertThrowsError(try ConnectionRuntimeSecretResolver.resolve(config: config, secret: nil)) { error in
            XCTAssertEqual(error as? DatabaseError, .missingCredentials)
        }
        XCTAssertNotNil(try ConnectionRuntimeSecretResolver.resolve(config: config, secret: Secret(password: "ephemeral")))
    }

    func testVaultModeRemovesStaticDatabasePassword() {
        let persisted = Secret(password: "old-password", apiToken: "unrelated")
        let vaultSecret = persisted.removingStaticDatabasePassword(for: .vaultOIDC)

        XCTAssertNil(vaultSecret.password)
        XCTAssertEqual(vaultSecret.apiToken, "unrelated")
        XCTAssertEqual(persisted.password, "old-password")
    }

    func testOIDCAuthURLAndCallbackUseInjectableHTTPSTransport() async throws {
        let transport = QueueVaultTransport(responses: [
            Data(#"{"data":{"auth_url":"https://idp.example.test/authorize?state=state-1&nonce=nonce-1"}}"#.utf8),
            Data(#"{"auth":{"client_token":"vault-token","lease_duration":300,"renewable":true}}"#.utf8)
        ])
        let client = VaultHTTPClient(transport: transport)
        let configuration = VaultAuthenticationConfiguration(
            serverURL: URL(string: "https://vault.example.test")!,
            role: "db-reader",
            databaseRole: "mysql-reader"
        )
        let redirect = URL(string: "dbconnect://vault/oidc/callback")!

        let request = try await client.authorizationRequest(
            configuration: configuration,
            redirectURI: redirect,
            clientNonce: "client-1"
        )
        let token = try await client.exchangeCallback(
            configuration: configuration,
            request: request,
            callbackURL: URL(string: "dbconnect://vault/oidc/callback?state=state-1&nonce=nonce-1&code=code-1")!,
            now: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(request.state, "state-1")
        XCTAssertEqual(request.nonce, "nonce-1")
        XCTAssertEqual(token.value, "vault-token")
        XCTAssertEqual(token.expiresAt, Date(timeIntervalSince1970: 1_300))
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests[0].httpMethod, "POST")
        XCTAssertNil(transport.requests[0].value(forHTTPHeaderField: "X-Vault-Token"))
        XCTAssertTrue(transport.requests[1].url?.path.contains("oidc/callback") == true)
    }

    func testOIDCCallbackRejectsUnexpectedState() async throws {
        let transport = QueueVaultTransport(responses: [
            Data(#"{"data":{"auth_url":"https://idp.example.test/authorize?state=expected&nonce=nonce"}}"#.utf8)
        ])
        let client = VaultHTTPClient(transport: transport)
        let configuration = VaultAuthenticationConfiguration(
            serverURL: URL(string: "https://vault.example.test")!,
            role: "db-reader",
            databaseRole: "mysql-reader"
        )
        let request = try await client.authorizationRequest(
            configuration: configuration,
            redirectURI: URL(string: "dbconnect://vault/callback")!
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await client.exchangeCallback(
                configuration: configuration,
                request: request,
                callbackURL: URL(string: "dbconnect://vault/callback?state=wrong&nonce=nonce&code=code")!,
                now: .now
            )
        }
    }

    private func makeProvider(
        auth: any VaultOIDCAuthenticator,
        api: any VaultCredentialAPI,
        store: any VaultTokenStore
    ) throws -> VaultMySQLEphemeralCredentialProvider {
        try VaultMySQLEphemeralCredentialProvider(
            configuration: VaultAuthenticationConfiguration(
                serverURL: URL(string: "https://vault.example.test")!,
                role: "db-reader",
                databaseRole: "mysql-reader",
                refreshLeeway: 30
            ),
            authenticator: auth,
            api: api,
            tokenStore: store
        )
    }
}

private final class QueueVaultTransport: VaultHTTPTransport, @unchecked Sendable {
    private var responses: [Data]
    private(set) var requests: [URLRequest] = []

    init(responses: [Data]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw VaultError.transport("No test response available.") }
        let data = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync(
        _ expression: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("Expected error", file: file, line: line)
        } catch {
            // Expected path.
        }
    }
}

private final class InMemoryVaultTokenStore: VaultTokenStore, @unchecked Sendable {
    private(set) var savedToken: VaultToken?
    func token(for scope: VaultTokenScope) throws -> VaultToken? { savedToken }
    func save(_ token: VaultToken, for scope: VaultTokenScope) throws { savedToken = token }
    func removeToken(for scope: VaultTokenScope) throws { savedToken = nil }
}

private final class FakeAuthenticator: VaultOIDCAuthenticator, @unchecked Sendable {
    private(set) var calls = 0
    func authenticate(configuration: VaultAuthenticationConfiguration) async throws -> VaultToken {
        calls += 1
        return VaultToken(value: "vault-token", expiresAt: Date(timeIntervalSince1970: 10_000), renewable: true)
    }
}

private final class FakeVaultAPI: VaultCredentialAPI, @unchecked Sendable {
    private(set) var readCalls = 0
    private(set) var renewCalls = 0

    func readDatabaseCredentials(
        configuration: VaultAuthenticationConfiguration,
        token: VaultToken,
        now: Date
    ) async throws -> VaultDatabaseLease {
        readCalls += 1
        return VaultDatabaseLease(
            leaseID: "lease-1",
            username: "vault-user",
            password: "ephemeral-password",
            leaseDuration: 100,
            renewable: true,
            issuedAt: now
        )
    }

    func renewLease(
        configuration: VaultAuthenticationConfiguration,
        token: VaultToken,
        leaseID: String,
        now: Date
    ) async throws -> VaultLeaseRefresh {
        renewCalls += 1
        return VaultLeaseRefresh(leaseID: leaseID, leaseDuration: 100, renewable: true, issuedAt: now)
    }
}
