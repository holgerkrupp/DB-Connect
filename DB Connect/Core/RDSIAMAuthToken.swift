import CryptoKit
import Foundation

nonisolated enum RDSIAMAuthTokenGenerator {
    private static let iso8601Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    private static let datestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    static func makeToken(
        host: String,
        port: Int,
        username: String,
        region: String,
        credentials: AWSCredentials,
        now: Date = .now
    ) throws -> String {
        let timestamp = iso8601Formatter.string(from: now)
        let datestamp = datestampFormatter.string(from: now)
        let service = "rds-db"
        let scope = "\(datestamp)/\(region)/\(service)/aws4_request"

        var queryItems = [
            ("Action", "connect"),
            ("DBUser", username),
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", "\(credentials.accessKeyID)/\(scope)"),
            ("X-Amz-Date", timestamp),
            ("X-Amz-Expires", "900"),
            ("X-Amz-SignedHeaders", "host")
        ]
        if let sessionToken = credentials.sessionToken, !sessionToken.isEmpty {
            queryItems.append(("X-Amz-Security-Token", sessionToken))
        }

        let canonicalQuery = canonicalQueryString(from: queryItems)
        let canonicalRequest = [
            "GET",
            "/",
            canonicalQuery,
            "host:\(host):\(port)",
            "",
            "host",
            "UNSIGNED-PAYLOAD"
        ].joined(separator: "\n")

        let stringToSign = [
            "AWS4-HMAC-SHA256",
            timestamp,
            scope,
            hexString(SHA256.hash(data: Data(canonicalRequest.utf8)))
        ].joined(separator: "\n")

        let signingKey = signatureKey(
            secretAccessKey: credentials.secretAccessKey,
            dateStamp: datestamp,
            region: region,
            service: service
        )
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(stringToSign.utf8),
            using: SymmetricKey(data: signingKey)
        )

        return "\(host):\(port)/?\(canonicalQuery)&X-Amz-Signature=\(hexString(signature))"
    }

    private static func canonicalQueryString(from items: [(String, String)]) -> String {
        let pairs = items.map { item in
            (percentEncode(item.0), percentEncode(item.1))
        }
        let sorted = pairs.sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
        }
        return sorted.map { key, value in
            "\(key)=\(value)"
        }.joined(separator: "&")
    }

    private static func percentEncode(_ value: String) -> String {
        let allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        return value.unicodeScalars.map { scalar in
            if allowed.unicodeScalars.contains(scalar) {
                return String(scalar)
            }
            return String(format: "%%%02X", scalar.value)
        }.joined()
    }

    private static func signatureKey(
        secretAccessKey: String,
        dateStamp: String,
        region: String,
        service: String
    ) -> Data {
        let key = Data(("AWS4" + secretAccessKey).utf8)
        let dateKey = hmac(data: Data(dateStamp.utf8), key: key)
        let regionKey = hmac(data: Data(region.utf8), key: dateKey)
        let serviceKey = hmac(data: Data(service.utf8), key: regionKey)
        return hmac(data: Data("aws4_request".utf8), key: serviceKey)
    }

    private static func hmac(data: Data, key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private static func hexString<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
