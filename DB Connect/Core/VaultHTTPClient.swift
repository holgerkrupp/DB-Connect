import Foundation

nonisolated protocol VaultHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionVaultHTTPTransport: VaultHTTPTransport, Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// Vault database-secrets client. OIDC browser/device-code login is injected through
/// `VaultOIDCAuthenticator`; this client only exchanges the resulting token for credentials and
/// renews leases.
struct VaultHTTPClient: VaultCredentialAPI, VaultOIDCAuthAPI, Sendable {
    private let transport: any VaultHTTPTransport

    init(session: URLSession = .shared) {
        self.transport = URLSessionVaultHTTPTransport(session: session)
    }

    init(transport: any VaultHTTPTransport) {
        self.transport = transport
    }

    func authorizationRequest(
        configuration: VaultAuthenticationConfiguration,
        redirectURI: URL,
        clientNonce: String? = nil
    ) async throws -> VaultOIDCAuthorizationRequest {
        try configuration.validate()
        try Self.validateRedirectURI(redirectURI)
        let url = try endpoint(
            serverURL: configuration.serverURL,
            components: ["v1", "auth", configuration.authMount, "oidc", "auth_url"]
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        var payload: [String: String] = [
            "role": configuration.role,
            "redirect_uri": redirectURI.absoluteString
        ]
        if let clientNonce, !clientNonce.isEmpty { payload["client_nonce"] = clientNonce }
        request.httpBody = try JSONEncoder().encode(payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await send(request, token: nil)
        try validate(response)

        struct Payload: Decodable {
            struct DataFields: Decodable { let authURL: URL?
                enum CodingKeys: String, CodingKey { case authURL = "auth_url" }
            }
            let data: DataFields?
        }
        let payloadResponse = try decode(Payload.self, data: data)
        guard let authorizationURL = payloadResponse.data?.authURL,
              authorizationURL.scheme?.lowercased() == "https",
              authorizationURL.host != nil,
              authorizationURL.user == nil,
              authorizationURL.password == nil else {
            throw VaultError.invalidResponse("Vault did not return a secure OIDC authorization URL.")
        }
        guard let query = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems,
              let state = query.first(where: { $0.name == "state" })?.value,
              !state.isEmpty else {
            throw VaultError.invalidResponse("Vault OIDC authorization URL did not contain state.")
        }
        return VaultOIDCAuthorizationRequest(
            authorizationURL: authorizationURL,
            state: state,
            nonce: query.first(where: { $0.name == "nonce" })?.value,
            clientNonce: clientNonce,
            redirectURI: redirectURI
        )
    }

    func exchangeCallback(
        configuration: VaultAuthenticationConfiguration,
        request authorization: VaultOIDCAuthorizationRequest,
        callbackURL: URL,
        now: Date
    ) async throws -> VaultToken {
        try configuration.validate()
        guard callbackURL.scheme == authorization.redirectURI.scheme else {
            throw VaultError.invalidResponse("OIDC callback used an unexpected URL scheme.")
        }
        guard let query = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems,
              let state = query.first(where: { $0.name == "state" })?.value,
              state == authorization.state,
              let code = query.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else {
            throw VaultError.invalidResponse("OIDC callback state or code was missing or invalid.")
        }
        if let expectedNonce = authorization.nonce,
           query.first(where: { $0.name == "nonce" })?.value != expectedNonce {
            throw VaultError.invalidResponse("OIDC callback nonce was invalid.")
        }

        let url = try endpoint(
            serverURL: configuration.serverURL,
            components: ["v1", "auth", configuration.authMount, "oidc", "callback"]
        )
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code", value: code)
        ]
        if let nonce = query.first(where: { $0.name == "nonce" })?.value {
            items.append(URLQueryItem(name: "nonce", value: nonce))
        }
        if let clientNonce = authorization.clientNonce {
            items.append(URLQueryItem(name: "client_nonce", value: clientNonce))
        }
        components.queryItems = items
        var callbackRequest = URLRequest(url: components.url!)
        callbackRequest.httpMethod = "GET"
        let (data, response) = try await send(callbackRequest, token: nil)
        try validate(response)

        struct Payload: Decodable {
            struct Auth: Decodable {
                let clientToken: String?
                let leaseDuration: TimeInterval?
                let renewable: Bool?
                enum CodingKeys: String, CodingKey {
                    case clientToken = "client_token"
                    case leaseDuration = "lease_duration"
                    case renewable
                }
            }
            let auth: Auth?
        }
        let auth = try decode(Payload.self, data: data).auth
        guard let token = auth?.clientToken, !token.isEmpty else {
            throw VaultError.invalidResponse("Vault OIDC callback did not return a client token.")
        }
        let expiration = auth?.leaseDuration.map { now.addingTimeInterval($0) }
        return VaultToken(value: token, expiresAt: expiration, renewable: auth?.renewable ?? false)
    }

    func readDatabaseCredentials(
        configuration: VaultAuthenticationConfiguration,
        token: VaultToken,
        now: Date
    ) async throws -> VaultDatabaseLease {
        try configuration.validate()
        let url = try endpoint(
            serverURL: configuration.serverURL,
            components: ["v1", configuration.databaseMount, "creds", configuration.databaseRole]
        )
        let (data, response) = try await send(URLRequest(url: url), token: token.value)
        try validate(response)

        struct Payload: Decodable {
            struct DataFields: Decodable {
                let username: String?
                let password: String?
            }
            let leaseID: String?
            let leaseDuration: TimeInterval?
            let renewable: Bool?
            let data: DataFields?
            enum CodingKeys: String, CodingKey {
                case leaseID = "lease_id"
                case leaseDuration = "lease_duration"
                case renewable
                case data
            }
        }

        let payload = try decode(Payload.self, data: data)
        guard let leaseID = payload.leaseID,
              let duration = payload.leaseDuration,
              duration > 0,
              let username = payload.data?.username,
              let password = payload.data?.password,
              !username.isEmpty,
              !password.isEmpty else {
            throw VaultError.invalidResponse("The database credentials response was incomplete.")
        }
        return VaultDatabaseLease(
            leaseID: leaseID,
            username: username,
            password: password,
            leaseDuration: duration,
            renewable: payload.renewable ?? false,
            issuedAt: now
        )
    }

    func renewLease(
        configuration: VaultAuthenticationConfiguration,
        token: VaultToken,
        leaseID: String,
        now: Date
    ) async throws -> VaultLeaseRefresh {
        try configuration.validate()
        guard !leaseID.isEmpty else {
            throw VaultError.invalidConfiguration("A Vault lease ID is required for renewal.")
        }
        let url = try endpoint(serverURL: configuration.serverURL, components: ["v1", "sys", "leases", "renew"])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(["lease_id": leaseID])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await send(request, token: token.value)
        try validate(response)

        struct Payload: Decodable {
            let leaseID: String?
            let leaseDuration: TimeInterval?
            let renewable: Bool?
            enum CodingKeys: String, CodingKey {
                case leaseID = "lease_id"
                case leaseDuration = "lease_duration"
                case renewable
            }
        }
        let payload = try decode(Payload.self, data: data)
        guard let renewedID = payload.leaseID,
              let duration = payload.leaseDuration,
              duration > 0 else {
            throw VaultError.invalidResponse("The lease renewal response was incomplete.")
        }
        return VaultLeaseRefresh(
            leaseID: renewedID,
            leaseDuration: duration,
            renewable: payload.renewable ?? false,
            issuedAt: now
        )
    }

    private func send(_ request: URLRequest, token: String?) async throws -> (Data, HTTPURLResponse) {
        var request = request
        if let token { request.setValue(token, forHTTPHeaderField: "X-Vault-Token") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            try Task.checkCancellation()
            let (data, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw VaultError.transport("Vault returned a non-HTTP response.")
            }
            return (data, http)
        } catch is CancellationError {
            throw VaultError.cancelled
        } catch let error as VaultError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw VaultError.cancelled
        } catch {
            throw VaultError.transport(error.localizedDescription)
        }
    }

    private func validate(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200 ..< 300:
            return
        case 401, 403:
            throw VaultError.unauthorized
        default:
            throw VaultError.requestFailed(statusCode: response.statusCode)
        }
    }

    private func endpoint(serverURL: URL, components: [String]) throws -> URL {
        guard serverURL.scheme?.lowercased() == "https", serverURL.host != nil else {
            throw VaultError.invalidConfiguration("Vault requests require an HTTPS server URL.")
        }
        var url = serverURL
        for component in components {
            guard !component.isEmpty, component != ".", component != ".." else {
                throw VaultError.invalidConfiguration("Vault request path contains an invalid component.")
            }
            url.append(path: component)
        }
        return url
    }

    private static func validateRedirectURI(_ url: URL) throws {
        guard let scheme = url.scheme, !scheme.isEmpty,
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else {
            throw VaultError.invalidConfiguration("OIDC redirect URI must have a scheme and no credentials, query, or fragment.")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw VaultError.invalidResponse("Vault returned malformed JSON.")
        }
    }
}
