#!/usr/bin/env bash
# avd-photos-status run for real against a scratch HOME, config and state, and
# its JSON read back with plutil (on every Mac, unlike jq). What it pins down:
# the "messages" object the menu's Messages rows are drawn from, for every
# state the source can be in, and that the "backup" object every existing
# reader parses is still there beside it. The emulator backend with an AVD name
# nothing runs, so the script asks no device and no app anything.
#
# Usage: test/status.sh          (also: /bin/bash test/status.sh, bash 3.2)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
export AVD_PHOTOS_CONFIG_DIR="$T/config" AVD_PHOTOS_STATE_DIR="$T/state"
mkdir -p "$HOME" "$T/config" "$T/state/logs" "$T/staging"

PASS=0; FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

config() {  # <MESSAGES_SOURCE value>
  printf 'ICLOUD_USERNAME=t@example.invalid\nSTAGING="%s/staging"\nPHOTOS_BACKEND=avd\nAVD_NAME=no-such-avd-%s\nMESSAGES_SOURCE=%s\n' \
    "$T" "$$" "$1" > "$T/config/config"
}
run() { /bin/bash "$HERE/../bin/avd-photos-status" > "$T/out.json" 2>"$T/err"; }
get() { plutil -extract "$1" raw -o - -- "$T/out.json" 2>/dev/null; }
parses() { plutil -convert xml1 -o /dev/null -- "$T/out.json" 2>/dev/null; }
STATUS="$T/state/messages-status"
tab="$(printf '\t')"

echo "the source off (the default)"
config 0; run
check "the output is JSON" parses
check "the backup object every reader parses is still there" \
  test "$(get backup.backend)/$(get backup.staged)/$(get backup.armed)" = "avd/0/false"
check "messages: off, no count, no age" \
  test "$(get messages.state)/$(get messages.count)/$(get messages.age)" = "off/0/-1"
printf '%s%sok%s12%s\n' "$(date +%s)" "$tab" "$tab" "$tab" > "$STATUS"
run
check "a status left by an earlier enabled run does not bring it back" test "$(get messages.state)" = off

echo "on, before its first scan"
rm -f "$STATUS"; config 1; run
check "unknown, not ok and not an error" test "$(get messages.state)/$(get messages.age)" = "unknown/-1"

echo "on, skipped for want of Full Disk Access"
printf '%s%sskipped%s7%sOperation not permitted\n' "$(( $(date +%s) - 120 ))" "$tab" "$tab" "$tab" > "$STATUS"
run
check "skipped, with macOS's words and the ledger count" \
  test "$(get messages.state)/$(get messages.reason)/$(get messages.count)" = "skipped/Operation not permitted/7"
age="$(get messages.age)"
check "and the age of that scan" test "${age:-0}" -ge 120 -a "${age:-0}" -lt 180

echo "on, scanned"
printf '%s%sok%s1161%s\n' "$(date +%s)" "$tab" "$tab" "$tab" > "$STATUS"
run
check "ok with its count and no reason" \
  test "$(get messages.state)/$(get messages.count)/$(get messages.reason)" = "ok/1161/"

echo "a reason JSON would choke on"
printf '%s%sskipped%s3%schat.db could not be queried: "near \\x": syntax error\n' "$(date +%s)" "$tab" "$tab" "$tab" > "$STATUS"
run
check "the output still parses" parses
check "and the reason survives, less the quote and backslash" \
  test "$(get messages.reason)" = "chat.db could not be queried: near x: syntax error"

# The collector runs under LC_ALL=C, where cut counts BYTES: a long reason cut
# through a multibyte character is invalid UTF-8, JSONSerialization refuses the
# whole blob, and the menu loses every row, photo sync included.
long="$(printf 'x%.0s' $(seq 1 159))é and more"
printf '%s%sskipped%s3%s%s\n' "$(date +%s)" "$tab" "$tab" "$tab" "$long" > "$STATUS"
run
check "a long non-ASCII reason cannot split a character and break the JSON" \
  test "$(LC_ALL=C tr -d '\040-\176' < "$T/out.json" | wc -c | tr -d ' ')" = 1

echo "a status line that is not one"
printf 'garbage\n' > "$STATUS"; run
check "an unreadable line is unknown, and the JSON still parses" \
  test "$(get messages.state)/$(get messages.count)/$(get messages.age)" = "unknown/0/-1" && parses
printf '%s%sexploded%s5%s\n' "$(date +%s)" "$tab" "$tab" "$tab" > "$STATUS"; run
check "a state the source never writes is unknown too" test "$(get messages.state)" = unknown
check "nothing on stderr through all of it" test ! -s "$T/err"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
