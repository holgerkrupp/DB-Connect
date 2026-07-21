# Example Databases

This folder contains SQLite databases for local testing and demos in DB Connect.

- `example.db`: authors and books with foreign keys, a generated column, an index, a trigger, a view, and a table without a primary key.
- `warehouse.db`: products, customers, orders, and line items with a composite primary key and inventory-focused sample data.
- `monitoring.db`: service checks and incidents for exercising saved queries, monitors, and time-based filtering.

These files are intended for manual app testing and for automated SQLite driver tests.
