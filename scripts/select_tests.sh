#!/bin/bash
# Test-selection classifier for the iOS Build workflow.
#
# Reads a newline-separated list of changed paths on stdin and prints
# GitHub-Actions-style key=value lines on stdout:
#
#   mode=<full|heavy|ui|core|none>
#   skip_args=<xcodebuild -skip-testing flags, may be empty>
#   reason=<one-line human explanation>
#
# Human-readable detail goes to stderr so stdout stays machine-clean.
#
# Modes:
#   full  - run the entire suite (default whenever classification is
#           ambiguous, shared core code changed, or CI itself changed)
#   heavy - fast unit tests + the heavy engine suites (embedded
#           Python/JSC, FFmpeg remux/transcode); UI tests skipped
#   ui    - fast unit tests + UI tests; heavy engine suites skipped
#   core  - fast unit tests only; heavy suites and UI tests skipped
#   none  - documentation-only change; no build/test steps at all
#
# The heavy suites are the expensive part of the suite (each
# EmbeddedPythonRuntimeTests case boots CPython in the simulator,
# FFmpegTranscodeTests runs real VideoToolbox encodes), so they only
# run when the code they exercise actually changed.
#
# Usage:
#   git diff --name-only BASE HEAD | scripts/select_tests.sh
#   FORCE_FULL=1 scripts/select_tests.sh < changed.txt
#   scripts/select_tests.sh --self-test
set -euo pipefail

HEAVY_CLASSES=(
  "VYRATests/EmbeddedPythonRuntimeTests"
  "VYRATests/FFmpegRemuxTests"
  "VYRATests/FFmpegTranscodeTests"
)

skip_args_for() {
  # $1 = mode
  local args=""
  case "$1" in
    core|ui)
      local c
      for c in "${HEAVY_CLASSES[@]}"; do
        args="$args -skip-testing:$c"
      done
      ;;
  esac
  case "$1" in
    core|heavy)
      args="$args -skip-testing:VYRAUITests"
      ;;
  esac
  echo "${args# }"
}

classify() {
  # stdin: changed paths. Echoes "<mode>\t<reason>".
  local path
  local saw_any=0 saw_code=0
  local heavy=0 ui=0 core=0
  local full_reason=""
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    saw_any=1
    case "$path" in
      # Documentation: never needs the test workflow.
      Documentation/*|*.md|LICENSE|LICENSE.*)
        ;;
      # CI definitions and project configuration: anything could
      # change; run everything.
      .github/workflows/*)
        full_reason="CI workflow definition changed ($path)" ;;
      VYRA.xcodeproj/*)
        full_reason="Xcode project configuration changed ($path)" ;;
      # Shared core code used across the app: full suite.
      VYRA/Models/*|VYRA/Services/*)
        full_reason="shared core code changed ($path)" ;;
      # Vendor bootstrap inputs feed the embedded engines directly.
      scripts/bootstrap_python.sh|scripts/bootstrap_ffmpeg.sh)
        heavy=1; saw_code=1 ;;
      # Any other script can change how CI behaves: full suite.
      scripts/*)
        full_reason="CI helper script changed ($path)" ;;
      # The embedded engines and their bridges.
      PythonBridge/*|FFmpegBridge/*)
        heavy=1; saw_code=1 ;;
      # The heavy test files/fixtures themselves.
      VYRATests/YtDlpEngineTests.swift|VYRATests/FFmpegRemuxTests.swift|\
      VYRATests/FFmpegTranscodeTests.swift|VYRATests/Fixtures/*)
        heavy=1; saw_code=1 ;;
      # App UI code and the UI tests themselves.
      VYRA/Views/*|VYRA/Components/*|VYRA/App/*|VYRAUITests/*)
        ui=1; saw_code=1 ;;
      # Everything else in the app or unit tests: fast tests cover it.
      VYRA/*|VYRATests/*)
        core=1; saw_code=1 ;;
      # Anything unrecognised: do not guess, run everything.
      *)
        full_reason="unclassified path changed ($path)" ;;
    esac
  done

  if [ -n "$full_reason" ]; then
    echo -e "full\t$full_reason"
  elif [ "$saw_any" -eq 0 ]; then
    echo -e "full\tno changed paths supplied; running everything to be safe"
  elif [ "$saw_code" -eq 0 ]; then
    echo -e "none\tdocumentation-only change"
  elif [ "$heavy" -eq 1 ] && [ "$ui" -eq 1 ]; then
    echo -e "full\theavy engine code and UI code both changed; together they cover the whole suite"
  elif [ "$heavy" -eq 1 ]; then
    echo -e "heavy\tembedded-engine code changed; UI tests unchanged area, skipped"
  elif [ "$ui" -eq 1 ]; then
    echo -e "ui\tUI code changed; heavy engine suites unchanged area, skipped"
  else
    echo -e "core\tapp/test code changed outside engine and UI areas; fast unit tests only"
  fi
}

run_case() {
  # $1 = expected mode, $2 = description, $3 = newline-separated paths
  local got
  got="$(printf '%s\n' "$3" | classify | cut -f1)"
  if [ "$got" = "$1" ]; then
    echo "ok   [$1] $2"
  else
    echo "FAIL [$2] expected=$1 got=$got" >&2
    SELF_TEST_FAILURES=$((SELF_TEST_FAILURES + 1))
  fi
}

self_test() {
  SELF_TEST_FAILURES=0
  run_case none "docs only" \
    "Documentation/HANDOFF/PHASE_4_HANDOFF.md
README.md"
  run_case core "view model change" \
    "VYRA/ViewModels/HomeViewModel.swift"
  run_case core "fast unit test change" \
    "VYRATests/ViewModelTests.swift"
  run_case heavy "python bridge change" \
    "PythonBridge/pybridge/vyra_bridge.py"
  run_case heavy "ffmpeg bootstrap change" \
    "scripts/bootstrap_ffmpeg.sh"
  run_case heavy "heavy test file change" \
    "VYRATests/FFmpegRemuxTests.swift"
  run_case heavy "runtime test fixtures change" \
    "VYRATests/Fixtures/player.js"
  run_case ui "settings view change" \
    "VYRA/Views/Settings/SettingsView.swift"
  run_case ui "tab bar component change" \
    "VYRA/Components/GlassTabBar.swift"
  run_case ui "UI test change" \
    "VYRAUITests/VYRAUITests.swift"
  run_case full "shared service change" \
    "VYRA/Services/YtDlpRuntime.swift"
  run_case full "workflow change" \
    ".github/workflows/ios-build.yml"
  run_case full "project config change" \
    "VYRA.xcodeproj/project.pbxproj"
  run_case full "bridge + UI change covers everything" \
    "PythonBridge/pybridge/vyra_bridge.py
VYRA/Views/Settings/SettingsView.swift"
  run_case full "unknown path" \
    "tools/something-new.txt"
  run_case full "empty diff" \
    ""
  if [ "$SELF_TEST_FAILURES" -gt 0 ]; then
    echo "select_tests.sh self-test: $SELF_TEST_FAILURES failure(s)" >&2
    return 1
  fi
  echo "select_tests.sh self-test: all cases passed"
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit 0
fi

if [ "${FORCE_FULL:-}" = "1" ]; then
  mode="full"
  reason="full suite forced (workflow_dispatch input or manual override)"
else
  result="$(classify)"
  mode="$(printf '%s' "$result" | cut -f1)"
  reason="$(printf '%s' "$result" | cut -f2)"
fi

echo "Test selection: mode=$mode ($reason)" >&2
echo "mode=$mode"
echo "skip_args=$(skip_args_for "$mode")"
echo "reason=$reason"
