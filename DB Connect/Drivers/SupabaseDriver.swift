import Foundation

/// Supabase / PostgREST over HTTP.
///
/// This driver exists to keep the abstraction honest: it has no SQL, no transactions and no
/// cursor, so anything in the app that silently assumed "database == SQL" breaks here first.
/// `capabilities.canRunArbitrarySQL` is false and the UI hides the console accordingly.
nonisolated struct SupabaseDriver: DatabaseDriver {
    static let id = "supabase"
    static let displayName = "Supabase"

    let capabilities = DriverCapabilities(
        canEditRows: true,
        canRunArbitrarySQL: false,
        supportsTransactions: false,
        supportsSchemas: false,
        requiresCredentials: true
    )

    func connect(config: ConnectionConfig, secret: Secret?) async throws -> any DatabaseSession {
        guard let apiKey = secret?.apiToken ?? secret?.password, !apiKey.isEmpty else {
            throw DatabaseError.missingCredentials
        }
        guard let baseURL = Self.restURL(from: config.host) else {
            throw DatabaseError.connectionFailed("“\(config.host)” is not a valid Supabase project URL.")
        }
        return try await SupabaseSession(baseURL: baseURL, apiKey: apiKey, capabilities: capabilities)
    }

    /// Accepts either the bare project URL or one that already ends in `/rest/v1`.
    static func restURL(from host: String) -> URL? {
        var text = host.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var url = URL(string: text), url.host() != nil else { return nil }
        if !url.path().contains("/rest/v1") {
            url = url.appending(path: "rest/v1")
        }
        return url
    }
}

actor SupabaseSession: DatabaseSession {
    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession
    private var cachedTables: [TableDescriptor]?
    nonisolated let capabilities: DriverCapabilities

    init(baseURL: URL, apiKey: String, capabilities: DriverCapabilities) async throws {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.capabilities = capabilities

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: configuration)

        // Fail fast on a bad key or URL, so the UI reports it at connect time like a real driver.
        _ = try await loadSchema()
    }

    func close() {
        session.invalidateAndCancel()
    }

    // MARK: - Introspection

    func tables() async throws -> [TableDescriptor] {
        if let cachedTables { return cachedTables }
        let loaded = try await loadSchema()
        cachedTables = loaded
        return loaded
    }

    func describe(table: String, schema: String?) async throws -> TableDescriptor {
        guard let match = try await tables().first(where: { $0.name == table }) else {
            throw DatabaseError.tableNotFound(table)
        }
        return match
    }

    /// PostgREST serves an OpenAPI 2 document at the API root describing every exposed table.
    private func loadSchema() async throws -> [TableDescriptor] {
        let (data, response) = try await send(request(for: baseURL))
        try Self.validate(response, data: data)

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let definitions = root["definitions"] as? [String: Any] else {
            throw DatabaseError.connectionFailed("The server did not return a PostgREST schema.")
        }

        return definitions.compactMap { name, value -> TableDescriptor? in
            guard let definition = value as? [String: Any],
                  let properties = definition["properties"] as? [String: Any] else { return nil }
            let required = Set(definition["required"] as? [String] ?? [])

            let columns = properties.compactMap { columnName, columnValue -> ColumnDescriptor? in
                guard let property = columnValue as? [String: Any] else { return nil }
                let format = property["format"] as? String ?? property["type"] as? String ?? ""
                let description = property["description"] as? String ?? ""

                return ColumnDescriptor(
                    name: columnName,
                    declaredType: format,
                    isNullable: !required.contains(columnName),
                    // PostgREST flags keys in the property description; there is no other
                    // machine-readable marker in the OpenAPI output.
                    isPrimaryKey: description.contains("<pk/>"),
                    defaultValue: property["default"].map { String(describing: $0) }
                )
            }
            .sorted { $0.name < $1.name }

            return TableDescriptor(name: name, schema: nil, kind: .table, columns: columns)
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: - Reading

    func fetch(_ rowRequest: RowRequest) async throws -> ResultSet {
        let descriptor = try await describe(table: rowRequest.table, schema: nil)
        let known = Set(descriptor.columns.map(\.name))

        var components = URLComponents(
            url: baseURL.appending(path: rowRequest.table),
            resolvingAgainstBaseURL: false
        )
        var items: [URLQueryItem] = [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "limit", value: String(rowRequest.limit + 1)),
            URLQueryItem(name: "offset", value: String(rowRequest.offset))
        ]

        if !rowRequest.sort.isEmpty {
            let terms = try rowRequest.sort.map { sort -> String in
                guard known.contains(sort.column) else {
                    throw DatabaseError.invalidIdentifier("Unknown column “\(sort.column)”.")
                }
                return "\(sort.column).\(sort.ascending ? "asc" : "desc")"
            }
            items.append(URLQueryItem(name: "order", value: terms.joined(separator: ",")))
        }

        // PostgREST expresses filters as query parameters rather than SQL: each column filter
        // becomes `column=op.value`, and free-text search becomes a single `or=(...)` group.
        for filter in rowRequest.filters where filter.isReady {
            guard known.contains(filter.column) else {
                throw DatabaseError.invalidIdentifier("Unknown column “\(filter.column)”.")
            }
            items.append(URLQueryItem(name: filter.column, value: try Self.postgrest(filter)))
        }

        if let search = rowRequest.search?.trimmingCharacters(in: .whitespaces), !search.isEmpty {
            let searchable = descriptor.columns.filter(\.isSearchable)
            if !searchable.isEmpty {
                let escaped = Self.escapeForPostgREST(search)
                let alternatives = searchable.map { "\($0.name).ilike.*\(escaped)*" }
                items.append(URLQueryItem(name: "or", value: "(\(alternatives.joined(separator: ",")))"))
            }
        }

        components?.queryItems = items

        guard let url = components?.url else {
            throw DatabaseError.queryFailed(sql: rowRequest.table, message: "Could not build the request URL.")
        }

        let clock = ContinuousClock()
        let start = clock.now
        let (data, response) = try await send(self.request(for: url))
        try Self.validate(response, data: data)

        guard let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DatabaseError.queryFailed(sql: rowRequest.table, message: "Unexpected response shape.")
        }

        let hasMore = objects.count > rowRequest.limit
        let page = hasMore ? Array(objects.prefix(rowRequest.limit)) : objects
        let rows = page.map { object in
            descriptor.columns.map { Self.value(from: object[$0.name]) }
        }

        return ResultSet(columns: descriptor.columns, rows: rows, hasMore: hasMore, elapsed: clock.now - start)
    }

    func query(_ statement: Statement) async throws -> ResultSet {
        throw DatabaseError.unsupported("Supabase connections do not support raw SQL. Browse tables instead.")
    }

    func execute(_ statement: Statement) async throws -> ExecutionResult {
        throw DatabaseError.unsupported("Supabase connections do not support raw SQL.")
    }

    // MARK: - Editing

    nonisolated func preview(_ mutations: [RowMutation], to table: TableDescriptor) throws -> [String] {
        try mutations.map { mutation in
            if let reason = table.readOnlyReason {
                throw DatabaseError.readOnly(reason: reason)
            }
            switch mutation.kind {
            case .insert:
                return "POST /\(table.name)\n   ⤷ \(Self.describe(mutation.values))"
            case .update:
                return "PATCH /\(table.name)?\(try Self.filter(for: mutation))\n   ⤷ \(Self.describe(mutation.values))"
            case .delete:
                return "DELETE /\(table.name)?\(try Self.filter(for: mutation))"
            }
        }
    }

    /// PostgREST has no client-side transaction, so this applies mutations one request at a
    /// time. A failure part-way leaves earlier changes committed — the UI warns about this
    /// before the user confirms, because pretending otherwise would be a lie about durability.
    func apply(_ mutations: [RowMutation], to table: TableDescriptor) async throws -> ExecutionResult {
        if let reason = table.readOnlyReason {
            throw DatabaseError.readOnly(reason: reason)
        }

        let clock = ContinuousClock()
        let start = clock.now
        var applied = 0

        for mutation in mutations {
            var components = URLComponents(
                url: baseURL.appending(path: table.name),
                resolvingAgainstBaseURL: false
            )
            if mutation.kind != .insert {
                components?.percentEncodedQuery = try Self.filter(for: mutation)
            }
            guard let url = components?.url else {
                throw DatabaseError.queryFailed(sql: table.name, message: "Could not build the request URL.")
            }

            var urlRequest = request(for: url)
            switch mutation.kind {
            case .insert:
                urlRequest.httpMethod = "POST"
            case .update:
                urlRequest.httpMethod = "PATCH"
            case .delete:
                urlRequest.httpMethod = "DELETE"
            }

            if mutation.kind != .delete {
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                urlRequest.httpBody = try JSONSerialization.data(
                    withJSONObject: Self.jsonObject(from: mutation.values)
                )
            }

            let (data, response) = try await send(urlRequest)
            do {
                try Self.validate(response, data: data)
            } catch {
                throw DatabaseError.queryFailed(
                    sql: "\(mutation.kind.rawValue) \(table.name)",
                    message: "\(error.localizedDescription) (\(applied) change\(applied == 1 ? "" : "s") already applied)"
                )
            }
            applied += 1
        }

        return ExecutionResult(affectedRows: applied, lastInsertID: nil, elapsed: clock.now - start)
    }

    /// Translate a column filter into PostgREST's `op.value` syntax.
    private static func postgrest(_ filter: ColumnFilter) throws -> String {
        let value = escapeForPostgREST(filter.value)
        return switch filter.op {
        case .equals: "eq.\(value)"
        case .notEquals: "neq.\(value)"
        case .greaterThan: "gt.\(value)"
        case .greaterOrEqual: "gte.\(value)"
        case .lessThan: "lt.\(value)"
        case .lessOrEqual: "lte.\(value)"
        case .contains: "ilike.*\(value)*"
        case .notContains: "not.ilike.*\(value)*"
        case .startsWith: "ilike.\(value)*"
        case .endsWith: "ilike.*\(value)"
        case .isNull: "is.null"
        case .isNotNull: "not.is.null"
        }
    }

    /// PostgREST treats `*` as its wildcard and uses `,` and `)` as syntax, so those must not
    /// arrive raw from a search box.
    private static func escapeForPostgREST(_ text: String) -> String {
        text
            .replacingOccurrences(of: "*", with: "%2A")
            .replacingOccurrences(of: ",", with: "%2C")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
    }

    /// PostgREST row filter, e.g. `id=eq.42`.
    private static func filter(for mutation: RowMutation) throws -> String {
        guard !mutation.primaryKey.isEmpty else {
            throw DatabaseError.readOnly(reason: "This row has no primary key, so it cannot be changed safely.")
        }
        return try mutation.primaryKey.sorted { $0.key < $1.key }.map { column, value in
            guard !value.isNull else {
                throw DatabaseError.readOnly(reason: "The row's key column “\(column)” is NULL, so it cannot be identified.")
            }
            let encoded = value.displayText
                .addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value.displayText
            return "\(column)=eq.\(encoded)"
        }
        .joined(separator: "&")
    }

    private static func jsonObject(from values: [String: SQLValue]) -> [String: Any] {
        values.mapValues { value -> Any in
            switch value {
            case .null: NSNull()
            case .bool(let v): v
            case .integer(let v): v
            case .double(let v): v
            case .text(let v): v
            case .date(let v): ISO8601DateFormatter().string(from: v)
            case .blob(let d): d.base64EncodedString()
            }
        }
    }

    private static func describe(_ values: [String: SQLValue]) -> String {
        values.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.displayText)" }
            .joined(separator: ", ")
    }

    // MARK: - Plumbing

    private func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw DatabaseError.connectionFailed(error.localizedDescription)
        }
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            // PostgREST returns a JSON body with a useful message; prefer it over the status code.
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0?["message"] as? String }

            switch http.statusCode {
            case 401, 403:
                throw DatabaseError.connectionFailed(detail ?? "The API key was rejected.")
            default:
                throw DatabaseError.queryFailed(
                    sql: "",
                    message: detail ?? "The server returned status \(http.statusCode)."
                )
            }
        }
    }

    static func value(from json: Any?) -> SQLValue {
        switch json {
        case nil, is NSNull:
            return .null
        case let bool as Bool:
            return .bool(bool)
        case let number as NSNumber:
            // NSNumber erases Bool; check the ObjC type encoding before treating it as numeric.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if String(cString: number.objCType) == "d" || String(cString: number.objCType) == "f" {
                return .double(number.doubleValue)
            }
            return .integer(number.int64Value)
        case let string as String:
            return .text(string)
        default:
            // Nested JSON objects and arrays keep their JSON form rather than being flattened.
            if let data = try? JSONSerialization.data(withJSONObject: json as Any),
               let text = String(data: data, encoding: .utf8) {
                return .text(text)
            }
            return .null
        }
    }
}
