# AGENTS.md

## Code Intelligence & Multi-Agent Workflow Guidelines

### Tool Selection Policy
- **Semantic Code Operations (Primary):** Use the `swift-lsp` plugin (SourceKit-LSP, enabled in `.claude/settings.json`) through the `LSP` tool to explore code structure, locate definitions, and trace references in Swift files. Avoid reading entire files into context unless strictly necessary.
  - Map a file's structs, classes, and functions: `documentSymbol`.
  - Jump to a definition: `goToDefinition`. Read a type's signature or docs: `hover`.
  - Trace usages before changing anything: `findReferences`. Trace callers: `incomingCalls`. Find protocol conformers: `goToImplementation`.
  - Positions are 1-based `line` and `character`; point `character` at the symbol name, not at the `func`/`let` keyword.
  - Find a declaration line first with `rg -n "(struct|class|enum|protocol|func|var|let) <Name>\b" Sources`, then run `LSP` on that line. Avoid `workspaceSymbol`: SourceKit-LSP matches fuzzily and returns hundreds of results.
  - Cross-file results come from the SwiftPM index. Run `swift build` first if they look stale or empty.
  - **Load it up front (Turn-1 Prefix Freeze & Parent Context Diet):** `LSP` and lazy MCP tools (e.g. `ctx_execute`) alter tool context when loaded mid-run. On any audit, bug hunt, refactor, or `/code-medic` run, call `ctx_resume({})` directly on Turn 1 when active, load `LSP` (`ToolSearch` `select:LSP`), required lazy MCP schemas, and parent-needed `SKILL.md` files on Turn 1—skipping worker-only skills (e.g. 400-line `test-driven-development/SKILL.md`) when Phase 3 is delegated—and never edit `AGENTS.md`, rules, or `SKILL.md` mid-session so the prompt prefix stays cached.
  - **Split of work:** `rg` sweeps for patterns across many files (`?? 0`, divisions, `Int(`, string literals). `LSP` answers symbol questions: a function's line range (`documentSymbol`), whether a finding is reachable (`incomingCalls`), who consumes a type or property (`findReferences`), and exact initializer signatures for tests (`hover`).
  - **Before changing a type, property, or row identity** (e.g. an `id`, a dictionary key, a struct field), run `findReferences` on it **and** on the collection that carries it (e.g. `GitCostReport.branches`), and list every consumer in the plan. A consumer that assumed the old uniqueness or shape is a regression waiting to happen.
- **Text & Regex Search (Secondary):** Use `rg` (ripgrep) for string literals, error messages, comments, logs, and non-Swift files (e.g., Markdown, JSON, YAML).
- **Surgical Code Editing:** Use `Edit` with an exact `old_string` scoped to the symbol being changed. Use `Write` only for new files or deliberate full rewrites.

### Main Agent Responsibilities (Orchestrator)
1. **Symbol Mapping & Phase-1 Verification Cap (`<= 3` Turns, `< 65K–75K` Tokens Entering Plan):** Summarize `wc -l` inside `ctx_execute` instead of reading large raw file lists, trust research subagents' reported signatures and repros, and read at most 1–3 finalist slices (`<= 3` verification turns) in the parent rather than running 15+ follow-up grep/read turns in parent context.
2. **Dry-Reference Scoped Delegation (`<= 1,500` Output Tokens / Dispatch Turn):** Put detailed task specs, verified signatures, and shared TDD rules inside `docs/plans/...`, and keep each `invoke_subagent` prompt to `<= 15–20` lines referencing the absolute plan path + task number (plus target `file:line`). Never emit `10K+` output-token dispatch turns that risk expiring the 5-minute cache TTL during generation/worktree creation.
3. **Context Cap & Phase-3 Coordinator Handoff (`< 150K` Tokens, `< 4m` Waits):** Keep parent context `<= 65K–75K` target / `150K` hard cap (above `~150K–200K` tokens, opportunistic implicit prefix caches can drop to `0%`). In unattended runs (`/code-medic` or multi-bug fixes) where `/compact` cannot be run between planning and execution, if parent context is `>= 75K` tokens or Phase 3 dispatches `2+` parallel `Workspace: "share"` TDD workers, delegate Phase 3 orchestration (spawning `Workspace: "share"` workers, yielding across wakeups, batch-harvesting files via `cp`, and running Phase 3 verification) to **one fresh-context Phase-3 Coordinator `self` subagent** (`Workspace: "inherit"`, `< 20K` initial prompt) returning a single `<= 20`-line summary. Never block synchronously `>= 4m` inside a tool call.
4. **Batch Phase 4 + Phase 5 Git Operations (`<= 2–3` Parent Turns):** After Phase-3 Coordinator handoff, collapse branch verification + atomic commits + `git fetch`/`rebase` + background post-rebase suite launch into a single shell turn, and `--ff-only` merge + branch cleanup into one wakeup turn (avoiding 8+ separate `130K+`-token turns on opportunistic-cache models).

### Subagent Responsibilities (Workers)
1. **Focused Context:** Read only the assigned symbol bodies: find the symbol's range with `documentSymbol`, then `Read` with `offset`/`limit` (`<= 80` lines).
2. **Isolated Execution:** Make changes strictly within the assigned symbols using `Edit`.
3. **Reference Verification:** Before modifying a function signature or struct property, run `LSP` `findReferences` to make sure callers are updated or unaffected.

### Concurrency & Conflict Prevention
- **Parallel Disjoint-File Workers (`Workspace: "share"`):** Never run multiple subagents concurrently on the **same file** or shared `.build/` directory. When `2+` tasks touch disjoint source and test files, dispatch workers in parallel in a single turn with `Workspace: "share"` (isolated git worktrees), yield with zero tool calls on intermediate wakeups, and harvest owned files in one batch once the wave completes.
- **Sequential / Grouped Fallback & `<= 20`-Line Returns:** If multiple tasks modify the same file, either assign that file to a single worker or run overlapping workers sequentially. Enforce a `<= 20`-line plain return contract per subagent (no raw build/test stdout).


## Baton Pass (Pre-Compaction & Exploration Protocol — Parent Baton + Subagent Shards)

**Objective:** Prevent silent auto-compaction or `/compact` from wiping verified `file:line` evidence, dead ends, and rationale, while keeping subagent runs fast, small, and inside the 5-minute prompt-cache TTL.
**Scope:** The **Parent / Orchestrator Agent** owns `inventory.md`; read-only **subagents** (`Agent` tool, e.g. `Explore`) execute bounded shards and write **no** baton files.

### 1. Initialize the Parent Baton Early (Mandatory Hard Gate)
For **any** debugging session (`/systematic-debugging`), bug hunt, audit (`/code-medic`), code review, or multi-file task (`3+` files), the **Main / Orchestrator Agent MUST** create `inventory.md` in the session artifacts directory (`<appDataDir>/brain/<conversation-id>/inventory.md`, or `<scratchpad>/inventory.md` when no session artifact directory is provided—**never** inside the repo working tree) **before** opening a 3rd source file (even when following an active `SKILL.md`). Subagents write **no** baton files.

### 2. Input-LOC Sharding & Single-Report Subagent Contract
- Prefer `LSP` `documentSymbol` and targeted line ranges (`Read` with `offset`/`limit` `<= 80` lines) over whole-file reads (`> 200` lines).
- Cap command/test output (`swift test --filter <Target>`, failure lines only)—never dump full build/test logs into context.
- **Shard by Input Size Before Dispatch:** Summarize `wc -l` on target files inside `ctx_execute` first and give **each read-only subagent `<= 3–4 files` / `<= 1,200 LOC` on opportunistic implicit-cache models** (so Phase-1 waves finish inside `< 2.5–3m` before `~3–4.5m` implicit-cache eviction; `<= 5 files` / `<= 1,800 LOC` max otherwise, or **1 call-chain / hypothesis**). Run baseline checks locally or with `run_in_background: true` during heavy sweeps so no straggler busts the 5-minute prompt-cache TTL.
- Every subagent prompt **MUST** enforce:
  1. **Two-Pass Triage -> Surgical Slice Reads (No Whole-File Tiling, `<= 12` Reads Max):** Skip re-reading `README.md` or `docs/agent-notes/*` inside subagents (pass domain invariants in the prompt). Run one `rg -n` pattern + `func`/`struct` header pass (or `LSP` `documentSymbol`) on the assigned files (`<= 40` output lines combined) to isolate **only** the 2–4 suspect symbol ranges, then read **only** those candidate ranges (`<= 80` lines per slice; **never** tile `1-80, 81-160, ...` end-to-end across a whole file, and cap total `read_file` calls at `<= 12`). Check caller reachability outside your slice via **one** `rg -n -C 6 "<Symbol>" Sources/` command (or `LSP` `incomingCalls`) instead of opening external files with `read_file`.
  2. **Single Report & Bail-and-Relay Valve (`<= 4` Model Turns, No Subagent Baton, No Mid-Run Pings):** Write no baton/temp files and never chase cross-module files with `read_file`. Return **one** final report when finished — or **bail and exit within `<= 4` model turns (`< 2.5m`)** if unread candidates remain — with `Confirmed`, `Ruled-Out`, and `Remaining` sections, so the parent updates `inventory.md` and spawns a clean-context relay subagent on `Remaining` if needed.

### 3. Rolling Checkpoints on Parent (Beat Auto-Compaction)
Never hold findings solely in memory until the end. Update the parent `inventory.md` **after each completed subagent wave or investigated area** and **always before `/compact` or phase transitions** (never on intermediate parallel wakeups; use surgical `edit_file` diffs rather than full-file `write_file` rewrites) with:
- **Goal & Verified State:** Scope, active branch, `git status -s`, last test/repro command & result.
- **Confirmed Findings:** Severity, exact `file:line`, trigger scenario, expected vs. actual, repro evidence, suggested fix.
- **Ruled-Out / Dead Ends:** Checked files/hypotheses that are safe or failed (with 1-line reason).
- **Remaining Queue:** Unchecked targets in priority order, or `READY TO REPORT`.

### 4. Post-Compaction Pickup
- **After compaction or session resume:** Read the parent `inventory.md` **first on Turn 1**. Trust `Confirmed Findings` and `Ruled-Out` (never re-read ruled-out files), then immediately write the report or continue from the top of `Remaining Queue`.


## Test Execution

- **Always run Swift tests serially:** use `swift test --no-parallel` (add `--filter <Suite>/<test>` for targeted runs). Plain parallel `swift test` deadlocks in this repo and hangs indefinitely.
- **Never block synchronously `>= 4m` (protect 5m cache TTL):** Never run the full `swift test --no-parallel` suite or `bash scripts/make-app.sh` inside a synchronous `ctx_execute` wrapper. Launch full-suite and app-bundle builds in the background (`> /tmp/tokaz-test.log 2>&1`) so the turn completes immediately and wakes reactively, then read only failure lines (`grep -E '✘|error:|Test run with'`).
- A targeted `--filter` run (`< 30s`) is fine synchronously for RED/GREEN checks. A test that traps (e.g. integer overflow, signal 5) kills the whole process, so run such tests one at a time by name.
