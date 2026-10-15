---
tags: [swift, swiftui, data-flow]
---
# Observation in SwiftUI

Since iOS 17 / macOS 14, use the `@Observable` macro instead of `ObservableObject` + `@Published`.

```swift
@Observable final class Store {
    var items: [Item] = []
    var filter = ""
}
```

- **Owning** an observable: `@State private var store = Store()` in the view (or the `App`) that creates it.
- **Passing down:** plain property (`let store: Store`) — SwiftUI tracks only the properties a view actually reads.
- **Bindings** to its properties: `@Bindable var store: Store`, then `$store.filter`.
- **Environment:** `.environment(store)` and `@Environment(Store.self) private var store`.
- Use `@ObservationIgnored` for properties that must not trigger updates (caches, weak references).
- Views re-render only when a property they read changes — prefer small views that read little.
