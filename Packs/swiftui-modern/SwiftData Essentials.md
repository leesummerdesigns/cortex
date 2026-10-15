---
tags: [swift, swiftdata, persistence]
---
# SwiftData Essentials

```swift
@Model final class Measurement {
    var name: String
    var value: Double
    var date: Date
    init(name: String, value: Double, date: Date = .now) { … }
}
```

- Set up once: `.modelContainer(for: Measurement.self)` on the `WindowGroup`.
- Read: `@Query(sort: \Measurement.date, order: .reverse) private var measurements: [Measurement]`.
- Filter: `#Predicate<Measurement> { $0.name == "HbA1c" }` (build queries in `init` when they depend on view inputs).
- Write: `@Environment(\.modelContext) private var context` → `context.insert(m)`, `context.delete(m)`; autosave is on by default.
- Relationships: `@Relationship(deleteRule: .cascade) var entries: [Entry] = []`.
- Schema changes: version with `VersionedSchema` and a `SchemaMigrationPlan` before shipping updates that change models.
- Keep `@Model` types free of UI logic; put derived values in computed properties.
