import SwiftUI
import UniformTypeIdentifiers

nonisolated enum TransferOperation: String, CaseIterable, Identifiable {
    case export = "Export"
    case `import` = "Import"

    var id: String { rawValue }
}

/// One guided home for database dumps and spreadsheet-friendly data files. The common path is
/// intentionally short (choose tables/file, then go); Sequel Ace-style controls remain available
/// in the format sections without forcing every user through a separate advanced dialog.
struct DataTransferView: View {
    let session: any DatabaseSession
    let dialect: SQLDialect?
    let database: String?
    let tables: [TableDescriptor]
    let selectedTable: TableDescriptor?
    let canImport: Bool
    let canCreateTable: Bool
    let onSchemaChange: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var operation: TransferOperation
    @State private var format: TransferFormat
    @State private var sqlTables: [SQLExportTable]
    @State private var exportSearchText = ""
    @State private var csvTableID: String
    @State private var exportsMultipleCSVs = false
    @State private var csvTableIDs: Set<String>
    @State private var sqlExport = SQLExportOptions()
    @State private var csvExport = CSVOptions()

    @State private var document: TransferFileDocument?
    @State private var documents: [TransferFileDocument] = []
    @State private var exportContentType: UTType = .plainText
    @State private var exportFilename = "Export"
    @State private var showsExporter = false
    @State private var showsMultipleExporter = false
    @State private var showsImporter = false

    @State private var importFilename: String?
    @State private var importText: String?
    @State private var importByteCount = 0
    @State private var importLineCount = 0
    @State private var sqlPreviewCount = 0
    @State private var sqlPreviewStatements: [ParsedSQLStatement] = []
    @State private var sqlPreviewWasTruncated = false
    @State private var parsedCSV: ParsedCSV?
    @State private var sqlImport = SQLImportOptions()
    @State private var csvImport = CSVImportOptions()
    @State private var targetTableID: String
    @State private var columnMapping: [String: Int] = [:]
    @State private var createNewTable = false
    @State private var newTableName = ""

    @State private var isWorking = false
    @State private var transferTask: Task<Void, Never>?
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var importFailures: [ImportFailure] = []

    init(
        session: any DatabaseSession,
        dialect: SQLDialect?,
        database: String?,
        tables: [TableDescriptor],
        selectedTable: TableDescriptor?,
        initialOperation: TransferOperation,
        canImport: Bool,
        canCreateTable: Bool,
        onSchemaChange: @escaping () -> Void
    ) {
        self.session = session
        self.dialect = dialect
        self.database = database
        self.tables = tables
        self.selectedTable = selectedTable
        self.canImport = canImport
        self.canCreateTable = canCreateTable
        self.onSchemaChange = onSchemaChange

        let initialTable = selectedTable ?? tables.first
        _operation = State(initialValue: initialOperation)
        _format = State(initialValue: dialect == nil ? .csv : .sql)
        _sqlTables = State(initialValue: tables.map {
            SQLExportTable(
                table: $0,
                includeStructure: true,
                includeContent: $0.kind == .table,
                includeDropStatement: true
            )
        })
        _csvTableID = State(initialValue: initialTable?.id ?? "")
        _csvTableIDs = State(initialValue: Set(tables.filter { $0.kind == .table }.map(\.id)))
        _targetTableID = State(initialValue: initialTable?.id ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Operation", selection: $operation) {
                    ForEach(TransferOperation.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if operation == .export {
                    exportForm
                } else {
                    importForm
                }

                if let statusMessage {
                    Section {
                        Label(
                            statusMessage,
                            systemImage: importFailures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                        )
                        .foregroundStyle(importFailures.isEmpty ? .green : .orange)
                    }
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                if !importFailures.isEmpty {
                    Section("Import errors (\(importFailures.count))") {
                        ForEach(importFailures) { failure in
                            DisclosureGroup("Statement \(failure.id) · \(failure.lineSummary)") {
                                Text(failure.message)
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                                Text(failure.lineSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(failure.statement)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Import & Export")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(operation.rawValue) {
                        startPrimaryAction()
                    }
                    .disabled(primaryActionDisabled || isWorking)
                }
            }
            .overlay {
                if isWorking {
                    ZStack {
                        Rectangle().fill(.background.opacity(0.65)).ignoresSafeArea()
                        VStack(spacing: 12) {
                            DatabaseLoadingView(
                                operation == .export ? "Preparing export…" : "Importing…",
                                size: 34
                            )
                            Button("Cancel") { transferTask?.cancel() }
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 720, idealWidth: 820, minHeight: 650, idealHeight: 760)
        #endif
        .fileExporter(
            isPresented: $showsExporter,
            document: document,
            contentType: exportContentType,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
        .fileExporter(
            isPresented: $showsMultipleExporter,
            documents: documents,
            contentType: .commaSeparatedText
        ) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText, .data]
        ) { result in
            loadImportFile(result)
        }
        .onChange(of: operation) { _, _ in clearMessages() }
        .onChange(of: format) { _, newFormat in
            clearMessages()
            if operation == .import, importText != nil {
                if newFormat == .csv { parseCSV() } else { prepareSQLPreview() }
            }
        }
        .onChange(of: csvExport.delimiter) { _, _ in
            if operation == .import { parseCSV() }
        }
        .onChange(of: csvExport.quote) { _, _ in
            if operation == .import { parseCSV() }
        }
        .onChange(of: csvImport.firstRowIsHeader) { _, _ in rebuildMapping() }
        .onChange(of: targetTableID) { _, _ in rebuildMapping() }
        .onChange(of: createNewTable) { _, _ in rebuildMapping() }
        .onDisappear { transferTask?.cancel() }
    }

    @ViewBuilder
    private var exportForm: some View {
        Section("Format") {
            Picker("File format", selection: $format) {
                if dialect != nil { Text("SQL dump").tag(TransferFormat.sql) }
                Text("CSV data").tag(TransferFormat.csv)
            }
            .pickerStyle(.segmented)
        }

        if format == .sql {
            sqlExportForm
        } else {
            csvExportForm
        }
    }

    private var sqlExportForm: some View {
        Group {
            Section("Objects") {
                if tables.count > 6 {
                    TextField("Filter tables and views", text: $exportSearchText)
                        .autocorrectionDisabled()
                }

                HStack {
                    Text("Database objects")
                    Spacer()
                    Text("Structure  Content  Drop")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if filteredSQLTableIndices.isEmpty {
                    ContentUnavailableView(
                        "No Matching Objects",
                        systemImage: "magnifyingglass",
                        description: Text("Try a different table, view, or schema name.")
                    )
                }

                ForEach(filteredSQLTableIndices, id: \.self) { index in
                    let selection = $sqlTables[index]
                    HStack {
                        Label(
                            selection.wrappedValue.table.qualifiedName,
                            systemImage: selection.wrappedValue.table.kind == .view ? "eye" : "tablecells"
                        )
                        .lineLimit(1)
                        Spacer()
                        Toggle("Structure", isOn: selection.includeStructure).labelsHidden()
                        Toggle("Content", isOn: selection.includeContent)
                            .labelsHidden()
                            .disabled(selection.wrappedValue.table.kind == .view)
                        Toggle("Drop", isOn: selection.includeDropStatement).labelsHidden()
                    }
                }

                HStack {
                    Button(allSQLTablesSelected ? "Deselect All" : "Select All") {
                        setAllSQLTablesSelected(!allSQLTablesSelected)
                    }
                    Button("Select Visible") {
                        for index in filteredSQLTableIndices {
                            sqlTables[index].includeStructure = true
                            sqlTables[index].includeContent = sqlTables[index].table.kind == .table
                            sqlTables[index].includeDropStatement = true
                        }
                    }
                    Button("Clear Visible") {
                        for index in filteredSQLTableIndices {
                            sqlTables[index].includeStructure = false
                            sqlTables[index].includeContent = false
                            sqlTables[index].includeDropStatement = false
                        }
                    }
                    Spacer()
                    Text("\(sqlTables.filter(\.isIncluded).count) selected")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }

            Section("SQL options") {
                Toggle("Wrap data in a transaction", isOn: $sqlExport.useTransaction)
                Toggle("Temporarily disable foreign-key checks", isOn: $sqlExport.disableForeignKeyChecks)
                    .disabled(dialect?.family == .postgres)
                Toggle("Preserve current auto-increment value", isOn: $sqlExport.includeAutoIncrementValue)
                    .disabled(dialect?.family != .mysql)
                Toggle("Write binary fields as hexadecimal", isOn: $sqlExport.blobAsHex)
                    .disabled(dialect?.family == .sqlite)
                Toggle("Include generated columns in INSERT statements", isOn: $sqlExport.includeGeneratedColumns)
                    .disabled(!tables.contains { $0.columns.contains(where: \.isGenerated) })
                Stepper(
                    "New INSERT every \(sqlExport.rowsPerInsert) rows",
                    value: $sqlExport.rowsPerInsert,
                    in: 1...5_000,
                    step: 50
                )
                Toggle("Add UTF-8 byte-order mark", isOn: $sqlExport.addUTF8BOM)
            }
        }
    }

    private var csvExportForm: some View {
        Group {
            Section("Data") {
                Toggle("Export multiple tables", isOn: $exportsMultipleCSVs)
                if exportsMultipleCSVs {
                    if tables.filter({ $0.kind == .table }).count > 6 {
                        TextField("Filter tables", text: $exportSearchText)
                            .autocorrectionDisabled()
                    }
                    if filteredCSVTables.isEmpty {
                        ContentUnavailableView(
                            "No Matching Tables",
                            systemImage: "magnifyingglass",
                            description: Text("Try a different table or schema name.")
                        )
                    }
                    ForEach(filteredCSVTables) { table in
                        Toggle(table.qualifiedName, isOn: csvSelectionBinding(for: table.id))
                    }
                    HStack {
                        Button(allCSVTableIDsSelected ? "Deselect All" : "Select All") {
                            csvTableIDs = allCSVTableIDsSelected ? [] : Set(tables.filter { $0.kind == .table }.map(\.id))
                        }
                        Button("Select Visible") {
                            csvTableIDs.formUnion(filteredCSVTables.map(\.id))
                        }
                        Button("Clear Visible") {
                            csvTableIDs.subtract(filteredCSVTables.map(\.id))
                        }
                        Spacer()
                        Text("\(csvTableIDs.count) selected").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                } else {
                    Picker("Table", selection: $csvTableID) {
                        ForEach(tables.filter { $0.kind == .table }) { table in
                            Text(table.qualifiedName).tag(table.id)
                        }
                    }
                }
            }

            Section("CSV options") {
                delimiterPicker
                quotePicker
                Toggle("Include column names", isOn: $csvExport.includeHeader)
                TextField("NULL value", text: $csvExport.nullValue)
                Picker("Line endings", selection: $csvExport.lineEnding) {
                    ForEach(CSVOptions.LineEnding.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Add UTF-8 byte-order mark", isOn: $csvExport.addUTF8BOM)
            }
        }
    }

    @ViewBuilder
    private var importForm: some View {
        if !canImport {
            Section {
                ContentUnavailableView(
                    "Import Unavailable",
                    systemImage: "lock",
                    description: Text("This connection is read-only or does not support SQL writes.")
                )
            }
        } else {
            Section("Source") {
                Button {
                    showsImporter = true
                } label: {
                    HStack {
                        Label(importFilename ?? "Choose SQL or CSV file…", systemImage: "doc.badge.plus")
                        Spacer()
                        Text("Choose…").foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if importText != nil {
                    Picker("File format", selection: $format) {
                        Text("SQL dump").tag(TransferFormat.sql)
                        Text("CSV data").tag(TransferFormat.csv)
                    }
                    .pickerStyle(.segmented)
                }
            }

            if importText != nil {
                if format == .sql { sqlImportForm } else { csvImportForm }
            }
        }
    }

    private var sqlImportForm: some View {
        Group {
            Section("SQL options") {
                Toggle("Stop at the first error", isOn: $sqlImport.stopOnError)
                Toggle("Wrap script in a transaction", isOn: $sqlImport.wrapInTransaction)
                    .disabled(!sqlImport.stopOnError)
                if !sqlImport.stopOnError {
                    Text("Errors will be collected and the remaining statements will continue. Transaction wrapping is disabled because PostgreSQL cannot continue a failed transaction.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if importText != nil {
                Section("Preview") {
                    Text("\(formattedImportSize) · \(importLineCount.formatted()) line\(importLineCount == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                    if sqlPreviewCount >= 0 {
                        Text("\(sqlPreviewCount.formatted()) executable statement\(sqlPreviewCount == 1 ? "" : "s")")
                    } else {
                        Text("Large script detected. Showing a preview from the opening part of the file.")
                    }
                    if sqlPreviewWasTruncated {
                        Text("The preview is intentionally partial so very large dumps stay responsive before import.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if sqlPreviewStatements.isEmpty {
                        Text("No executable SQL found.")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    } else {
                        ForEach(sqlPreviewStatements.prefix(5)) { statement in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Statement \(statement.id) · \(statement.lineSummary)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(statement.preview)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .lineLimit(5)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
    }

    private var csvImportForm: some View {
        Group {
            Section("CSV format") {
                delimiterPicker
                quotePicker
                Toggle("First row contains column names", isOn: $csvImport.firstRowIsHeader)
                TextField("NULL value", text: $csvImport.nullValue)
                Toggle("Treat empty fields as NULL", isOn: $csvImport.emptyValuesAreNull)
            }

            Section("Destination") {
                if canCreateTable {
                    Toggle("Create a new table", isOn: $createNewTable)
                }
                if createNewTable {
                    TextField("New table name", text: $newTableName)
                        .autocorrectionDisabled()
                    Text("Column names and basic types are inferred from the first 200 rows. Review the table structure after importing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Table", selection: $targetTableID) {
                        ForEach(tables.filter { $0.kind == .table }) { table in
                            Text(table.qualifiedName).tag(table.id)
                        }
                    }
                }
                Picker("On duplicate key", selection: $csvImport.conflictStrategy) {
                    ForEach(CSVConflictStrategy.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Import in one transaction", isOn: $csvImport.useTransaction)
            }

            if let csv = parsedCSV {
                csvPreview(csv)
                if createNewTable {
                    inferredColumnsPreview(csv)
                } else {
                    mappingForm(csv)
                }
            }
        }
    }

    private func csvPreview(_ csv: ParsedCSV) -> some View {
        Section("Preview") {
            let headers = csv.headers(firstRowIsHeader: csvImport.firstRowIsHeader)
            Text("\(csv.dataRows(firstRowIsHeader: csvImport.firstRowIsHeader).count.formatted()) rows · \(csv.columnCount) columns")
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                    GridRow {
                        ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                            Text(header).font(.caption.bold()).lineLimit(1)
                        }
                    }
                    Divider()
                    ForEach(Array(csv.dataRows(firstRowIsHeader: csvImport.firstRowIsHeader).prefix(6).enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(headers.indices), id: \.self) { index in
                                Text(row.indices.contains(index) ? row[index] : "")
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func inferredColumnsPreview(_ csv: ParsedCSV) -> some View {
        Section("New Table Preview") {
            let columns = DataTransferService.inferredColumns(from: csv, firstRowIsHeader: csvImport.firstRowIsHeader)
            ForEach(columns) { column in
                HStack {
                    Text(column.name)
                    Spacer()
                    Text(column.type.displayName)
                        .foregroundStyle(.secondary)
                }
            }
            Text("DB Connect infers a compact starter schema from the first 200 rows. Review indexes, defaults, and exact types after the import.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func mappingForm(_ csv: ParsedCSV) -> some View {
        Section {
            if let targetTable {
                ForEach(targetTable.columns) { column in
                    Picker(column.name, selection: mappingBinding(for: column.name)) {
                        Text("Do not import").tag(-1)
                        ForEach(Array(csv.headers(firstRowIsHeader: csvImport.firstRowIsHeader).enumerated()), id: \.offset) { index, header in
                            Text("\(index + 1): \(header)").tag(index)
                        }
                    }
                    .disabled(column.isGenerated)
                }
            }
        } header: {
            Text("Column mapping")
        } footer: {
            Text("Unmapped database columns keep their default value.")
        }
    }

    private var delimiterPicker: some View {
        Picker("Field delimiter", selection: delimiterBinding) {
            Text("Comma (,)").tag(",")
            Text("Semicolon (;)").tag(";")
            Text("Tab").tag("\t")
            Text("Pipe (|)").tag("|")
        }
    }

    private var quotePicker: some View {
        Picker("Fields enclosed by", selection: quoteBinding) {
            Text("Double quote (\")").tag("\"")
            Text("Single quote (')").tag("'")
        }
    }

    private var delimiterBinding: Binding<String> {
        Binding(
            get: { String(csvExport.delimiter) },
            set: { value in if let character = value.first { csvExport.delimiter = character } }
        )
    }

    private var quoteBinding: Binding<String> {
        Binding(
            get: { String(csvExport.quote) },
            set: { value in if let character = value.first { csvExport.quote = character } }
        )
    }

    private var targetTable: TableDescriptor? {
        tables.first { $0.id == targetTableID }
    }

    private var selectedCSVTable: TableDescriptor? {
        tables.first { $0.id == csvTableID }
    }

    private var selectedCSVTables: [TableDescriptor] {
        tables.filter { $0.kind == .table && csvTableIDs.contains($0.id) }
    }

    private var filteredSQLTableIndices: [Int] {
        sqlTables.indices.filter { matchesExportSearch(sqlTables[$0].table) }
    }

    private var filteredCSVTables: [TableDescriptor] {
        tables.filter { $0.kind == .table && matchesExportSearch($0) }
    }

    private var allSQLTablesSelected: Bool {
        !sqlTables.isEmpty && sqlTables.allSatisfy(\.isIncluded)
    }

    private var allCSVTableIDsSelected: Bool {
        let allTableIDs = Set(tables.filter { $0.kind == .table }.map(\.id))
        return !allTableIDs.isEmpty && csvTableIDs == allTableIDs
    }

    private func setAllSQLTablesSelected(_ isSelected: Bool) {
        for index in sqlTables.indices {
            sqlTables[index].includeStructure = isSelected
            sqlTables[index].includeContent = isSelected && sqlTables[index].table.kind == .table
            sqlTables[index].includeDropStatement = isSelected
        }
    }

    private var primaryActionDisabled: Bool {
        if operation == .export {
            if format == .sql { return dialect == nil || !sqlTables.contains(where: \.isIncluded) }
            return exportsMultipleCSVs ? selectedCSVTables.isEmpty : selectedCSVTable == nil
        }
        guard canImport, importText != nil else { return true }
        if format == .sql { return dialect == nil }
        guard parsedCSV != nil else { return true }
        if createNewTable { return newTableName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return targetTable == nil || columnMapping.values.allSatisfy { $0 < 0 }
    }

    private func performPrimaryAction() async {
        clearMessages()
        isWorking = true
        defer {
            isWorking = false
            transferTask = nil
        }
        do {
            if operation == .export {
                try await prepareExport()
            } else {
                try await runImport()
            }
        } catch is CancellationError {
            errorMessage = "The operation was cancelled."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startPrimaryAction() {
        guard transferTask == nil else { return }
        transferTask = Task { await performPrimaryAction() }
    }

    private func prepareExport() async throws {
        let data: Data
        let base = safeFilename(database ?? "Database")
        if format == .sql {
            guard let dialect else {
                throw DataTransferError.unsupported("This connection cannot create a SQL dump.")
            }
            data = try await DataTransferService.exportSQL(
                session: session,
                tables: sqlTables,
                database: database,
                dialect: dialect,
                options: sqlExport
            )
            exportContentType = .plainText
            exportFilename = "\(base)_\(dateStamp).sql"
        } else {
            if exportsMultipleCSVs {
                let selected = selectedCSVTables
                guard !selected.isEmpty else { throw DataTransferError.noTables }
                var exports: [TransferFileDocument] = []
                for table in selected {
                    try Task.checkCancellation()
                    let tableData = try await DataTransferService.exportCSV(
                        session: session,
                        table: table,
                        options: csvExport
                    )
                    exports.append(TransferFileDocument(
                        data: tableData,
                        filename: "\(safeFilename(table.name))_\(dateStamp).csv"
                    ))
                }
                documents = exports
                showsMultipleExporter = true
                return
            }
            guard let table = selectedCSVTable else { throw DataTransferError.noTables }
            data = try await DataTransferService.exportCSV(
                session: session,
                table: table,
                options: csvExport
            )
            exportContentType = .commaSeparatedText
            exportFilename = "\(safeFilename(table.name))_\(dateStamp).csv"
        }
        document = TransferFileDocument(data: data)
        showsExporter = true
    }

    private func runImport() async throws {
        guard let importText else { throw DataTransferError.noContent }
        if format == .sql {
            let summary = try await DataTransferService.importSQL(importText, into: session, options: sqlImport)
            statusMessage = summary.message
            importFailures = summary.failures
            onSchemaChange()
            return
        }

        guard let dialect else {
            throw DataTransferError.unsupported("CSV import requires a SQL connection.")
        }
        guard let parsedCSV else { throw DataTransferError.noContent }
        let destination: TableDescriptor
        var mapping = columnMapping.filter { $0.value >= 0 }

        if createNewTable {
            let columns = DataTransferService.inferredColumns(
                from: parsedCSV,
                firstRowIsHeader: csvImport.firstRowIsHeader
            )
            let spec = NewTableSpec(
                name: newTableName.trimmingCharacters(in: .whitespacesAndNewlines),
                schema: selectedTable?.schema,
                columns: columns
            )
            try await session.createTable(spec)
            destination = try await session.describe(table: spec.name, schema: spec.schema)
            mapping = Dictionary(uniqueKeysWithValues: columns.enumerated().map { ($0.element.name, $0.offset) })
            onSchemaChange()
        } else {
            guard let targetTable else { throw DataTransferError.noTables }
            destination = targetTable
        }

        let summary = try await DataTransferService.importCSV(
            parsedCSV,
            into: session,
            table: destination,
            mapping: mapping,
            dialect: dialect,
            options: csvImport
        )
        statusMessage = summary.message
        onSchemaChange()
    }

    private func loadImportFile(_ result: Result<URL, Error>) {
        clearMessages()
        do {
            let url = try result.get()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let text = try DataTransferService.decodedText(from: data)
            importFilename = url.lastPathComponent
            importText = text
            importByteCount = data.count
            importLineCount = text.isEmpty ? 0 : text.reduce(into: 1) { count, character in
                if character == "\n" { count += 1 }
            }
            let ext = url.pathExtension.lowercased()
            format = ext == "csv" || ext == "tsv" ? .csv : .sql
            if ext == "tsv" {
                csvExport.delimiter = "\t"
            } else if format == .csv {
                csvExport.delimiter = CSVCodec.detectedDelimiter(in: text)
            }
            newTableName = safeIdentifier(url.deletingPathExtension().lastPathComponent)
            if format == .csv {
                parseCSV()
            } else {
                parsedCSV = nil
                prepareSQLPreview()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func parseCSV() {
        guard let importText else { parsedCSV = nil; return }
        do {
            parsedCSV = try CSVCodec.parse(importText, delimiter: csvExport.delimiter, quote: csvExport.quote)
            sqlPreviewStatements = []
            sqlPreviewWasTruncated = false
            rebuildMapping()
        } catch {
            parsedCSV = nil
            errorMessage = error.localizedDescription
        }
    }

    private func prepareSQLPreview() {
        let text = importText ?? ""
        if text.utf8.count > 5_000_000 {
            sqlPreviewCount = -1
            sqlPreviewStatements = Array(SQLScriptParser.parse(String(text.prefix(200_000))).prefix(5))
            sqlPreviewWasTruncated = true
            return
        }
        let statements = SQLScriptParser.parse(text)
        sqlPreviewCount = statements.count
        sqlPreviewStatements = Array(statements.prefix(5))
        sqlPreviewWasTruncated = false
    }

    private func rebuildMapping() {
        guard let csv = parsedCSV else { columnMapping = [:]; return }
        if createNewTable {
            columnMapping = [:]
            return
        }
        let headers = csv.headers(firstRowIsHeader: csvImport.firstRowIsHeader)
        var mapping: [String: Int] = [:]
        for column in targetTable?.columns ?? [] {
            mapping[column.name] = column.isGenerated ? -1 : headers.firstIndex {
                $0.caseInsensitiveCompare(column.name) == .orderedSame
            } ?? -1
        }
        columnMapping = mapping
    }

    private func mappingBinding(for column: String) -> Binding<Int> {
        Binding(
            get: { columnMapping[column] ?? -1 },
            set: { columnMapping[column] = $0 }
        )
    }

    private func csvSelectionBinding(for tableID: String) -> Binding<Bool> {
        Binding(
            get: { csvTableIDs.contains(tableID) },
            set: { isSelected in
                if isSelected { csvTableIDs.insert(tableID) } else { csvTableIDs.remove(tableID) }
            }
        )
    }

    private func clearMessages() {
        statusMessage = nil
        errorMessage = nil
        importFailures = []
    }

    private func matchesExportSearch(_ table: TableDescriptor) -> Bool {
        let query = exportSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return table.qualifiedName.localizedCaseInsensitiveContains(query)
            || table.name.localizedCaseInsensitiveContains(query)
            || (table.schema?.localizedCaseInsensitiveContains(query) ?? false)
    }

    private var formattedImportSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(importByteCount), countStyle: .file)
    }

    private var dateStamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: .now)
    }

    private func safeFilename(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return raw.components(separatedBy: forbidden).filter { !$0.isEmpty }.joined(separator: "_")
    }

    private func safeIdentifier(_ raw: String) -> String {
        var value = raw.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" }
        if value.first?.isNumber == true { value.insert("_", at: value.startIndex) }
        return String(value).isEmpty ? "imported_data" : String(value)
    }
}

struct TransferFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .commaSeparatedText, .data] }

    var data: Data
    var filename: String?

    init(data: Data, filename: String? = nil) {
        self.data = data
        self.filename = filename
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        filename = configuration.file.preferredFilename
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = filename
        return wrapper
    }
}
