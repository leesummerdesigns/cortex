---
tags: [swift, swiftui, layout]
---
# SwiftUI Layout Rules

1. **Parent proposes a size, child chooses its size, parent places the child.** Every modifier wraps the view and takes part in this.
2. `.frame(width:)` changes the *proposal*; the child may still be smaller. Use `maxWidth: .infinity` to fill.
3. `.fixedSize()` makes a view ignore the proposal and use its ideal size (stops truncation).
4. Order matters: `.padding().background()` ≠ `.background().padding()`.
5. Prefer stacks, `Grid`, `ViewThatFits` and `containerRelativeFrame` over `GeometryReader`, which takes all offered space.
6. Custom arrangements: implement the `Layout` protocol (`sizeThatFits`, `placeSubviews`) instead of measuring with preferences.
7. `.layoutPriority(1)` decides who keeps space when a stack runs out.
