#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}"
TMP_DIR="$(mktemp -d "$TMP_ROOT/loom-docc.XXXXXX")"
SYMBOLGRAPH_FILTER_DIR="$TMP_DIR/symbolgraph"
DUMP_STDOUT="$TMP_DIR/dump-symbol-graph.stdout"
DUMP_STDERR="$TMP_DIR/dump-symbol-graph.stderr"
OUTPUT_PATH="$ROOT_DIR/docs"
HOSTING_BASE_PATH="${DOCC_HOSTING_BASE_PATH:-Loom}"
HOSTING_BASE_PATH="${HOSTING_BASE_PATH#/}"

trap 'rm -rf "$TMP_DIR"' EXIT

rm -rf "$OUTPUT_PATH"
mkdir -p "$SYMBOLGRAPH_FILTER_DIR"

dump_exit=0
if ! swift package dump-symbol-graph --minimum-access-level public >"$DUMP_STDOUT" 2>"$DUMP_STDERR"; then
  dump_exit=$?
fi

SYMBOLGRAPH_DIR="$(sed -n 's/^Files written to //p' "$DUMP_STDOUT" | tail -n 1)"
if [[ -z "$SYMBOLGRAPH_DIR" ]]; then
  SYMBOLGRAPH_DIR="$(find "$ROOT_DIR/.build" -type d -name symbolgraph -print | head -n 1)"
fi
LOOM_SYMBOLGRAPH="$SYMBOLGRAPH_DIR/Loom.symbols.json"

if [[ ! -f "$LOOM_SYMBOLGRAPH" ]]; then
  cat "$DUMP_STDOUT"
  cat "$DUMP_STDERR" >&2
  echo "Expected public Loom symbol graph at '$LOOM_SYMBOLGRAPH' but it was not produced." >&2
  if (( dump_exit != 0 )); then
    exit "$dump_exit"
  fi
  exit 1
fi

if (( dump_exit != 0 )); then
  if grep -Eq "Failed to emit symbol graph for '.*Tests'" "$DUMP_STDERR"; then
    echo "Ignoring SwiftPM test-target symbol graph failure because the Loom public symbol graph was emitted." >&2
  else
    cat "$DUMP_STDOUT"
    cat "$DUMP_STDERR" >&2
    exit "$dump_exit"
  fi
fi

cp "$LOOM_SYMBOLGRAPH" "$SYMBOLGRAPH_FILTER_DIR/"

xcrun docc convert \
  "$ROOT_DIR/Sources/Loom/Loom.docc" \
  --additional-symbol-graph-dir "$SYMBOLGRAPH_FILTER_DIR" \
  --output-dir "$OUTPUT_PATH" \
  --transform-for-static-hosting \
  --hosting-base-path "$HOSTING_BASE_PATH" \
  --fallback-display-name Loom \
  --fallback-bundle-identifier loom.Loom

touch "$OUTPUT_PATH/.nojekyll"
