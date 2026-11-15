---
name: swift-lsp
description: >-
  Navigate, diagnose, and safely refactor Swift and Objective-C/C/C++ code using
  swift-mcp-server SourceKit-LSP tools. Use for compiler-accurate definitions,
  references, protocol conformances, call/type hierarchies, fix-its, and
  workspace-wide symbol renames.
---

# Swift Semantic Navigation & Refactoring

Use `swift-mcp-server` tools backed by SourceKit-LSP whenever compiler precision matters more than text search.

## Guidelines

- **0-based coordinates**: Convert 1-based editor line/column numbers to 0-based `line` and `character` values before calling position-based tools.
- **Locating symbols**:
  - Within a file: `find_symbols` (`file_path`, `name_pattern`).
  - Across the workspace: `search_workspace_symbols` (`query`, plus optional `workspace_path` if no file tool has run yet).
- **Tracing relationships**:
  - `get_definition` and `get_hover_info` for exact declaration targets and inferred types/docs.
  - `find_references` for every compiler-verified usage across the workspace.
  - `get_implementations` and `type_hierarchy` (`supertypes` / `subtypes`) for protocol conformances and class inheritance.
  - `call_hierarchy` (`incoming` / `outgoing`) for caller and callee graphs.
- **Diagnostics, fix-its, and safe edits**:
  - `get_diagnostics` to inspect compiler errors and warnings on a file.
  - `code_actions` (`file_path`, `line`, optional `apply` title) to list or apply compiler fix-its on disk.
  - `rename_symbol` to rename a symbol cleanly across all workspace files without touching comments, strings, or unrelated overloads.
  - `format_document` to inspect formatting edits from SourceKit-LSP.
