import Foundation
import NIOCore

enum PreparedServerEndpoint {
    case tcp(address: SocketAddress, serverHostname: String?, tunnel: OpenSSHTunnel?)
    case unixSocket(path: String)
}

nonisolated enum ServerEndpointResolver {
    static func resolve(
        config: ConnectionConfig,
        secret: Secret?
    ) async throws -> PreparedServerEndpoint {
        if !config.socketPath.isEmpty {
            return .unixSocket(path: config.socketPath)
        }

        let port = resolvedPort(for: config)
        if let ssh = config.sshTunnel {
            #if os(macOS)
            let tunnel = try await MainActor.run {
                try OpenSSHTunnel(
                    configuration: ssh,
                    remoteHost: config.host,
                    remotePort: port,
                    secret: secret
                )
            }
            let address = try SocketAddress(ipAddress: "127.0.0.1", port: tunnel.localPort)
            return .tcp(address: address, serverHostname: config.host, tunnel: tunnel)
            #else
            throw DatabaseError.unsupported("SSH tunnelling is currently available on macOS.")
            #endif
        }

        do {
            let address = try SocketAddress.makeAddressResolvingHost(config.host, port: port)
            return .tcp(address: address, serverHostname: config.host, tunnel: nil)
        } catch {
            throw DatabaseError.connectionFailed("Could not resolve “\(config.host)”.")
        }
    }

    static func resolvedPort(for config: ConnectionConfig) -> Int {
        if config.port != 0 { return config.port }
        switch config.driverID {
        case DriverIdentity.mysql: return DriverIdentity.mysqlPort
        case DriverIdentity.postgres: return DriverIdentity.postgresPort
        default: return 0
        }
    }
}
