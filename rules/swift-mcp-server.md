---
trigger: glob
globs: "**/*.swift, Package.swift, **/*.xcodeproj/**, **/*.xcworkspace/**, **/*.m, **/*.mm, **/*.h"
description: Guidelines for using swift-mcp-server SourceKit-LSP and OS availability tools on Swift and Apple platform codebases.
---

# Swift MCP Server Guidelines

When working on Swift, SwiftUI, Objective-C, or Apple SDK tasks with `swift-mcp-server` available:

- **Use compiler semantics over text heuristics** for navigation, impact analysis, and refactoring: `find_symbols`, `search_workspace_symbols`, `find_references`, `get_definition`, `get_implementations`, `get_hover_info`, `call_hierarchy`, `type_hierarchy`, `get_diagnostics`, `code_actions`, `format_document`, and `rename_symbol`.
- **Coordinates are 0-based**: `line` and `character` arguments are 0-based across all position tools (`code_actions` takes a 0-based `line`).
- **Verify OS deployment target compatibility** before adopting or shipping Apple SDK APIs: use `api_availability` to look up SDK introduction/deprecation versions, and `check_availability` / `check_availability_matrix` to type-check files against target OS versions.
- **Keep C-family support in mind**: Objective-C/C/C++ files routed through `clangd` require `compile_commands.json` in the project root.
