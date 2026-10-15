---
tags: [ai, prompting, context]
---
# Context Engineering Principles

The quality of an AI answer is bounded by the context it receives.

- **Right context, not more context.** Irrelevant memories dilute attention and cause wrong answers. Load identity always, project context when relevant, details on demand.
- **Structure beats prose:** goal → constraints → relevant facts → examples → output format.
- **Put instructions where they apply.** Global style rules in core; task rules with the task.
- **Show, don't describe:** one good example of the desired output beats three paragraphs of description.
- **Make success verifiable:** ask for something you can check (tests, sources, a specific format).
- **Refresh, don't accumulate:** start new sessions with a compact summary instead of dragging long histories along.
