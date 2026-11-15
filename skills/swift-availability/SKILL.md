---
name: swift-availability
description: >-
  Audit Swift files and Apple SDK symbols against minimum OS deployment targets
  (iOS, macOS, tvOS, watchOS, visionOS) using swift-mcp-server compiler checks
  and SDK lookups. Use when checking OS compatibility, `#available` guards, or
  deprecated Apple framework APIs.
---

# Swift OS Availability Audit

Use `swift-mcp-server`'s compiler-backed availability tools instead of guessing OS availability from memory.

## Workflow

1. **Look up individual Apple SDK APIs before writing new code**:
   - Call `api_availability` with `symbol` (`Type`, `Type.member`, or `Type.method(label:)`), optional `modules` (e.g., `["SwiftUI"]`, `["UIKit"]`), and `platform` (`iOS`, `macOS`, `tvOS`, `watchOS`, `visionOS`).
   - Use the returned introduction and deprecation versions to decide whether an `if #available(...)` / `@available(...)` guard is required.

2. **Type-check an existing Swift file against a target OS version**:
   - Call `check_availability` with `file_path`, `minimum_version` (e.g., `"15.0"`), and `platform`.
   - For SwiftPM packages, dependencies are compiled automatically; for Xcode projects, ensure the app target was built once in Xcode so DerivedData modules exist.

3. **Find the lowest OS version that compiles across a matrix**:
   - Call `check_availability_matrix` with `file_path`, `versions` (e.g., `["14", "15", "16", "17", "26"]`), and `platform`.
   - Review any reported **not checked** status (caused by missing module imports) before trusting a clean pass.

4. **Apply fixes and re-verify**:
   - Add `if #available(...)` / `@available(...)` guards or alternative APIs for flagged usages, then re-run `check_availability` or `check_availability_matrix` to confirm zero availability errors remain.
