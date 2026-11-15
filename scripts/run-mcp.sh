#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PLUGIN_ROOT_DIR="${PLUGIN_ROOT:-$(dirname "$SCRIPT_DIR")}"
DATA_DIR="${PLUGIN_DATA:-${XDG_CACHE_HOME:-$HOME/.cache}/swift-mcp-server/plugin-data}"

export PATH="$PATH:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:/Applications/Xcode.app/Contents/Developer/usr/bin"

log() {
  printf '%s\n' "swift-mcp-server plugin: $*" >&2
}

has_transport_arg() {
  for arg in "$@"; do
    case "$arg" in
      --transport|--transport=*) return 0 ;;
    esac
  done
  return 1
}

exec_server() {
  bin_path="$1"
  shift
  if has_transport_arg "$@"; then
    exec "$bin_path" "$@"
  else
    exec "$bin_path" --transport stdio "$@"
  fi
}

is_source_newer_than() {
  target_bin="$1"
  if [ ! -e "$PLUGIN_ROOT_DIR/Package.swift" ]; then
    return 1
  fi
  if [ -n "$(find "$PLUGIN_ROOT_DIR/Package.swift" "$PLUGIN_ROOT_DIR/Sources" -newer "$target_bin" -print -quit 2>/dev/null)" ]; then
    return 0
  fi
  return 1
}

compute_source_hash() {
  (
    cd "$PLUGIN_ROOT_DIR"
    {
      if [ -f "Package.swift" ]; then
        printf '%s\n' "Package.swift"
        /usr/bin/shasum -a 256 "Package.swift"
      fi
      if [ -f "Package.resolved" ]; then
        printf '%s\n' "Package.resolved"
        /usr/bin/shasum -a 256 "Package.resolved"
      fi
      if [ -d "Sources" ]; then
        find "Sources" -type f | LC_ALL=C sort | while IFS= read -r file; do
          printf '%s\n' "$file"
          /usr/bin/shasum -a 256 "$file"
        done
      fi
    } | /usr/bin/shasum -a 256 | awk '{print $1}'
  )
}

resolve_swift() {
  if command -v swift >/dev/null 2>&1; then
    command -v swift
    return 0
  fi
  if [ -x /usr/bin/xcrun ] && /usr/bin/xcrun --find swift >/dev/null 2>&1; then
    /usr/bin/xcrun --find swift
    return 0
  fi
  return 1
}

release_lock() {
  rm -rf "$LOCK_DIR" 2>/dev/null || true
}

acquire_lock() {
  LOCK_DIR="$DATA_DIR/.build.lock"
  attempts=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if [ -f "$LOCK_DIR/pid" ]; then
      holder_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
      if [ -n "$holder_pid" ] && ! kill -0 "$holder_pid" 2>/dev/null; then
        rm -rf "$LOCK_DIR" 2>/dev/null || true
        continue
      fi
    fi
    attempts=$((attempts + 1))
    if [ "$attempts" -gt 300 ]; then
      log "Timed out waiting for Swift build lock at $LOCK_DIR"
      exit 1
    fi
    sleep 1
  done
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  trap release_lock EXIT INT TERM
}

build_into_plugin_data() {
  SWIFT_BIN="$(resolve_swift || true)"
  if [ -z "$SWIFT_BIN" ]; then
    log "Swift toolchain not found. Install Xcode or Swift 5.9+ and verify 'swift --version'."
    exit 1
  fi

  if [ ! -f "$PLUGIN_ROOT_DIR/Package.swift" ] || [ ! -d "$PLUGIN_ROOT_DIR/Sources" ]; then
    log "No prebuilt swift-mcp-server binary and no Package.swift/Sources under $PLUGIN_ROOT_DIR"
    exit 1
  fi

  mkdir -p "$DATA_DIR/bin"
  CACHED_BIN="$DATA_DIR/bin/swift-mcp-server"
  STAMP_FILE="$DATA_DIR/build.sha256"
  SOURCE_HASH="$(compute_source_hash)"

  if [ -x "$CACHED_BIN" ] && [ -f "$STAMP_FILE" ] && [ "$(cat "$STAMP_FILE" 2>/dev/null || true)" = "$SOURCE_HASH" ]; then
    return 0
  fi

  acquire_lock

  # Re-check after acquiring the lock in case a sibling process finished building.
  if [ -x "$CACHED_BIN" ] && [ -f "$STAMP_FILE" ] && [ "$(cat "$STAMP_FILE" 2>/dev/null || true)" = "$SOURCE_HASH" ]; then
    release_lock
    trap - EXIT INT TERM
    return 0
  fi

  log "Building swift-mcp-server release binary into $DATA_DIR (first run or plugin update)..."

  # Stage Package.swift + Sources into writable PLUGIN_DATA/src because installed
  # Antigravity plugins live in a read-only directory where SwiftPM cannot write Package.resolved.
  STAGE_SRC="$DATA_DIR/src"
  STAGE_NEXT="$DATA_DIR/src.next.$$"
  rm -rf "$STAGE_NEXT"
  mkdir -p "$STAGE_NEXT"
  cp "$PLUGIN_ROOT_DIR/Package.swift" "$STAGE_NEXT/Package.swift"
  if [ -f "$PLUGIN_ROOT_DIR/Package.resolved" ]; then
    cp "$PLUGIN_ROOT_DIR/Package.resolved" "$STAGE_NEXT/Package.resolved"
  elif [ -f "$STAGE_SRC/Package.resolved" ]; then
    cp "$STAGE_SRC/Package.resolved" "$STAGE_NEXT/Package.resolved"
  fi
  cp -R "$PLUGIN_ROOT_DIR/Sources" "$STAGE_NEXT/Sources"
  if [ -d "$PLUGIN_ROOT_DIR/Tests" ]; then
    cp -R "$PLUGIN_ROOT_DIR/Tests" "$STAGE_NEXT/Tests"
  else
    mkdir -p "$STAGE_NEXT/Tests/SwiftMCPServerTests"
    printf '// Placeholder so SwiftPM manifest loads when Tests/ is omitted\n' > "$STAGE_NEXT/Tests/SwiftMCPServerTests/Placeholder.swift"
  fi
  chmod -R u+w "$STAGE_NEXT"
  rm -rf "$STAGE_SRC"
  mv "$STAGE_NEXT" "$STAGE_SRC"

  SCRATCH_DIR="$DATA_DIR/build"
  "$SWIFT_BIN" build \
    --package-path "$STAGE_SRC" \
    --scratch-path "$SCRATCH_DIR" \
    --configuration release \
    --product swift-mcp-server >&2

  BIN_DIR="$("$SWIFT_BIN" build \
    --package-path "$STAGE_SRC" \
    --scratch-path "$SCRATCH_DIR" \
    --configuration release \
    --show-bin-path 2>/dev/null)"
  BUILT_BIN="$BIN_DIR/swift-mcp-server"

  if [ ! -x "$BUILT_BIN" ]; then
    log "Expected built binary missing at $BUILT_BIN"
    exit 1
  fi

  TMP_BIN="$CACHED_BIN.tmp.$$"
  cp "$BUILT_BIN" "$TMP_BIN"
  chmod 0755 "$TMP_BIN"
  mv -f "$TMP_BIN" "$CACHED_BIN"

  TMP_STAMP="$STAMP_FILE.tmp.$$"
  printf '%s\n' "$SOURCE_HASH" > "$TMP_STAMP"
  mv -f "$TMP_STAMP" "$STAMP_FILE"

  release_lock
  trap - EXIT INT TERM
}

# 1. Explicit binary override
if [ -n "${SWIFT_MCP_SERVER_BIN:-}" ] && [ -x "${SWIFT_MCP_SERVER_BIN}" ]; then
  exec_server "$SWIFT_MCP_SERVER_BIN" "$@"
fi

if [ "${SWIFT_MCP_FORCE_BUILD:-0}" != "1" ]; then
  # 2. Prebuilt binary bundled with the plugin (e.g. Marketplace or release bundle)
  for prebuilt in "$PLUGIN_ROOT_DIR/scripts/swift-mcp-server" "$PLUGIN_ROOT_DIR/bin/swift-mcp-server"; do
    if [ -x "$prebuilt" ]; then
      exec_server "$prebuilt" "$@"
    fi
  done

  # 3. Up-to-date local SwiftPM build in a development checkout
  LOCAL_BUILD_BIN="$PLUGIN_ROOT_DIR/.build/release/swift-mcp-server"
  if [ -x "$LOCAL_BUILD_BIN" ] && ! is_source_newer_than "$LOCAL_BUILD_BIN"; then
    exec_server "$LOCAL_BUILD_BIN" "$@"
  fi
fi

# 4. Build and cache inside writable PLUGIN_DATA
build_into_plugin_data
exec_server "$DATA_DIR/bin/swift-mcp-server" "$@"
