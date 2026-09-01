#if os(macOS)
import Darwin
import Foundation

/// Reuses the user's OpenSSH trust configuration instead of shipping a second SSH stack with its
/// own host-key store. Unknown hosts therefore fail closed until the user trusts them explicitly
/// outside the app, which matches DB Connect's "safe by default" direction.
final class OpenSSHTunnel: @unchecked Sendable {
    let localPort: Int

    private let process: Process
    private let temporaryDirectory: URL
    private let stderrPipe = Pipe()

    init(
        configuration: SSHTunnelConfiguration,
        remoteHost: String,
        remotePort: Int,
        secret: Secret?
    ) throws {
        guard !configuration.host.isEmpty else {
            throw DatabaseError.unsupported("SSH tunnelling needs an SSH host.")
        }
        guard !configuration.username.isEmpty else {
            throw DatabaseError.unsupported("SSH tunnelling needs an SSH username.")
        }

        let localPort = try Self.reserveLocalPort()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DBConnect-SSH-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.standardError = stderrPipe
        process.standardOutput = Pipe()
        process.standardInput = Pipe()

        var arguments = [
            "-N",
            "-T",
            "-L", "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "RequestTTY=no",
            "-p", "\(configuration.port)",
            "-l", configuration.username
        ]

        var environment = ProcessInfo.processInfo.environment
        let askPassURL = temporaryDirectory.appendingPathComponent("askpass.sh")

        switch configuration.authenticationMode {
        case .agent:
            arguments.append(contentsOf: [
                "-o", "BatchMode=yes",
                "-o", "PreferredAuthentications=publickey"
            ])
        case .password:
            guard let sshPassword = secret?.sshPassword, !sshPassword.isEmpty else {
                throw DatabaseError.missingCredentials
            }
            try Self.writeAskPassScript(to: askPassURL)
            environment["SSH_ASKPASS"] = askPassURL.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = "DBConnect"
            environment["DBCONNECT_SSH_SECRET"] = sshPassword
            arguments.append(contentsOf: [
                "-o", "BatchMode=no",
                "-o", "PreferredAuthentications=password,keyboard-interactive"
            ])
        case .privateKey:
            guard let privateKey = secret?.sshPrivateKey, !privateKey.isEmpty else {
                throw DatabaseError.missingCredentials
            }
            let keyURL = temporaryDirectory.appendingPathComponent("id_dbconnect")
            try privateKey.write(to: keyURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
            arguments.append(contentsOf: [
                "-i", keyURL.path,
                "-o", "IdentitiesOnly=yes",
                "-o", "PreferredAuthentications=publickey"
            ])

            if let passphrase = secret?.sshPassphrase, !passphrase.isEmpty {
                try Self.writeAskPassScript(to: askPassURL)
                environment["SSH_ASKPASS"] = askPassURL.path
                environment["SSH_ASKPASS_REQUIRE"] = "force"
                environment["DISPLAY"] = "DBConnect"
                environment["DBCONNECT_SSH_SECRET"] = passphrase
                arguments.append(contentsOf: ["-o", "BatchMode=no"])
            } else {
                arguments.append(contentsOf: ["-o", "BatchMode=yes"])
            }
        }

        arguments.append(configuration.host)
        process.arguments = arguments
        process.environment = environment

        try process.run()

        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if !process.isRunning {
                throw DatabaseError.connectionFailed(Self.readFailure(from: stderrPipe))
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        self.localPort = localPort
        self.temporaryDirectory = temporaryDirectory
        self.process = process
    }

    func close() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
    private static func writeAskPassScript(to url: URL) throws {
        let script = """
        #!/bin/sh
        printf '%s\\n' "$DBCONNECT_SSH_SECRET"
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func readFailure(from pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text! : "Could not establish the SSH tunnel."
    }

    private static func reserveLocalPort() throws -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw DatabaseError.connectionFailed("Could not reserve a local port for the SSH tunnel.")
        }
        defer { Darwin.close(socketFD) }

        var value: Int32 = 1
        _ = withUnsafePointer(to: &value) {
            setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw DatabaseError.connectionFailed("Could not reserve a local port for the SSH tunnel.")
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard nameResult == 0 else {
            throw DatabaseError.connectionFailed("Could not reserve a local port for the SSH tunnel.")
        }

        return Int(UInt16(bigEndian: assigned.sin_port))
    }
}
#endif

#if !os(macOS)
final class OpenSSHTunnel: @unchecked Sendable {
    let localPort: Int = 0

    init(
        configuration: SSHTunnelConfiguration,
        remoteHost: String,
        remotePort: Int,
        secret: Secret?
    ) throws {
        throw DatabaseError.unsupported("SSH tunnelling is currently available on macOS.")
    }

    func close() {}
}
#endif
