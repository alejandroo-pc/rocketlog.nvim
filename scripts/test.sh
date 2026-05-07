#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

NVIM_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nvim"
PLENARY_PATH="$NVIM_DATA_DIR/lazy/plenary.nvim"
OUTPUT_FILE="$(mktemp "${TMPDIR:-/tmp}/rocketlog-tests.XXXXXX")"
START_SECONDS=$(date +%s)

cleanup() {
  rm -f "$OUTPUT_FILE"
}
trap cleanup EXIT

fail() {
  echo "$1"
  exit 1
}

count_test_files() {
  find "$REPO_ROOT/tests" -type f -name '*_spec.lua' | wc -l | tr -d '[:space:]'
}

count_declared_tests() {
  grep -R "^[[:space:]]*it(" "$REPO_ROOT/tests" 2>/dev/null | wc -l | tr -d '[:space:]'
}

sum_plenary_count() {
  local label="$1"

  awk -v label="$label" '
    BEGIN {
      escape = sprintf("%c", 27)
      carriage_return = sprintf("%c", 13)
    }

    {
      line = $0
      gsub(carriage_return, "", line)
      gsub(escape "\\[[0-9;?]*[ -/]*[@-~]", "", line)
    }

    line ~ "^[[:space:]]*" label "[[:space:]]*:?[[:space:]]*[0-9]+" {
      sub("^[[:space:]]*" label "[[:space:]]*:?[[:space:]]*", "", line)
      sub("[^0-9].*$", "", line)
      total += line + 0
    }

    END { print total + 0 }
  ' "$OUTPUT_FILE"
}

count_failed_test_lines() {
  awk '
    BEGIN {
      escape = sprintf("%c", 27)
      carriage_return = sprintf("%c", 13)
    }

    {
      line = $0
      gsub(carriage_return, "", line)
      gsub(escape "\\[[0-9;?]*[ -/]*[@-~]", "", line)
    }

    line ~ /^[[:space:]]*Fail[[:space:]]+\|\|/ { total += 1 }

    END { print total + 0 }
  ' "$OUTPUT_FILE"
}

repeat_char() {
  local char="$1"
  local count="$2"
  local output=""

  while [ "$count" -gt 0 ]; do
    output="$output$char"
    count=$((count - 1))
  done

  printf '%s' "$output"
}

print_metric() {
  local label="$1"
  local value="$2"
  local total="$3"
  local width=28
  local percent=0
  local filled=0
  local empty=28

  if [ "$total" -gt 0 ]; then
    percent=$((value * 100 / total))
    filled=$((value * width / total))
    empty=$((width - filled))
  fi

  printf '%-16s %4s/%-4s %3s%% [%s%s]\n' \
    "$label:" \
    "$value" \
    "$total" \
    "$percent" \
    "$(repeat_char '#' "$filled")" \
    "$(repeat_char '-' "$empty")"
}

print_failed_tests() {
  local failures
  failures=$(awk '
    /^Fail[[:space:]]+\|\|/ {
      sub(/^Fail[[:space:]]+\|\|[[:space:]]*/, "")
      print "  - " $0
    }
  ' "$OUTPUT_FILE")

  if [ -n "$failures" ]; then
    echo
    echo "Failed tests:"
    printf '%s\n' "$failures"
  fi
}

print_summary() {
  local exit_code="$1"
  local duration_seconds
  local reported_successes
  local reported_failures
  local reported_errors
  local reported_pending
  local reported_total
  local status="PASS"

  duration_seconds=$(($(date +%s) - START_SECONDS))
  reported_successes=$(sum_plenary_count "Success")
  reported_failures=$(sum_plenary_count "Failed")
  reported_errors=$(sum_plenary_count "Errors")
  reported_pending=$(sum_plenary_count "Pending")
  reported_total=$((reported_successes + reported_failures + reported_errors + reported_pending))

  if [ "$reported_total" -eq 0 ] && [ "$exit_code" -eq 0 ] && [ "$DECLARED_TESTS" -gt 0 ]; then
    reported_successes="$DECLARED_TESTS"
    reported_total="$DECLARED_TESTS"
  fi

  if [ "$reported_total" -eq 0 ] && [ "$exit_code" -ne 0 ]; then
    reported_failures=$(count_failed_test_lines)
    reported_total="$DECLARED_TESTS"
  fi

  if [ "$exit_code" -ne 0 ] || [ "$reported_failures" -gt 0 ] || [ "$reported_errors" -gt 0 ]; then
    status="FAIL"
  fi

  echo "--------------------------------------------------------------------------------"
  echo "Test Summary"
  echo "--------------------------------------------------------------------------------"
  printf '%-16s %s\n' "Status:" "$status"
  printf '%-16s %ss\n' "Duration:" "$duration_seconds"
  printf '%-16s %s\n' "Test files:" "$TOTAL_TEST_FILES"
  printf '%-16s %s\n' "Declared tests:" "$DECLARED_TESTS"
  printf '%-16s %s\n' "Reported total:" "$reported_total"
  echo
  print_metric "Passed" "$reported_successes" "$reported_total"
  print_metric "Failed" "$reported_failures" "$reported_total"
  print_metric "Errors" "$reported_errors" "$reported_total"
  print_metric "Pending/skipped" "$reported_pending" "$reported_total"
  print_failed_tests
  echo "--------------------------------------------------------------------------------"

  if [ "$status" = "FAIL" ]; then
    return 1
  fi

  return 0
}

[ -f "$REPO_ROOT/tests/minimal_init.lua" ] || fail "Missing: $REPO_ROOT/tests/minimal_init.lua"
[ -d "$PLENARY_PATH" ] || fail "Plenary not found at: $PLENARY_PATH
Install it in your normal Neovim config with Lazy, then run :Lazy sync"
command -v nvim >/dev/null 2>&1 || fail "nvim was not found in PATH"

TOTAL_TEST_FILES=$(count_test_files)
DECLARED_TESTS=$(count_declared_tests)

cd "$REPO_ROOT"

echo "Running rocketlog.nvim tests..."
echo "Test files: $TOTAL_TEST_FILES"
echo "Declared tests: $DECLARED_TESTS"
echo "--------------------------------------------------------------------------------"

set +e
nvim --headless -u "$REPO_ROOT/tests/minimal_init.lua" \
  -c "PlenaryBustedDirectory $REPO_ROOT/tests { minimal_init = '$REPO_ROOT/tests/minimal_init.lua' }" \
  -c "qa" 2>&1 | tee "$OUTPUT_FILE"
NVIM_EXIT=${PIPESTATUS[0]}
set -e

print_summary "$NVIM_EXIT"
