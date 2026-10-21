#!/bin/bash
# Checks that the running test servers behave the way the app's tests rely
# on: TLS rules, certificates, capabilities, users, sample mail and SMTP
# restrictions. Run with `test-server/fmailtest smoke` after `fmailtest up`.
#
# Side effect: sends one message to alice+smoke@fmail.test, which lands in
# alice's "smoke" folder. INBOX and the other seeded folders are untouched.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HERE
readonly CA="$HERE/.generated/certs/ca.crt"
# shellcheck source=servers.env
source "$HERE/servers.env"

PASSED=0
FAILED=0

pass() { PASSED=$((PASSED + 1)); printf '  \e[32mok\e[0m    %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '  \e[31mFAIL\e[0m  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; }

# expect_match NAME TEXT REGEX
expect_match() { if grep -qE -- "$3" <<<"$2"; then pass "$1"; else fail "$1" "expected /$3/ in: ${2:0:300}"; fi; }
# expect_no_match NAME TEXT REGEX
expect_no_match() { if grep -qE -- "$3" <<<"$2"; then fail "$1" "unexpected /$3/ in: ${2:0:300}"; else pass "$1"; fi; }

# expect_equal NAME ACTUAL EXPECTED
expect_equal() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected '$3', found '${2:-nothing}'"; fi; }

password_of() { echo "$1-test-password"; }

# --------------------------------------------------------------- helpers
# Sends IMAP lines over a plain TCP connection and prints the replies.
imap_plain() {
  local port="$1"; shift
  { sleep 0.5; printf '%s\r\n' "$@"; sleep 1; } \
    | timeout 10 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port; cat <&3 & cat >&3; wait" 2>/dev/null
}

# Sends IMAP lines over IMAPS (implicit TLS) with the given SNI name.
imap_tls() {
  local port="$1" sni="$2"; shift 2
  { sleep 0.5; printf '%s\r\n' "$@"; sleep 1; } \
    | timeout 10 openssl s_client -quiet -connect "127.0.0.1:$port" -servername "$sni" \
        -verify_hostname "$sni" -CAfile "$CA" -verify_return_error 2>/dev/null
}

# Prints OpenSSL's verdict on the certificate served for an SNI name.
tls_verdict() {
  local port="$1" sni="$2" extra="${3:-}"
  # shellcheck disable=SC2086
  echo | timeout 10 openssl s_client -connect "127.0.0.1:$port" -servername "$sni" \
      -verify_hostname "$sni" -CAfile "$CA" $extra 2>&1 | grep -E "Verify return code"
}

# Counts messages in a mailbox via IMAP EXAMINE.
message_count() {
  local port="$1" user="$2" mailbox="$3"
  curl -sS --max-time 10 --cacert "$CA" "imaps://127.0.0.1:$port/" \
    -u "$user@$TEST_DOMAIN:$(password_of "$user")" -X "EXAMINE \"$mailbox\"" 2>&1 \
    | grep -oE '^\* [0-9]+ EXISTS' | grep -oE '[0-9]+'
}

expected_count() {
  python3 -I - "$HERE/seed.toml" "$1" "$2" <<'EOF'
import sys, tomllib
plan = tomllib.load(open(sys.argv[1], "rb"))["message"]
print(sum(1 for m in plan if m["user"] == sys.argv[2] and m["mailbox"] == sys.argv[3]))
EOF
}

send_mail() {
  local url="$1" user="$2" from="$3" rcpt="$4"
  printf 'From: %s\r\nTo: %s\r\nSubject: smoke test\r\nDate: %s\r\nMessage-ID: <smoke-%s@fmail.test>\r\n\r\nhello\r\n' \
      "$from" "$rcpt" "$(date -R)" "$RANDOM$RANDOM" \
    | curl -sS --max-time 15 --ssl-reqd --cacert "$CA" "$url" \
        --mail-from "$from" --mail-rcpt "$rcpt" \
        -u "$user@$TEST_DOMAIN:$(password_of "$user")" -T - 2>&1
}

# ---------------------------------------------------------------- checks
check_ports_are_local_only() {
  echo "Network exposure"
  local listening
  listening="$(ss -Hltn 2>/dev/null)"
  local port
  for port in $SECURE_IMAP_PORT $SECURE_IMAPS_PORT $SECURE_SUBMISSION_PORT $SECURE_SUBMISSIONS_PORT \
              $LIMITED_IMAPS_PORT $PLAIN_IMAP_PORT $PLAIN_SUBMISSION_PORT; do
    expect_no_match "port $port is not exposed beyond 127.0.0.1" "$listening" "(0\.0\.0\.0|\*|\[::\]):$port\b"
  done
}

check_certificates() {
  echo "Certificates (secure IMAPS)"
  expect_match "valid certificate for mail.fmail.test" \
    "$(tls_verdict "$SECURE_IMAPS_PORT" mail.fmail.test)" "return code: 0 "
  expect_match "expired.fmail.test serves an expired certificate" \
    "$(tls_verdict "$SECURE_IMAPS_PORT" expired.fmail.test)" "return code: 10 "
  expect_match "untrusted.fmail.test serves a self-signed certificate" \
    "$(tls_verdict "$SECURE_IMAPS_PORT" untrusted.fmail.test)" "return code: 18 "
  expect_match "other names get a hostname mismatch" \
    "$(tls_verdict "$SECURE_IMAPS_PORT" other.fmail.test)" "return code: 62 "
  expect_match "TLS 1.1 is refused" \
    "$(echo | timeout 10 openssl s_client -connect "127.0.0.1:$SECURE_IMAPS_PORT" -tls1_1 2>&1)" \
    "(no protocols available|alert|handshake failure|wrong version|unsupported protocol)"
}

check_secure_imap() {
  echo "Secure IMAP"
  local reply
  reply="$(imap_plain "$SECURE_IMAP_PORT" "a1 LOGIN alice@$TEST_DOMAIN alice-test-password" "a2 LOGOUT")"
  expect_match "port 143 advertises STARTTLS and LOGINDISABLED" "$reply" "STARTTLS.*LOGINDISABLED|LOGINDISABLED.*STARTTLS"
  expect_match "login before STARTTLS is refused" "$reply" "^a1 NO"

  reply="$( { sleep 0.5; printf 'a1 LOGIN alice@%s alice-test-password\r\na2 LOGOUT\r\n' "$TEST_DOMAIN"; sleep 1; } \
    | timeout 10 openssl s_client -quiet -starttls imap -connect "127.0.0.1:$SECURE_IMAP_PORT" \
        -servername mail.fmail.test -verify_hostname mail.fmail.test -CAfile "$CA" -verify_return_error 2>/dev/null)"
  expect_match "login after STARTTLS works" "$reply" "^a1 OK"

  reply="$(imap_tls "$SECURE_IMAPS_PORT" mail.fmail.test "a1 LOGIN alice@$TEST_DOMAIN wrong-password" "a2 LOGOUT")"
  expect_match "wrong password is refused" "$reply" "^a1 NO"

  local user
  for user in $TEST_USERS; do
    reply="$(imap_tls "$SECURE_IMAPS_PORT" mail.fmail.test "a1 LOGIN $user@$TEST_DOMAIN $(password_of "$user")" "a2 LOGOUT")"
    expect_match "$user can log in over IMAPS" "$reply" "^a1 OK"
  done

  reply="$(imap_tls "$SECURE_IMAPS_PORT" mail.fmail.test "a1 LOGIN alice@$TEST_DOMAIN alice-test-password" "a2 CAPABILITY" "a3 LOGOUT")"
  local cap
  for cap in IDLE CONDSTORE QRESYNC MOVE UIDPLUS SPECIAL-USE ENABLE LITERAL+ NAMESPACE; do
    expect_match "secure server advertises $cap" "$reply" "^\* CAPABILITY .*\b$cap\b"
  done

  reply="$(imap_tls "$SECURE_IMAPS_PORT" mail.fmail.test "a1 LOGIN carol@$TEST_DOMAIN carol-test-password" 'a2 LIST "" "*"' "a3 LOGOUT")"
  expect_match "carol uses cPanel-style INBOX. folders" "$reply" '^\* LIST .* "\." INBOX\.Receipts'
  expect_match "carol's INBOX.spam is the \\Junk folder (like Namecheap)" "$reply" '\\Junk\) "\." INBOX\.spam'
  expect_match "carol's INBOX.Junk is a plain folder" "$reply" '^\* LIST \(\\HasNoChildren\) "\." INBOX\.Junk'
  reply="$(imap_tls "$SECURE_IMAPS_PORT" mail.fmail.test "a1 LOGIN alice@$TEST_DOMAIN alice-test-password" 'a2 LIST "" "*"' "a3 LOGOUT")"
  expect_match "alice has nested folder Projects/2026" "$reply" '"/" Projects/2026'
  expect_match "alice has non-ASCII folder (modified UTF-7)" "$reply" '"/" &ZeVnLIqe-'
  expect_match "alice's Sent folder is marked \\Sent" "$reply" '\\Sent\) "/" Sent'
}

check_sample_mail() {
  echo "Sample mail"
  local user mailbox expected actual
  for pair in "alice INBOX" "alice Sent" "alice Drafts" "alice Projects/2026" "bob INBOX" "carol INBOX" "carol INBOX.Junk" "carol INBOX.Receipts"; do
    read -r user mailbox <<<"$pair"
    expected="$(expected_count "$user" "$mailbox")"
    actual="$(message_count "$SECURE_IMAPS_PORT" "$user" "$mailbox")"
    expect_equal "$user $mailbox has $expected messages" "$actual" "$expected"
  done
  actual="$(message_count "$LIMITED_IMAPS_PORT" alice INBOX)"
  expected="$(expected_count alice INBOX)"
  expect_equal "limited server is seeded too" "$actual" "$expected"
}

check_smtp() {
  echo "SMTP submission"
  local reply
  reply="$( { sleep 0.5; printf 'EHLO smoke.test\r\nQUIT\r\n'; sleep 1; } \
    | timeout 10 bash -c "exec 3<>/dev/tcp/127.0.0.1/$SECURE_SUBMISSION_PORT; cat <&3 & cat >&3; wait" 2>/dev/null)"
  expect_match "port 587 offers STARTTLS" "$reply" "250.STARTTLS"
  expect_no_match "port 587 offers no login before STARTTLS" "$reply" "250.AUTH"

  local before after
  before="$(message_count "$SECURE_IMAPS_PORT" alice smoke 2>/dev/null)"; before="${before:-0}"
  reply="$(send_mail "smtps://127.0.0.1:$SECURE_SUBMISSIONS_PORT" alice "alice@$TEST_DOMAIN" "alice+smoke@$TEST_DOMAIN")"
  expect_equal "send over port 465 (implicit TLS)" "$reply" ""
  reply="$(send_mail "smtp://127.0.0.1:$SECURE_SUBMISSION_PORT" alice "alice@$TEST_DOMAIN" "alice+smoke@$TEST_DOMAIN")"
  expect_equal "send over port 587 (STARTTLS)" "$reply" ""

  local deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    after="$(message_count "$SECURE_IMAPS_PORT" alice smoke 2>/dev/null)"; after="${after:-0}"
    ((after >= before + 2)) && break
    sleep 0.5
  done
  expect_equal "sent mail arrives in alice's smoke folder" "$after" "$((before + 2))"

  reply="$(send_mail "smtps://127.0.0.1:$SECURE_SUBMISSIONS_PORT" alice "alice@$TEST_DOMAIN" "someone@example.com")"
  expect_match "mail to outside domains is refused" "$reply" "(550|554|5\.7\.1)"
  reply="$(send_mail "smtps://127.0.0.1:$SECURE_SUBMISSIONS_PORT" alice "bob@$TEST_DOMAIN" "alice+smoke@$TEST_DOMAIN")"
  expect_match "sending as someone else is refused" "$reply" "(553|554|5\.7\.1)"
}

check_limited() {
  echo "Limited server"
  local reply
  reply="$(imap_tls "$LIMITED_IMAPS_PORT" mail.fmail.test "a1 LOGIN alice@$TEST_DOMAIN alice-test-password" "a2 CAPABILITY" "a3 LOGOUT")"
  expect_match "limited server works over TLS" "$reply" "^a1 OK"
  local cap
  for cap in CONDSTORE QRESYNC MOVE; do
    expect_no_match "limited server does not advertise $cap" "$reply" "^\* CAPABILITY .*\b$cap\b"
  done
  expect_match "limited server still advertises IDLE" "$reply" "^\* CAPABILITY .*\bIDLE\b"
}

check_plain() {
  echo "Plain (insecure) server"
  local reply
  reply="$(imap_plain "$PLAIN_IMAP_PORT" "a1 CAPABILITY" "a2 LOGOUT")"
  expect_no_match "plain server offers no STARTTLS" "$reply" "STARTTLS"
  expect_no_match "plain server does not disable login" "$reply" "LOGINDISABLED"
  reply="$( { sleep 0.5; printf 'EHLO smoke.test\r\nQUIT\r\n'; sleep 1; } \
    | timeout 10 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PLAIN_SUBMISSION_PORT; cat <&3 & cat >&3; wait" 2>/dev/null)"
  expect_no_match "plain SMTP offers no STARTTLS" "$reply" "STARTTLS"
}

main() {
  [[ -r "$CA" ]] || { echo "No CA at $CA; run 'test-server/fmailtest up' first" >&2; exit 2; }
  check_ports_are_local_only
  check_certificates
  check_secure_imap
  check_sample_mail
  check_smtp
  check_limited
  check_plain
  echo
  echo "$PASSED passed, $FAILED failed"
  ((FAILED == 0))
}

main "$@"
