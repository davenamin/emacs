#!/bin/bash
# Run a simulator build of Emacs.app and check that it works.
# Usage: simulator-test.sh APP BUNDLE-ID OUTPUT-DIRECTORY

# Copyright (C) 2026 Free Software Foundation, Inc.

# This file is part of GNU Emacs.

# GNU Emacs is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# GNU Emacs is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

# APP must have been built with "make ios IOS_SELFTESTS=yes" against
# the iphonesimulator SDK.  The script installs it on a throwaway
# simulator and launches it twice.
#
# The first launch finds no portable dump, so Emacs runs loadup from
# source and writes one.  It is driven by the app's own keystroke
# driver (EMACS_IOS_AUTO_INPUT), which saves a file and then runs
# M-x ios-run-self-tests: the port's probes followed by the bundled
# upstream ERT suites, one PASS, FAIL or SKIP line each.
#
# The second launch must load the dump the first one wrote, and reach
# its first frame sooner than the first did.
#
# Logs, the results file and a screenshot are left in
# OUTPUT-DIRECTORY.  The exit status is zero only if every check
# passed.

set -u

app=${1:?usage: simulator-test.sh APP BUNDLE-ID OUTPUT-DIRECTORY}
bundle_id=${2:?usage: simulator-test.sh APP BUNDLE-ID OUTPUT-DIRECTORY}
out=${3:?usage: simulator-test.sh APP BUNDLE-ID OUTPUT-DIRECTORY}

failed=0
dev=

say ()  { echo "$@"; }
fail () { echo "FAILED: $*"; failed=1; }

cleanup ()
{
  if [ -n "$dev" ]; then
    xcrun simctl shutdown "$dev" >/dev/null 2>&1
    xcrun simctl delete "$dev" >/dev/null 2>&1
  fi
}
trap cleanup EXIT

# Wait up to $2 seconds for the command line in $1 to succeed.
wait_for ()
{
  local waited=0
  while [ "$waited" -lt "$2" ]; do
    if eval "$1"; then
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

# Milliseconds from launch to the first frame, as the launch log in
# $1 records it.  Each launch stamps its lines with the time since
# its own first line.
first_frame_ms ()
{
  grep -a 'x-create-frame' "$1" 2>/dev/null \
    | sed -n '1s/.*\[\([0-9.]*\)ms\].*/\1/p'
}

[ -d "$app" ] || { echo "$app: no such bundle"; exit 2; }
mkdir -p "$out"

say "== Simulator"
# The simulator runs an arm64 binary only if it is signed, if only
# ad hoc; the build leaves a bundle with no identity unsigned.
codesign --force --sign - "$app" || fail "ad-hoc signing"
devtype=$(xcrun simctl list devicetypes \
            | grep -oE 'com\.apple\.CoreSimulator\.SimDeviceType\.iPhone-[A-Za-z0-9-]+' \
            | head -1)
dev=$(xcrun simctl create emacs-test "$devtype") \
  || { echo "could not create a $devtype simulator"; exit 2; }
say "device $dev ($devtype)"
xcrun simctl boot "$dev"
xcrun simctl bootstatus "$dev" -b >/dev/null
xcrun simctl install "$dev" "$app" \
  || { echo "the simulator refused to install $app"; exit 1; }

say "== First launch: loadup from source, self-tests"
SIMCTL_CHILD_EMACS_IOS_AUTO_INPUT=1 SIMCTL_CHILD_EMACS_IOS_DEBUG_LOG=1 \
  xcrun simctl launch "$dev" "$bundle_id" \
  || fail "the app did not launch"

# The container exists only once the app has started.
container=
wait_for 'container=$(xcrun simctl get_app_container "$dev" "$bundle_id" data 2>/dev/null) && [ -n "$container" ]' 60
[ -n "$container" ] || { echo "the app never created its container"; exit 1; }
docs=$container/Documents
results=$docs/ios-test-results.txt
launch_log=$docs/emacs-launch.log
stdout_log=$docs/emacs-stdout.log
dump="$container/Library/Application Support/Emacs/emacs.pdmp"

# The duration moves with the test list, so wait for the results
# rather than for a fixed time.
if wait_for '[ -s "$results" ]' 600; then
  say "results written"
else
  fail "no self-test results within ten minutes"
fi
# A little longer, so the font demo that follows is on screen.
sleep 5
xcrun simctl io "$dev" screenshot "$out/screenshot.png" >/dev/null 2>&1
xcrun simctl terminate "$dev" "$bundle_id" >/dev/null 2>&1

for f in ios-test-results.txt emacs-launch.log emacs-stdout.log \
         ci-roundtrip.txt; do
  [ -f "$docs/$f" ] && cp "$docs/$f" "$out/first-launch-$f"
done

say "== File round trip"
# The driver visits ci-roundtrip.txt, types into it and saves.
if grep -aq 'saved on iOS' "$docs/ci-roundtrip.txt" 2>/dev/null; then
  say "find-file, insert and save-buffer reached the disk"
else
  fail "ci-roundtrip.txt was not written as typed"
fi

say "== Self-tests"
if [ -s "$results" ]; then
  # The results can carry bytes that make grep take the file for
  # binary and print nothing, hence -a throughout.
  passed=$(grep -ac '^PASS ' "$results")
  skipped=$(grep -ac '^SKIP ' "$results")
  say "passed:  $passed"
  # Skips are listed.  A suite whose feature the build leaves out
  # skips every test in it, which must not read as coverage.
  say "skipped: $skipped"
  grep -a '^SKIP ' "$results" | sed 's/^/  /'
  [ "$passed" -gt 0 ] || fail "no test passed"
  if grep -aq '^FAIL ' "$results"; then
    grep -a '^FAIL ' "$results" | sed 's/^/  /'
    fail "self-tests reported failures"
  fi
else
  fail "the results file is missing or empty"
fi

say "== Portable dump"
if [ -s "$dump" ]; then
  say "written: $(wc -c < "$dump" | tr -d ' ') bytes"
else
  fail "no dump at $dump"
fi
grep -aq 'emacs-pdmp: wrote dump to' "$stdout_log" 2>/dev/null \
  || fail "the first launch did not report writing a dump"
source_ms=$(first_frame_ms "$launch_log")

# Both logs are appended to by every launch.  Move them aside so
# what the second launch writes can be told from the first.
mv -f "$launch_log" "$launch_log.first" 2>/dev/null
mv -f "$stdout_log" "$stdout_log.first" 2>/dev/null

say "== Second launch: load the dump"
SIMCTL_CHILD_EMACS_IOS_DEBUG_LOG=1 \
  xcrun simctl launch "$dev" "$bundle_id" \
  || fail "the app did not launch a second time"
if wait_for 'grep -aq "emacs-pdmp: loaded dump from" "$stdout_log" 2>/dev/null' 90
then
  wait_for '[ -n "$(first_frame_ms "$launch_log")" ]' 60
  dump_ms=$(first_frame_ms "$launch_log")
  if [ -n "$source_ms" ] && [ -n "$dump_ms" ]; then
    say "first frame after ${source_ms}ms from source, ${dump_ms}ms from the dump"
    awk -v a="$source_ms" -v b="$dump_ms" 'BEGIN { exit !(b < a) }' \
      || fail "loading the dump was no faster than running loadup"
  else
    fail "could not read both first-frame timings"
  fi
else
  grep -a 'emacs-pdmp:' "$stdout_log" 2>/dev/null | sed 's/^/  /'
  fail "the second launch did not load the dump"
fi
xcrun simctl terminate "$dev" "$bundle_id" >/dev/null 2>&1

for f in emacs-launch.log emacs-stdout.log; do
  [ -f "$docs/$f" ] && cp "$docs/$f" "$out/second-launch-$f"
done

if [ "$failed" -ne 0 ]; then
  # What the system saw, for a failure the app's own logs do not
  # explain: its unified log, and any crash report.
  xcrun simctl spawn "$dev" log show --last 10m --style compact \
    --predicate 'process == "emacs"' > "$out/unified-log.txt" 2>&1
  find "$HOME/Library/Logs/DiagnosticReports" \
       "$HOME/Library/Logs/CoreSimulator/$dev" \
       -name 'emacs*.ips' -type f 2>/dev/null \
    | head -3 | while IFS= read -r report; do
        cp "$report" "$out/"
        say "crash report: $report"
        head -60 "$report"
      done
fi

if [ "$failed" -eq 0 ]; then
  say "== All checks passed"
else
  say "== Some checks FAILED"
fi
exit $failed
