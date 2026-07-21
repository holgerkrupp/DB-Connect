import Foundation

// MARK: - Transfer configuration

nonisolated enum TransferFormat: String, Sendable, CaseIterable, Identifiable {
    case sql = "SQL"
    case csv = "CSV"

    var id: String { rawValue }
}

nonisolated struct SQLExportOptions: Sendable, Hashable {
    var includeStructure = true
    var includeContent = true
    var includeDropStatements = true
    var includeAutoIncrementValue = false
    var useTransaction = true
    var disableForeignKeyChecks = true
    var blobAsHex = true
    var includeGeneratedColumns = false
    var rowsPerInsert = 250
    var addUTF8BOM = false
}

nonisolated struct SQLExportTable: Sendable, Hashable, Identifiable {
    let table: TableDescriptor
    var includeStructure: Bool
    var includeContent: Bool
    var includeDropStatement: Bool

    var id: String { table.id }

    init(
        table: TableDescriptor,
        includeStructure: Bool = true,
        includeContent: Bool = true,
        includeDropStatement: Bool = true
    ) {
        self.table = table
        self.includeStructure = includeStructure
        self.includeContent = includeContent && table.kind == .table
        self.includeDropStatement = includeDropStatement
    }

    var isIncluded: Bool { includeStructure || includeContent || includeDropStatement }
}

nonisolated struct CSVOptions: Sendable, Hashable {
    enum LineEnding: String, Sendable, CaseIterable, Identifiable {
        case lf = "LF (Unix/macOS)"
        case crlf = "CRLF (Windows)"

        var id: String { rawValue }
        var value: String { self == .lf ? "\n" : "\r\n" }
    }

    var delimiter: Character = ","
    var quote: Character = "\""
    var includeHeader = true
    var nullValue = "NULL"
    var lineEnding: LineEnding = .lf
    var addUTF8BOM = false
}

nonisolated struct SQLImportOptions: Sendable, Hashable {
    var stopOnError = true
    var wrapInTransaction = false
}

nonisolated enum CSVConflictStrategy: String, Sendable, CaseIterable, Identifiable {
    case fail = "Stop on duplicate"
    case ignore = "Skip duplicates"
    case replace = "Update duplicates"

    var id: String { rawValue }
}

nonisolated struct CSVImportOptions: Sendable, Hashable {
    var firstRowIsHeader = true
    var nullValue = "NULL"
    var emptyValuesAreNull = false
    var conflictStrategy: CSVConflictStrategy = .fail
    var useTransaction = true
}

nonisolated struct ImportFailure: Sendable, Hashable, Identifiable {
    let id: Int
    let statement: String
    let message: String
}

nonisolated struct ImportSummary: Sendable, Hashable {
    let completed: Int
    let failures: [ImportFailure]

    var message: String {
        if failures.isEmpty {
            return "Imported \(completed.formatted()) item\(completed == 1 ? "" : "s")."
        }
        return "Imported \(completed.formatted()) item\(completed == 1 ? "" : "s") with \(failures.count.formatted()) error\(failures.count == 1 ? "" : "s")."
    }
}

nonisolated enum DataTransferError: Error, LocalizedError {
    case noTables
    case noContent
    case invalidCSV(String)
    case invalidMapping(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .noTables: "Select at least one table."
        case .noContent: "The selected file is empty."
        case .invalidCSV(let detail): "Could not read the CSV file: \(detail)"
        case .invalidMapping(let detail): detail
        case .unsupported(let detail): detail
        }
    }
}

// MARK: - CSV parsing

/// A small RFC 4180 parser used for both the preview and the import. It accepts CRLF, LF and CR
/// line endings, quoted line breaks, doubled quote characters, and rows with missing trailing
/// fields. Keeping it here makes import behavior independent from the UI and easy to exercise.
nonisolated struct ParsedCSV: Sendable, Hashable {
    let rows: [[String]]

    var columnCount: Int { rows.map(\.count).max() ?? 0 }

    func headers(firstRowIsHeader: Bool) -> [String] {
        guard columnCount > 0 else { return [] }
        if firstRowIsHeader, let first = rows.first {
            return (0..<columnCount).map { index in
                let candidate = first.indices.contains(index)
                    ? first[index].trimmingCharacters(in: .whitespacesAndNewlines)
                    : ""
                return candidate.isEmpty ? "Column \(index + 1)" : candidate
            }
        }
        return (1...columnCount).map { "Column \($0)" }
    }

    func dataRows(firstRowIsHeader: Bool) -> ArraySlice<[String]> {
        rows.dropFirst(firstRowIsHeader && !rows.isEmpty ? 1 : 0)
    }
}

nonisolated enum CSVCodec {
    static func detectedDelimiter(in text: String) -> Character {
        let sample = String(text.prefix(16_384))
        let candidates: [Character] = [",", ";", "\t", "|"]
        return candidates.max { lhs, rhs in
            let left = (try? parse(sample, delimiter: lhs).columnCount) ?? 0
            let right = (try? parse(sample, delimiter: rhs).columnCount) ?? 0
            return left < right
        } ?? ","
    }

    static func parse(_ text: String, delimiter: Character = ",", quote: Character = "\"") throws -> ParsedCSV {
        guard !text.isEmpty else { throw DataTransferError.noContent }

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.drop(while: { $0 == "\u{FEFF}" }).makeIterator()
        var pending: Character?

        func finishField() {
            row.append(field)
            field.removeAll(keepingCapacity: true)
        }
        func finishRow() {
            finishField()
            rows.append(row)
            row.removeAll(keepingCapacity: true)
        }

        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == quote {
                    if let next = iterator.next() {
                        if next == quote {
                            field.append(quote)
                        } else {
                            inQuotes = false
                            pending = next
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }

            switch character {
            case delimiter:
                finishField()
            case quote where field.isEmpty:
                inQuotes = true
            case "\r":
                // Consume the LF half of CRLF, but leave any other next character for the loop.
                if let next = iterator.next(), next != "\n" { pending = next }
                finishRow()
            case "\n":
                finishRow()
            default:
                field.append(character)
            }
        }

        guard !inQuotes else {
            throw DataTransferError.invalidCSV("The last quoted field is not closed.")
        }
        if !field.isEmpty || !row.isEmpty {
            finishRow()
        }
        return ParsedCSV(rows: rows)
    }

    static func encode(_ fields: [String], options: CSVOptions) -> String {
        fields.map { field in
            let needsQuotes = field.contains(options.delimiter)
                || field.contains(options.quote)
                || field.contains("\n")
                || field.contains("\r")
                || field.first?.isWhitespace == true
                || field.last?.isWhitespace == true
            guard needsQuotes else { return field }
            let quote = String(options.quote)
            return quote + field.replacingOccurrences(of: quote, with: quote + quote) + quote
        }.joined(separator: String(options.delimiter))
    }
}

// MARK: - SQL script splitting

/// Splits a dump into executable statements without being fooled by semicolons in strings,
/// comments, quoted identifiers, PostgreSQL dollar strings, or MySQL `DELIMITER` blocks.
nonisolated enum SQLScriptParser {
    static func statements(in script: String) -> [String] {
        let characters = Array(script)
        var statements: [String] = []
        var buffer = ""
        var delimiter = ";"
        var index = 0
        var lineStart = true
        var singleQuoted = false
        var doubleQuoted = false
        var backtickQuoted = false
        var bracketQuoted = false
        var lineComment = false
        var blockComment = false
        var dollarTag: String?

        func has(_ token: String, at offset: Int) -> Bool {
            let tokenCharacters = Array(token)
            guard offset + tokenCharacters.count <= characters.count else { return false }
            return Array(characters[offset..<(offset + tokenCharacters.count)]) == tokenCharacters
        }

        func hasIgnoringCase(_ token: String, at offset: Int) -> Bool {
            guard offset + token.count <= characters.count else { return false }
            return String(characters[offset..<(offset + token.count)]).caseInsensitiveCompare(token) == .orderedSame
        }

        func isBackslashEscaped(at offset: Int) -> Bool {
            guard offset > 0 else { return false }
            var cursor = offset - 1
            var count = 0
            while characters[cursor] == "\\" {
                count += 1
                guard cursor > 0 else { break }
                cursor -= 1
            }
            return !count.isMultiple(of: 2)
        }

        func containsExecutableSQL(_ text: String) -> Bool {
            let value = Array(text)
            var cursor = 0
            while cursor < value.count {
                while cursor < value.count, value[cursor].isWhitespace { cursor += 1 }
                guard cursor < value.count else { return false }
                if value[cursor] == "#" {
                    while cursor < value.count, value[cursor] != "\n", value[cursor] != "\r" { cursor += 1 }
                    continue
                }
                if cursor + 1 < value.count, value[cursor] == "-", value[cursor + 1] == "-" {
                    cursor += 2
                    while cursor < value.count, value[cursor] != "\n", value[cursor] != "\r" { cursor += 1 }
                    continue
                }
                if cursor + 1 < value.count, value[cursor] == "/", value[cursor + 1] == "*" {
                    // MySQL executes version comments and optimizer hints; they are statements,
                    // not decoration, even though their outer spelling is a block comment.
                    if cursor + 2 < value.count, value[cursor + 2] == "!" || value[cursor + 2] == "+" {
                        return true
                    }
                    cursor += 2
                    while cursor + 1 < value.count, !(value[cursor] == "*" && value[cursor + 1] == "/") {
                        cursor += 1
                    }
                    cursor = min(value.count, cursor + 2)
                    continue
                }
                return true
            }
            return false
        }

        func flush() {
            let statement = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if containsExecutableSQL(statement) { statements.append(statement) }
            buffer.removeAll(keepingCapacity: true)
        }

        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil

            if lineComment {
                buffer.append(character)
                if character == "\n" {
                    lineComment = false
                    lineStart = true
                }
                index += 1
                continue
            }
            if blockComment {
                buffer.append(character)
                if character == "*", next == "/" {
                    buffer.append("/")
                    index += 2
                    blockComment = false
                } else {
                    index += 1
                }
                continue
            }
            if let tag = dollarTag {
                if has(tag, at: index) {
                    buffer += tag
                    index += tag.count
                    dollarTag = nil
                } else {
                    buffer.append(character)
                    index += 1
                }
                continue
            }

            if singleQuoted || doubleQuoted || backtickQuoted || bracketQuoted {
                buffer.append(character)
                let closing: Character = singleQuoted ? "'" : doubleQuoted ? "\"" : backtickQuoted ? "`" : "]"
                if character == closing {
                    if next == closing {
                        buffer.append(closing)
                        index += 2
                        continue
                    }
                    if singleQuoted, isBackslashEscaped(at: index) {
                        index += 1
                        continue
                    }
                    singleQuoted = false
                    doubleQuoted = false
                    backtickQuoted = false
                    bracketQuoted = false
                }
                index += 1
                continue
            }

            if lineStart {
                var probe = index
                while probe < characters.count, characters[probe] == " " || characters[probe] == "\t" { probe += 1 }
                let keyword = "DELIMITER"
                let afterKeyword = probe + keyword.count
                if hasIgnoringCase(keyword, at: probe),
                   afterKeyword == characters.count
                    || characters[afterKeyword] == " "
                    || characters[afterKeyword] == "\t" {
                    var end = probe + keyword.count
                    while end < characters.count, characters[end] == " " || characters[end] == "\t" { end += 1 }
                    var lineEnd = end
                    while lineEnd < characters.count, characters[lineEnd] != "\n", characters[lineEnd] != "\r" { lineEnd += 1 }
                    let value = String(characters[end..<lineEnd]).trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { delimiter = value }
                    index = lineEnd
                    lineStart = true
                    continue
                }
            }

            // Check the active delimiter before looking for PostgreSQL dollar quotes. MySQL
            // commonly uses `DELIMITER $$`; treating that terminator as an opening `$$` string
            // would swallow the rest of the file.
            if has(delimiter, at: index) {
                flush()
                index += delimiter.count
                lineStart = false
                continue
            }

            if character == "-", next == "-" {
                lineComment = true
                buffer += "--"
                index += 2
                continue
            }
            if character == "#" {
                lineComment = true
                buffer.append(character)
                index += 1
                continue
            }
            if character == "/", next == "*" {
                blockComment = true
                buffer += "/*"
                index += 2
                continue
            }
            if character == "$" {
                var end = index + 1
                while end < characters.count, characters[end].isLetter || characters[end].isNumber || characters[end] == "_" { end += 1 }
                if end < characters.count, characters[end] == "$" {
                    let tag = String(characters[index...end])
                    dollarTag = tag
                    buffer += tag
                    index = end + 1
                    lineStart = false
                    continue
                }
            }

            switch character {
            case "'": singleQuoted = true
            case "\"": doubleQuoted = true
            case "`": backtickQuoted = true
            case "[": bracketQuoted = true
            default: break
            }

            buffer.append(character)
            lineStart = character == "\n" || character == "\r"
            index += 1
        }
        flush()
        return statements
    }
}

// MARK: - Transfer engine

nonisolated enum DataTransferService {
    private static let pageSize = 500

    static func exportSQL(
        session: any DatabaseSession,
        tables: [SQLExportTable],
        database: String?,
        dialect: SQLDialect,
        options: SQLExportOptions
    ) async throws -> Data {
        let included = tables.filter(\.isIncluded)
        guard !included.isEmpty else { throw DataTransferError.noTables }

        var output = "-- DB Connect SQL export\n"
        output += "-- Database: \(database ?? "(current)")\n"
        output += "-- Created: \(ISO8601DateFormatter().string(from: .now))\n\n"

        if options.disableForeignKeyChecks {
            switch dialect.family {
            case .mysql:
                output += "SET @DB_CONNECT_OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0;\n"
            case .sqlite: output += "PRAGMA foreign_keys=OFF;\n"
            case .postgres: break
            }
        }
        output += "\n"

        // Views go last because they commonly depend on one or more selected tables.
        let ordered = included.sorted { lhs, rhs in
            if lhs.table.kind != rhs.table.kind { return lhs.table.kind == .table }
            return lhs.table.qualifiedName.localizedStandardCompare(rhs.table.qualifiedName) == .orderedAscending
        }

        // Remove dependent views before their tables. Keeping all drops in a prelude also makes
        // rerunning a dump deterministic; interleaving DROP/CREATE would leave an old view in
        // place while trying to replace the table it depends on.
        if options.includeDropStatements {
            let dropOrder = ordered.sorted { lhs, rhs in
                if lhs.table.kind != rhs.table.kind { return lhs.table.kind == .view }
                return lhs.table.qualifiedName.localizedStandardCompare(rhs.table.qualifiedName) == .orderedAscending
            }
            for selection in dropOrder where selection.includeDropStatement {
                let table = selection.table
                let qualified = try SQLIdentifier.qualify(
                    schema: table.schema,
                    name: table.name,
                    style: dialect.identifierStyle
                )
                output += "DROP \(table.kind == .view ? "VIEW" : "TABLE") IF EXISTS \(qualified);\n"
            }
            output += "\n"
        }

        for selection in ordered {
            try Task.checkCancellation()
            let table = selection.table
            output += "-- \(table.kind == .view ? "View" : "Table"): \(table.qualifiedName)\n"

            if options.includeStructure && selection.includeStructure {
                let exact = try await session.definitionSQL(for: table)
                var definition = exact ?? fallbackDefinition(for: table, dialect: dialect)
                if !options.includeAutoIncrementValue, dialect.family == .mysql {
                    definition = definition.replacingOccurrences(
                        of: #"\sAUTO_INCREMENT=\d+"#,
                        with: "",
                        options: .regularExpression
                    )
                }
                output += definition.trimmingCharacters(in: .whitespacesAndNewlines)
                if !output.hasSuffix(";") { output += ";" }
                output += "\n"
            }
        }

        if options.useTransaction { output += "BEGIN;\n\n" }

        for selection in ordered where options.includeContent && selection.includeContent {
            try Task.checkCancellation()
            let table = selection.table
            guard table.kind == .table, !table.columns.isEmpty else { continue }
            let qualified = try SQLIdentifier.qualify(
                schema: table.schema,
                name: table.name,
                style: dialect.identifierStyle
            )
            output += "-- Data: \(table.qualifiedName)\n"

            output += try await contentSQL(
                session: session,
                table: table,
                qualified: qualified,
                dialect: dialect,
                options: options
            )
            output += "\n"
        }

        let deferredSelections = ordered.filter { $0.includeStructure }
        var wroteDeferredHeader = false
        for selection in deferredSelections {
            let statements = try await session.deferredDefinitionSQL(for: selection.table)
            if !statements.isEmpty, !wroteDeferredHeader {
                output += "-- Deferred schema objects\n"
                wroteDeferredHeader = true
            }
            for statement in statements {
                output += statement.trimmingCharacters(in: .whitespacesAndNewlines)
                if !output.hasSuffix(";") { output += ";" }
                output += "\n"
            }
        }
        if wroteDeferredHeader { output += "\n" }

        if options.useTransaction { output += "COMMIT;\n" }
        if options.disableForeignKeyChecks {
            switch dialect.family {
            case .mysql: output += "SET FOREIGN_KEY_CHECKS=@DB_CONNECT_OLD_FOREIGN_KEY_CHECKS;\n"
            case .sqlite: output += "PRAGMA foreign_keys=ON;\n"
            case .postgres: break
            }
        }
        var data = Data(output.utf8)
        if options.addUTF8BOM { data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0) }
        return data
    }

    static func exportCSV(
        session: any DatabaseSession,
        table: TableDescriptor,
        options: CSVOptions
    ) async throws -> Data {
        var output = ""
        if options.includeHeader {
            output += CSVCodec.encode(table.columns.map(\.name), options: options) + options.lineEnding.value
        }

        var offset = 0
        while true {
            try Task.checkCancellation()
            let result = try await session.fetch(RowRequest(
                table: table.name,
                schema: table.schema,
                limit: pageSize,
                offset: offset
            ))
            for row in result.rows {
                let fields = row.map { csvString(for: $0, nullValue: options.nullValue) }
                output += CSVCodec.encode(fields, options: options) + options.lineEnding.value
            }
            guard result.hasMore else { break }
            offset += result.rows.count
            if result.rows.isEmpty { break }
        }

        var data = Data(output.utf8)
        if options.addUTF8BOM { data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0) }
        return data
    }

    static func importSQL(
        _ script: String,
        into session: any DatabaseSession,
        options: SQLImportOptions
    ) async throws -> ImportSummary {
        let statements = SQLScriptParser.statements(in: script)
        guard !statements.isEmpty else { throw DataTransferError.noContent }

        var completed = 0
        var failures: [ImportFailure] = []
        let transactional = options.wrapInTransaction && options.stopOnError
        if transactional { _ = try await session.execute(Statement("BEGIN")) }

        do {
            for (index, sql) in statements.enumerated() {
                try Task.checkCancellation()
                do {
                    _ = try await session.execute(Statement(sql))
                    completed += 1
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failures.append(ImportFailure(
                        id: index + 1,
                        statement: String(sql.prefix(300)),
                        message: error.localizedDescription
                    ))
                    if options.stopOnError { throw error }
                }
            }
            if transactional { _ = try await session.execute(Statement("COMMIT")) }
        } catch is CancellationError {
            if transactional { _ = try? await session.execute(Statement("ROLLBACK")) }
            throw CancellationError()
        } catch {
            if transactional { _ = try? await session.execute(Statement("ROLLBACK")) }
            if failures.isEmpty { throw error }
            return ImportSummary(completed: transactional ? 0 : completed, failures: failures)
        }
        return ImportSummary(completed: completed, failures: failures)
    }

    /// Imports CSV rows using parameterized statements. `mapping` maps a destination column name
    /// to its source CSV index; omitted destination columns keep their database defaults.
    static func importCSV(
        _ csv: ParsedCSV,
        into session: any DatabaseSession,
        table: TableDescriptor,
        mapping: [String: Int],
        dialect: SQLDialect,
        options: CSVImportOptions
    ) async throws -> ImportSummary {
        guard !mapping.isEmpty else {
            throw DataTransferError.invalidMapping("Map at least one CSV field to a table column.")
        }
        let knownColumns = Dictionary(uniqueKeysWithValues: table.columns.map { ($0.name, $0) })
        for (column, index) in mapping {
            guard let descriptor = knownColumns[column] else {
                throw DataTransferError.invalidMapping("The table has no column named “\(column)”.")
            }
            guard !descriptor.isGenerated else {
                throw DataTransferError.invalidMapping("“\(column)” is generated by the database and cannot be imported.")
            }
            guard index >= 0, index < csv.columnCount else {
                throw DataTransferError.invalidMapping("The mapping for “\(column)” points outside the CSV file.")
            }
        }

        let rows = csv.dataRows(firstRowIsHeader: options.firstRowIsHeader)
        guard !rows.isEmpty else { throw DataTransferError.noContent }
        let qualified = try SQLIdentifier.qualify(
            schema: table.schema,
            name: table.name,
            style: dialect.identifierStyle
        )
        let orderedMapping = mapping.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key < rhs.key
        }
        let quotedColumns = try orderedMapping.map {
            try SQLIdentifier.quote($0.key, style: dialect.identifierStyle)
        }
        let placeholders = orderedMapping.indices.map { dialect.placeholder($0 + 1) }
        let verb = insertVerb(for: options.conflictStrategy, family: dialect.family)
        var sql = "\(verb) INTO \(qualified) (\(quotedColumns.joined(separator: ", "))) VALUES (\(placeholders.joined(separator: ", ")))"
        sql += try conflictSuffix(
            for: options.conflictStrategy,
            table: table,
            importedColumns: orderedMapping.map(\.key),
            dialect: dialect
        )

        var completed = 0
        if options.useTransaction { _ = try await session.execute(Statement("BEGIN")) }
        do {
            for row in rows {
                try Task.checkCancellation()
                let bindings = orderedMapping.map { column, sourceIndex -> SQLValue in
                    let raw = row.indices.contains(sourceIndex) ? row[sourceIndex] : ""
                    return value(
                        from: raw,
                        column: knownColumns[column]!,
                        nullValue: options.nullValue,
                        emptyIsNull: options.emptyValuesAreNull
                    )
                }
                _ = try await session.execute(Statement(sql, bindings: bindings))
                completed += 1
            }
            if options.useTransaction { _ = try await session.execute(Statement("COMMIT")) }
        } catch {
            if options.useTransaction { _ = try? await session.execute(Statement("ROLLBACK")) }
            throw error
        }
        return ImportSummary(completed: completed, failures: [])
    }

    static func decodedText(from data: Data) throws -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let value = String(data: data.dropFirst(3), encoding: .utf8) {
            return value
        }
        if data.starts(with: [0xFF, 0xFE]), let value = String(data: data, encoding: .utf16LittleEndian) {
            return value
        }
        if data.starts(with: [0xFE, 0xFF]), let value = String(data: data, encoding: .utf16BigEndian) {
            return value
        }
        if let value = String(data: data, encoding: .utf8) { return value }
        if let value = String(data: data, encoding: .isoLatin1) { return value }
        throw DataTransferError.unsupported("The file is not UTF-8, UTF-16, or ISO Latin-1 text.")
    }

    static func inferredColumns(from csv: ParsedCSV, firstRowIsHeader: Bool) -> [NewColumn] {
        let headers = uniqueHeaders(csv.headers(firstRowIsHeader: firstRowIsHeader))
        let sample = csv.dataRows(firstRowIsHeader: firstRowIsHeader).prefix(200)
        return headers.enumerated().map { index, name in
            let values = sample.compactMap { row in row.indices.contains(index) ? row[index] : nil }
                .filter { !$0.isEmpty }
            let type: ColumnType
            if !values.isEmpty, values.allSatisfy({ Int64($0) != nil }) {
                type = .bigInteger
            } else if !values.isEmpty, values.allSatisfy({ Double($0) != nil }) {
                type = .real
            } else if !values.isEmpty, values.allSatisfy({ ["true", "false", "yes", "no", "0", "1"].contains($0.lowercased()) }) {
                type = .boolean
            } else {
                type = .text
            }
            return NewColumn(name: name, type: type)
        }
    }

    static func uniqueHeaders(_ headers: [String]) -> [String] {
        var counts: [String: Int] = [:]
        return headers.enumerated().map { index, raw in
            let base = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "column_\(index + 1)" : raw
            let key = base.lowercased()
            counts[key, default: 0] += 1
            return counts[key] == 1 ? base : "\(base)_\(counts[key]!)"
        }
    }

    private static func contentSQL(
        session: any DatabaseSession,
        table: TableDescriptor,
        qualified: String,
        dialect: SQLDialect,
        options: SQLExportOptions
    ) async throws -> String {
        let exportedColumns = table.columns.enumerated().filter {
            options.includeGeneratedColumns || !$0.element.isGenerated
        }
        guard !exportedColumns.isEmpty else { return "" }
        let columns = try exportedColumns.map {
            try SQLIdentifier.quote($0.element.name, style: dialect.identifierStyle)
        }.joined(separator: ", ")
        let insertHead = "INSERT INTO \(qualified) (\(columns)) VALUES\n"
        var output = ""
        var batch: [String] = []
        var offset = 0

        func appendBatch() {
            guard !batch.isEmpty else { return }
            output += insertHead + batch.joined(separator: ",\n") + ";\n"
            batch.removeAll(keepingCapacity: true)
        }

        while true {
            let result = try await session.fetch(RowRequest(
                table: table.name,
                schema: table.schema,
                limit: pageSize,
                offset: offset
            ))
            for row in result.rows {
                let literals = exportedColumns.map { index, column in
                    let value = row.indices.contains(index) ? row[index] : .null
                    return literal(
                        for: value,
                        declaredType: column.declaredType,
                        dialect: dialect,
                        blobAsHex: options.blobAsHex
                    )
                }
                batch.append("    (\(literals.joined(separator: ", ")))")
                if batch.count >= max(1, options.rowsPerInsert) { appendBatch() }
            }
            guard result.hasMore else { break }
            offset += result.rows.count
            if result.rows.isEmpty { break }
            try Task.checkCancellation()
        }
        appendBatch()
        return output
    }

    private static func fallbackDefinition(for table: TableDescriptor, dialect: SQLDialect) -> String {
        let qualified = (try? SQLIdentifier.qualify(
            schema: table.schema,
            name: table.name,
            style: dialect.identifierStyle
        )) ?? table.qualifiedName
        if table.kind == .view {
            return "-- Definition unavailable for view \(qualified)"
        }
        var definitions = table.columns.map { column -> String in
            let name = (try? SQLIdentifier.quote(column.name, style: dialect.identifierStyle)) ?? column.name
            var parts = [name, column.declaredType.isEmpty ? "TEXT" : column.declaredType]
            if !column.isNullable { parts.append("NOT NULL") }
            if let defaultValue = column.defaultValue { parts.append("DEFAULT \(defaultValue)") }
            return parts.joined(separator: " ")
        }
        let keys = table.primaryKey.compactMap { try? SQLIdentifier.quote($0, style: dialect.identifierStyle) }
        if !keys.isEmpty { definitions.append("PRIMARY KEY (\(keys.joined(separator: ", ")))") }
        return "CREATE TABLE \(qualified) (\n" + definitions.map { "    \($0)" }.joined(separator: ",\n") + "\n)"
    }

    private static func literal(
        for value: SQLValue,
        declaredType: String,
        dialect: SQLDialect,
        blobAsHex: Bool
    ) -> String {
        switch value {
        case .null: return "NULL"
        case .bool(let value):
            return dialect.family == .postgres ? (value ? "TRUE" : "FALSE") : (value ? "1" : "0")
        case .integer(let value): return String(value)
        case .double(let value): return value.isFinite ? String(value) : "NULL"
        case .date(let value):
            let type = declaredType.lowercased()
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            if type == "date" {
                formatter.dateFormat = "yyyy-MM-dd"
            } else if dialect.family == .mysql {
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            } else {
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSXXXXX"
            }
            return quoted(formatter.string(from: value))
        case .text(let value):
            // MySQL's backslash mode varies by server. A UTF-8 hex introducer is both lossless
            // and independent of SQL_MODE; the other engines use standard doubled quotes.
            if dialect.family == .mysql { return "_utf8mb4 0x\(Data(value.utf8).hexString)" }
            return quoted(value)
        case .blob(let data):
            if !blobAsHex {
                let base64 = data.base64EncodedString()
                switch dialect.family {
                case .mysql: return "FROM_BASE64('\(base64)')"
                case .postgres: return "decode('\(base64)', 'base64')"
                // SQLite has no built-in base64 decoder, so hexadecimal remains the only
                // round-trip-safe representation even when compact base64 was requested.
                case .sqlite: return "X'\(data.hexString)'"
                }
            }
            switch dialect.family {
            case .mysql: return "0x\(data.hexString)"
            case .sqlite: return "X'\(data.hexString)'"
            case .postgres: return "decode('\(data.hexString)', 'hex')"
            }
        }
    }

    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func csvString(for value: SQLValue, nullValue: String) -> String {
        switch value {
        case .null: nullValue
        case .bool(let value): value ? "true" : "false"
        case .integer(let value): String(value)
        case .double(let value): String(value)
        case .text(let value): value
        case .blob(let value): "0x" + value.hexString
        case .date(let value): ISO8601DateFormatter().string(from: value)
        }
    }

    private static func value(
        from raw: String,
        column: ColumnDescriptor,
        nullValue: String,
        emptyIsNull: Bool
    ) -> SQLValue {
        if raw == nullValue || (emptyIsNull && raw.isEmpty) { return .null }
        let type = column.declaredType.lowercased()
        if type.contains("bool") || type == "tinyint(1)" {
            switch raw.lowercased() {
            case "true", "yes", "y", "1": return .bool(true)
            case "false", "no", "n", "0": return .bool(false)
            default: break
            }
        }
        if type.contains("int"), let integer = Int64(raw) { return .integer(integer) }
        if type.contains("real") || type.contains("double") || type.contains("float") || type.contains("numeric") || type.contains("decimal") {
            if let double = Double(raw) { return .double(double) }
        }
        if type.contains("blob") || type.contains("bytea") || type.contains("binary"), raw.hasPrefix("0x"),
           let data = Data(hexString: String(raw.dropFirst(2))) {
            return .blob(data)
        }
        if type.contains("date") || type.contains("time"),
           let date = ISO8601DateFormatter().date(from: raw) {
            return .date(date)
        }
        return .text(raw)
    }

    private static func insertVerb(for strategy: CSVConflictStrategy, family: SQLDialect.Family) -> String {
        switch (strategy, family) {
        case (.ignore, .mysql): "INSERT IGNORE"
        case (.ignore, .sqlite): "INSERT OR IGNORE"
        default: "INSERT"
        }
    }

    private static func conflictSuffix(
        for strategy: CSVConflictStrategy,
        table: TableDescriptor,
        importedColumns: [String],
        dialect: SQLDialect
    ) throws -> String {
        switch strategy {
        case .fail: return ""
        case .ignore:
            return dialect.family == .postgres ? " ON CONFLICT DO NOTHING" : ""
        case .replace:
            let keys = table.primaryKey
            if dialect.family != .mysql, keys.isEmpty {
                throw DataTransferError.invalidMapping("Updating duplicates requires a primary key on the target table.")
            }
            let updates = try importedColumns.filter { !keys.contains($0) }.map { column in
                let quoted = try SQLIdentifier.quote(column, style: dialect.identifierStyle)
                return switch dialect.family {
                case .mysql: "\(quoted) = VALUES(\(quoted))"
                case .sqlite: "\(quoted) = excluded.\(quoted)"
                case .postgres: "\(quoted) = EXCLUDED.\(quoted)"
                }
            }
            guard !updates.isEmpty else {
                if dialect.family == .mysql, let firstKey = keys.first {
                    let quoted = try SQLIdentifier.quote(firstKey, style: dialect.identifierStyle)
                    return " ON DUPLICATE KEY UPDATE \(quoted) = VALUES(\(quoted))"
                }
                return dialect.family == .mysql ? "" : " ON CONFLICT DO NOTHING"
            }
            if dialect.family == .mysql {
                return " ON DUPLICATE KEY UPDATE \(updates.joined(separator: ", "))"
            }
            let target = try keys.map { try SQLIdentifier.quote($0, style: dialect.identifierStyle) }
            return " ON CONFLICT (\(target.joined(separator: ", "))) DO UPDATE SET \(updates.joined(separator: ", "))"
        }
    }
}

nonisolated private extension Data {
    var hexString: String { map { String(format: "%02X", $0) }.joined() }

    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        data.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
