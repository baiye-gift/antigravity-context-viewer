---
name: context-viewer
description: Open the Context Viewer side pane or inspect conversation context window and token usage metrics.
---

# Context Viewer

Context Viewer is a native Antigravity sidecar UI plugin that inspects local conversation transcripts (`transcript.jsonl`) read-only and displays context window occupancy, cache hit ratio, per-step token deltas, content composition, and multi-session token history.

## Opening the Side Pane

When the user wants to open or view the Context Viewer dashboard, surface a clickable pill link in your response:

```markdown
[Context Viewer](sidecar://context-viewer/viewer/)
```

Only emit the `sidecar://` pill if the plugin is enabled.

## Managing the Plugin

To enable, disable, or uninstall the plugin, direct the user to its Customizations page:

```markdown
[Context Viewer](customization://context-viewer)
```

## Metric Definitions

- **Active Context Window**: `input_tokens + cache_read_tokens` on the latest `PLANNER_RESPONSE` step.
- **Cache Hit Rate**: `cache_read_tokens / (input_tokens + cache_read_tokens)`.
- **Step Delta (`+Δ`)**: Change in active context window size compared to the preceding `PLANNER_RESPONSE` step.
- **When nearing limit**: If active context occupancy reaches 70%+, remind the user they can run `/compact` to summarize and free up context space.
