import SwiftUI
import WidgetKit

struct SavedQueriesEntry: TimelineEntry {
    let date: Date
    let queries: [WidgetSnapshot.Query]
}

struct SavedQueriesProvider: TimelineProvider {
    func placeholder(in context: Context) -> SavedQueriesEntry {
        SavedQueriesEntry(date: .now, queries: [
            .init(id: UUID(), title: "Recent orders", connectionName: "Production", database: "shop"),
            .init(id: UUID(), title: "Slow queries", connectionName: "Analytics", database: "warehouse")
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (SavedQueriesEntry) -> Void) {
        completion(SavedQueriesEntry(date: .now, queries: WidgetSnapshot.load().queries))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SavedQueriesEntry>) -> Void) {
        let entry = SavedQueriesEntry(date: .now, queries: WidgetSnapshot.load().queries)
        completion(Timeline(entries: [entry], policy: .never))
    }
}

struct SavedQueriesWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SavedQueriesEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Saved Queries", systemImage: "text.page")
                .font(.headline)

            if entry.queries.isEmpty {
                Spacer()
                Text("Save a query in DB Connect to open it from here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(entry.queries.prefix(rowLimit)) { query in
                    Link(destination: URL(string: "db-connect://query/\(query.id.uuidString)")!) {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right.circle.fill")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(query.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(query.database.isEmpty
                                     ? query.connectionName
                                     : "\(query.connectionName) · \(query.database)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var rowLimit: Int {
        family == .systemLarge ? 6 : 3
    }
}

struct SavedQueriesWidget: Widget {
    let kind = "DBConnect.SavedQueries"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SavedQueriesProvider()) { entry in
            SavedQueriesWidgetView(entry: entry)
        }
        .configurationDisplayName("Saved Queries")
        .description("Quickly opens saved SQL in its DB Connect console.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
