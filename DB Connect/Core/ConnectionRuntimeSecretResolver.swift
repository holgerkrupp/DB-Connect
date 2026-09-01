import Foundation

nonisolated struct AWSCredentials: Sendable, Hashable {
    var accessKeyID: String
    var secretAccessKey: String
    var sessionToken: String?
}

nonisolated enum DriverIdentity {
    static let mysql = "mysql"
    static let postgres = "postgres"
    static let mysqlPort = 3306
    static let postgresPort = 5432
}

nonisolated enum ConnectionRuntimeSecretResolver {
    static func resolve(
        config: ConnectionConfig,
        secret: Secret?,
        now: Date = .now
    ) throws -> Secret? {
        switch config.authentication.mode {
        case .password:
            return secret
        case .awsIAM:
            guard config.driverID == DriverIdentity.mysql else {
                throw DatabaseError.unsupported("AWS IAM authentication is currently available only for MySQL connections.")
            }
            guard config.socketPath.isEmpty else {
                throw DatabaseError.unsupported("AWS IAM authentication is not available for local socket connections.")
            }

            let region = config.authentication.awsRegion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !region.isEmpty else {
                throw DatabaseError.unsupported("AWS IAM authentication needs an AWS region.")
            }

            guard let accessKeyID = secret?.awsAccessKeyID, !accessKeyID.isEmpty,
                  let secretAccessKey = secret?.awsSecretAccessKey, !secretAccessKey.isEmpty else {
                throw DatabaseError.missingCredentials
            }

            let credentials = AWSCredentials(
                accessKeyID: accessKeyID,
                secretAccessKey: secretAccessKey,
                sessionToken: secret?.awsSessionToken
            )
            let token = try RDSIAMAuthTokenGenerator.makeToken(
                host: config.host,
                port: config.port == 0 ? DriverIdentity.mysqlPort : config.port,
                username: config.username,
                region: region,
                credentials: credentials,
                now: now
            )

            var resolved = secret ?? Secret()
            resolved.password = token
            return resolved
        }
    }
}
