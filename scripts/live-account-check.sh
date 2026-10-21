#!/bin/bash
# Read-only check of the real account in live-test.env: logs in over TLS,
# lists what the server supports and its folder layout. Changes nothing.
#
#   scripts/live-account-check.sh [path/to/live-test.env]
#
# The password is read from the system keychain (secret-tool) and passed to
# curl on stdin, so it never appears in the process list, shell history or
# any file.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly ENV_FILE="${1:-$REPO_ROOT/live-test.env}"
readonly KEYCHAIN_SERVICE="fmail-test"
# Capabilities the sync engine can use, best first.
readonly WANTED_CAPS=(IDLE CONDSTORE QRESYNC MOVE UIDPLUS SPECIAL-USE ENABLE LITERAL+ NAMESPACE ESEARCH UTF8=ACCEPT)

log() { echo "$*" >&2; }
die() { log "error: $*"; exit 1; }

# ------------------------------------------------------------ settings
# Parsed line by line, never sourced, so the file can't run code.
declare -A SETTINGS=()

load_settings() {
  [[ -f "$ENV_FILE" ]] || die "$ENV_FILE not found. Create it with:
  cp live-test.env.example live-test.env   and fill in your account"
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]] || die "bad line in $ENV_FILE: $line"
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    [[ "$key" == *PASSWORD* || "$key" == *SECRET* || "$key" == *TOKEN* ]] \
      && die "$ENV_FILE must not contain secrets ($key); use the keychain"
    SETTINGS["$key"]="$value"
  done < "$ENV_FILE"
}

setting() { echo "${SETTINGS[$1]:?$1 is missing from $ENV_FILE}"; }

validate_settings() {
  local email host port
  email="$(setting LIVE_EMAIL)"
  [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "LIVE_EMAIL '$email' is not an address"
  [[ "$email" == you@example.com ]] && die "fill in your own account in $ENV_FILE"
  for host in "$(setting LIVE_IMAP_HOST)" "$(setting LIVE_SMTP_HOST)"; do
    [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || die "'$host' is not a hostname"
  done
  for port in "$(setting LIVE_IMAP_PORT)" "$(setting LIVE_SMTP_PORT)"; do
    if ! [[ "$port" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
      die "'$port' is not a port"
    fi
  done
  [[ "$(setting LIVE_TEST_FOLDER)" =~ ^[A-Za-z0-9_-]+$ ]] || die "LIVE_TEST_FOLDER must be a simple name"
}

# ------------------------------------------------------------ keychain
read_password() {
  command -v secret-tool >/dev/null || die "secret-tool not found (apt install libsecret-tools)"
  local email="$1" password
  if ! password="$(secret-tool lookup service "$KEYCHAIN_SERVICE" account "$email")" || [[ -z "$password" ]]; then
    die "no password in the keychain for $email. Store it with:
  secret-tool store --label=\"Fmail test account\" service $KEYCHAIN_SERVICE account $email"
  fi
  printf '%s' "$password"
}

# Escapes a value for a double-quoted curl config string.
curl_quote() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }

# ------------------------------------------------------------ IMAP
# Runs one read-only IMAP command over TLS and prints the server's replies.
# Credentials go to curl on stdin (-K -), never on the command line.
imap_command() {
  local email="$1" password="$2" command="$3"
  printf 'user = %s\n' "$(curl_quote "$email:$password")" \
    | curl --silent --show-error --max-time 30 --ssl-reqd --tlsv1.2 -K - \
        "imaps://$(setting LIVE_IMAP_HOST):$(setting LIVE_IMAP_PORT)/" \
        --request "$command"
}

report_tls() {
  local host="$1" port="$2" label="$3" result
  result="$(echo | timeout 15 openssl s_client -connect "$host:$port" -servername "$host" \
      -verify_hostname "$host" -verify_return_error 2>&1)" || true
  if grep -q "Verify return code: 0 (ok)" <<<"$result"; then
    local protocol
    protocol="$(grep -oE "Protocol *: *TLSv[0-9.]+" <<<"$result" | grep -oE "TLSv[0-9.]+" | head -1)"
    echo "  ok    $label certificate valid for $host (${protocol:-TLS})"
  else
    echo "  FAIL  $label certificate is not valid for $host:"
    grep -E "verify error|Verify return code" <<<"$result" | sed 's/^/        /' | head -3
    die "the app would refuse this server; check the hostname"
  fi
}

report_capabilities() {
  local caps="$1" cap
  echo
  echo "IMAP capabilities after login:"
  for cap in "${WANTED_CAPS[@]}"; do
    if grep -qE "(^| )${cap//+/\\+}( |$)" <<<"$caps"; then echo "  yes   $cap"; else echo "  no    $cap"; fi
  done
  echo "  (full list: $caps)"
}

report_folders() {
  local listing="$1"
  echo
  echo "Folders (LIST):"
  sed -n 's/^\* LIST /  /p' <<<"$listing" | tr -d '\r'
}

main() {
  load_settings
  validate_settings
  local email password
  email="$(setting LIVE_EMAIL)"
  echo "Live account: $email (read-only check)"
  echo
  echo "TLS:"
  report_tls "$(setting LIVE_IMAP_HOST)" "$(setting LIVE_IMAP_PORT)" "IMAP"
  report_tls "$(setting LIVE_SMTP_HOST)" "$(setting LIVE_SMTP_PORT)" "SMTP"

  password="$(read_password "$email")"
  local caps listing
  caps="$(imap_command "$email" "$password" CAPABILITY | sed -n 's/^\* CAPABILITY //p' | tr -d '\r')" \
    || die "IMAP login failed"
  [[ -n "$caps" ]] || die "IMAP login failed or no capabilities returned"
  listing="$(imap_command "$email" "$password" 'LIST "" "*"')"
  unset password

  report_capabilities "$caps"
  report_folders "$listing"
}

main "$@"
