import Foundation

/// Configuration for Vault OIDC and its database secrets engine. Vault is deliberately restricted
/// to HTTPS; URLSession performs the system trust evaluation for the server certificate.
nonisolated struct VaultAuthenticationConfiguration: Sendable, Hashable, Codable {
    var serverURL: URL
    var authMount: String
    var role: String
    var databaseMount: String
    var databaseRole: String
    /// Refresh before expiry so a connection handshake does not start with a stale credential.
    var refreshLeeway: TimeInterval

    init(
        serverURL: URL,
        authMount: String = "oidc",
        role: String,
        databaseMount: String = "database",
        databaseRole: String,
        refreshLeeway: TimeInterval = 30
    ) {
        self.serverURL = serverURL
        self.authMount = authMount
        self.role = role
        self.databaseMount = databaseMount
        self.databaseRole = databaseRole
        self.refreshLeeway = refreshLeeway
    }

    func validate() throws {
        guard serverURL.scheme?.lowercased() == "https",
              serverURL.host != nil,
              serverURL.user == nil,
              serverURL.password == nil,
              serverURL.query == nil,
              serverURL.fragment == nil else {
            throw VaultError.invalidConfiguration("Vault server must be an HTTPS URL without credentials or query parameters.")
        }
        guard Self.validPath(authMount), Self.validPath(databaseMount) else {
            throw VaultError.invalidConfiguration("Vault mount names must be non-empty paths without dot segments.")
        }
        guard Self.validLeaf(role), Self.validLeaf(databaseRole) else {
            throw VaultError.invalidConfiguration("Vault auth and database roles are required.")
        }
        guard refreshLeeway >= 0, refreshLeeway < 86_400 else {
            throw VaultError.invalidConfiguration("Vault refresh leeway must be between zero and one day.")
        }
    }

    var tokenScope: VaultTokenScope {
        VaultTokenScope(serverURL: serverURL, authMount: authMount)
    }

    private static func validPath(_ value: String) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return !components.isEmpty && !components.contains(".") && !components.contains("..")
    }

    private static func validLeaf(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.contains("/") && trimmed != "." && trimmed != ".."
    }
}

/// Stable, non-secret Keychain namespace for one Vault server and auth mount.
nonisolated struct VaultTokenScope: Sendable, Hashable {
    let server: String
    let authMount: String

    init(serverURL: URL, authMount: String) {
        var server = serverURL.absoluteString
        while server.hasSuffix("/") { server.removeLast() }
        self.server = server
        self.authMount = authMount
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var keychainAccount: String { "\(server)|\(authMount)" }
}

nonisolated struct VaultToken: Sendable, Hashable, Codable {
    let value: String
    let expiresAt: Date?
    let renewable: Bool

    init(value: String, expiresAt: Date?, renewable: Bool) {
        self.value = value
        self.expiresAt = expiresAt
        self.renewable = renewable
    }

    func isUsable(at now: Date, leeway: TimeInterval) -> Bool {
        guard !value.isEmpty else { return false }
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(now) > leeway
    }
}

nonisolated struct VaultOIDCAuthorizationRequest: Sendable, Hashable {
    let authorizationURL: URL
    let state: String
    let nonce: String?
    let clientNonce: String?
    let redirectURI: URL
}

nonisolated struct VaultLeaseRefresh: Sendable, Hashable {
    let leaseID: String
    let leaseDuration: TimeInterval
    let renewable: Bool
    let issuedAt: Date

    var expiresAt: Date { issuedAt.addingTimeInterval(leaseDuration) }
}

nonisolated struct VaultDatabaseLease: Sendable, Hashable {
    let leaseID: String
    let username: String
    let password: String
    let leaseDuration: TimeInterval
    let renewable: Bool
    let issuedAt: Date

    var expiresAt: Date { issuedAt.addingTimeInterval(leaseDuration) }

    func isUsable(at now: Date, leeway: TimeInterval) -> Bool {
        !username.isEmpty && !password.isEmpty && expiresAt.timeIntervalSince(now) > leeway
    }

    func refreshed(with refresh: VaultLeaseRefresh) -> VaultDatabaseLease {
        VaultDatabaseLease(
            leaseID: refresh.leaseID,
            username: username,
            password: password,
            leaseDuration: refresh.leaseDuration,
            renewable: refresh.renewable,
            issuedAt: refresh.issuedAt
        )
    }
}

/// Runtime-only values for one MySQL connection attempt. Vault passwords are never Codable.
nonisolated struct VaultMySQLCredentials: Sendable, Hashable {
    let username: String
    let password: String
    let leaseID: String
    let expiresAt: Date

    init(lease: VaultDatabaseLease) throws {
        guard !lease.username.isEmpty, !lease.password.isEmpty, lease.leaseDuration > 0 else {
            throw VaultError.invalidResponse("Vault did not return usable MySQL credentials.")
        }
        self.username = lease.username
        self.password = lease.password
        self.leaseID = lease.leaseID
        self.expiresAt = lease.expiresAt
    }

    /// Build runtime config/secret values without modifying the saved connection record.
    func connectionInputs(for config: ConnectionConfig) -> (config: ConnectionConfig, secret: Secret) {
        var runtimeConfig = config
        runtimeConfig.username = username
        return (runtimeConfig, Secret(password: password))
    }
}

nonisolated enum VaultError: Error, Sendable, Equatable, LocalizedError {
    case invalidConfiguration(String)
    case invalidResponse(String)
    case unauthorized
    case requestFailed(statusCode: Int)
    case transport(String)
    case cancelled

    var isAuthenticationFailure: Bool {
        if case .unauthorized = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): "Vault configuration is invalid: \(message)"
        case .invalidResponse(let message): "Vault returned an invalid response: \(message)"
        case .unauthorized: "Vault authentication expired or was rejected. Sign in again."
        case .requestFailed(let statusCode): "Vault request failed (HTTP \(statusCode))."
        case .transport(let message): "Could not reach Vault: \(message)"
        case .cancelled: "The Vault authentication request was cancelled."
        }
    }
}

nonisolated protocol VaultTokenStore: Sendable {
    func token(for scope: VaultTokenScope) throws -> VaultToken?
    func save(_ token: VaultToken, for scope: VaultTokenScope) throws
    func removeToken(for scope: VaultTokenScope) throws
}

nonisolated protocol VaultOIDCAuthenticator: Sendable {
    func authenticate(configuration: VaultAuthenticationConfiguration) async throws -> VaultToken
}

/// Adapter for an ASWebAuthenticationSession/device-code flow, and for tests.
struct ClosureVaultOIDCAuthenticator: VaultOIDCAuthenticator {
    let handler: @Sendable (VaultAuthenticationConfiguration) async throws -> VaultToken

    init(handler: @escaping @Sendable (VaultAuthenticationConfiguration) async throws -> VaultToken) {
        self.handler = handler
    }

    func authenticate(configuration: VaultAuthenticationConfiguration) async throws -> VaultToken {
        try await handler(configuration)
    }
}

nonisolated protocol VaultCredentialAPI: Sendable {
    func readDatabaseCredentials(
        configuration: VaultAuthenticationConfiguration,
        token: VaultToken,
        now: Date
    ) async throws -> VaultDatabaseLease

    func renewLease(
        configuration: VaultAuthenticationConfiguration,
        token: VaultToken,
        leaseID: String,
        now: Date
    ) async throws -> VaultLeaseRefresh
}

nonisolated protocol VaultOIDCAuthAPI: Sendable {
    func authorizationRequest(
        configuration: VaultAuthenticationConfiguration,
        redirectURI: URL,
        clientNonce: String?
    ) async throws -> VaultOIDCAuthorizationRequest

    func exchangeCallback(
        configuration: VaultAuthenticationConfiguration,
        request: VaultOIDCAuthorizationRequest,
        callbackURL: URL,
        now: Date
    ) async throws -> VaultToken
}

/// Actor-owned runtime state for Vault OIDC/MySQL credentials. Only the Vault token is persisted;
/// leased usernames/passwords and lease state stay in memory.
actor VaultMySQLEphemeralCredentialProvider: Sendable {
    let configuration: VaultAuthenticationConfiguration
    private let authenticator: any VaultOIDCAuthenticator
    private let api: any VaultCredentialAPI
    private let tokenStore: any VaultTokenStore
    private var cachedToken: VaultToken?
    private var cachedLease: VaultDatabaseLease?

    init(
        configuration: VaultAuthenticationConfiguration,
        authenticator: any VaultOIDCAuthenticator,
        api: any VaultCredentialAPI,
        tokenStore: any VaultTokenStore = VaultTokenKeychainStore()
    ) throws {
        try configuration.validate()
        self.configuration = configuration
        self.authenticator = authenticator
        self.api = api
        self.tokenStore = tokenStore
    }

    /// Call before every initial connection and reconnect. Valid state is reused; expiring state
    /// is renewed or reissued. Cancellation is checked before every external operation.
    func credentials(now: Date = .now) async throws -> VaultMySQLCredentials {
        try Task.checkCancellation()
        let token = try await tokenForUse(now: now)
        do {
            let lease = try await leaseForUse(token: token, now: now)
            return try VaultMySQLCredentials(lease: lease)
        } catch let error as VaultError where error.isAuthenticationFailure {
            try clearToken()
            let freshToken = try await authenticateAndCache(now: now)
            let lease = try await api.readDatabaseCredentials(configuration: configuration, token: freshToken, now: now)
            cachedLease = lease
            return try VaultMySQLCredentials(lease: lease)
        }
    }

    func invalidate() throws {
        cachedToken = nil
        cachedLease = nil
        try tokenStore.removeToken(for: configuration.tokenScope)
    }

    private func tokenForUse(now: Date) async throws -> VaultToken {
        try Task.checkCancellation()
        if let cachedToken, cachedToken.isUsable(at: now, leeway: configuration.refreshLeeway) {
            return cachedToken
        }
        if let stored = try tokenStore.token(for: configuration.tokenScope) {
            if stored.isUsable(at: now, leeway: configuration.refreshLeeway) {
                cachedToken = stored
                return stored
            }
            try tokenStore.removeToken(for: configuration.tokenScope)
        }
        return try await authenticateAndCache(now: now)
    }

    private func authenticateAndCache(now: Date) async throws -> VaultToken {
        try Task.checkCancellation()
        do {
            let token = try await authenticator.authenticate(configuration: configuration)
            guard token.isUsable(at: now, leeway: 0) else {
                throw VaultError.invalidResponse("Vault authentication returned an empty token.")
            }
            try tokenStore.save(token, for: configuration.tokenScope)
            cachedToken = token
            return token
        } catch is CancellationError {
            throw VaultError.cancelled
        }
    }

    private func leaseForUse(token: VaultToken, now: Date) async throws -> VaultDatabaseLease {
        if let cachedLease, cachedLease.isUsable(at: now, leeway: configuration.refreshLeeway) {
            return cachedLease
        }
        if let cachedLease, cachedLease.renewable, cachedLease.expiresAt > now {
            let refresh = try await api.renewLease(
                configuration: configuration,
                token: token,
                leaseID: cachedLease.leaseID,
                now: now
            )
            let renewed = cachedLease.refreshed(with: refresh)
            self.cachedLease = renewed
            return renewed
        }
        let lease = try await api.readDatabaseCredentials(configuration: configuration, token: token, now: now)
        cachedLease = lease
        return lease
    }

    private func clearToken() throws {
        cachedToken = nil
        try tokenStore.removeToken(for: configuration.tokenScope)
    }
}
