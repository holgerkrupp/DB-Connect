import Foundation
import NIOSSL
import Crypto

/// Certificate pinning for database connections.
///
/// The design here is deliberate. An earlier version of this app offered a "pinned" TLS mode
/// backed only by a fingerprint string — but neither PostgresNIO nor MySQLNIO exposes a custom
/// verification callback, so the fingerprint could never actually be checked during the
/// handshake. Rather than claim a protection that was not being enforced, pinning now works by
/// importing the server's certificate and using it as the *only* trust root:
///
/// - BoringSSL enforces it during the handshake, not us afterwards.
/// - It works with self-signed certificates, which is the case that needs it.
/// - The fingerprint is still computed, but for the user to compare out-of-band — it is a
///   verification aid, not the mechanism.
nonisolated enum CertificatePinning {

    enum PinningError: Error, LocalizedError {
        case invalidCertificate(String)

        var errorDescription: String? {
            switch self {
            case .invalidCertificate(let detail): "The certificate could not be read: \(detail)"
            }
        }
    }

    /// Parse a PEM (or DER) certificate supplied by the user.
    static func certificate(fromPEM pem: String) throws -> NIOSSLCertificate {
        let bytes = Array(pem.utf8)
        if let certificate = try? NIOSSLCertificate(bytes: bytes, format: .pem) {
            return certificate
        }
        if let certificate = try? NIOSSLCertificate(bytes: bytes, format: .der) {
            return certificate
        }
        throw PinningError.invalidCertificate("Expected a PEM or DER encoded X.509 certificate.")
    }

    /// SHA-256 of the DER encoding — the same value `openssl x509 -fingerprint -sha256` prints,
    /// so the user can compare it with what their server administrator quotes.
    static func fingerprint(of certificate: NIOSSLCertificate) throws -> String {
        let der = try certificate.toDERBytes()
        let digest = SHA256.hash(data: Data(der))
        return digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    static func fingerprint(fromPEM pem: String) throws -> String {
        try fingerprint(of: certificate(fromPEM: pem))
    }

    /// A TLS configuration that trusts *only* the supplied certificate.
    ///
    /// Hostname verification is relaxed because pinned certificates are typically self-signed
    /// with a CN that does not match how the user reaches the host. The chain check against the
    /// pinned certificate is what provides the security here, and it remains fully enforced.
    static func tlsConfiguration(pinnedTo pem: String) throws -> TLSConfiguration {
        let certificate = try certificate(fromPEM: pem)
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.trustRoots = .certificates([certificate])
        configuration.certificateVerification = .noHostnameVerification
        return configuration
    }
}
