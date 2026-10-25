#!/bin/bash
# Creates the test certificate authority and server certificates used by the
# test mail server. Output goes to test-server/.generated/certs (git-ignored).
#
# The CA is name-constrained to the DNS names citusmail.test and localhost, so
# even if it were trusted by mistake it could not impersonate any real site.
# (No IP constraint: BoringSSL, used by Dart, rejects IP name constraints as
# unsupported, which would make every certificate from this CA fail.)
#
# Certificates:
#   ca.crt         Citusmail Test CA (tests trust only this)
#   mail.crt       valid for mail.citusmail.test, localhost, 127.0.0.1
#   expired.crt    signed by the CA, but expired in 2021
#   untrusted.crt  self-signed, not from the CA
#
# Re-running is safe: existing certificates are kept unless they expire
# within 30 days or --force is given.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly OUT_DIR="${CITUSMAIL_CERT_DIR:-$SCRIPT_DIR/../.generated/certs}"
readonly RENEW_SECONDS=$((30 * 24 * 3600))
FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

log() { echo "[certs] $*" >&2; }

new_key() {
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1" 2>/dev/null
  chmod 600 "$1"
}

still_valid() {
  [[ -f "$1" ]] && openssl x509 -in "$1" -noout -checkend "$RENEW_SECONDS" >/dev/null 2>&1
}

make_ca() {
  if ! $FORCE && still_valid "$OUT_DIR/ca.crt"; then return; fi
  log "creating test CA"
  new_key "$OUT_DIR/ca.key"
  openssl req -x509 -new -key "$OUT_DIR/ca.key" -sha256 -days 3650 \
    -subj "/O=Citusmail Test/CN=Citusmail Test CA (NOT FOR REAL USE)" \
    -addext "basicConstraints=critical,CA:true,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "nameConstraints=critical,permitted;DNS:citusmail.test,permitted;DNS:localhost" \
    -out "$OUT_DIR/ca.crt"
  FORCE=true  # a new CA invalidates every certificate it signed
}

# sign_cert NAME SAN [extra openssl x509 args...]
sign_cert() {
  local name="$1" san="$2"; shift 2
  local ext; ext="$(mktemp)"
  printf '%s\n' \
    "basicConstraints=critical,CA:false" \
    "keyUsage=critical,digitalSignature" \
    "extendedKeyUsage=serverAuth" \
    "subjectAltName=$san" > "$ext"
  new_key "$OUT_DIR/$name.key"
  local first_name="${san%%,*}"
  openssl req -new -key "$OUT_DIR/$name.key" -subj "/CN=${first_name#DNS:}" \
    | openssl x509 -req -CA "$OUT_DIR/ca.crt" -CAkey "$OUT_DIR/ca.key" \
        -CAcreateserial -sha256 -extfile "$ext" "$@" -out "$OUT_DIR/$name.crt" 2>/dev/null
  rm -f "$ext"
}

# A certificate from the test CA that expired in 2021. Made with
# "openssl ca", whose -startdate/-enddate work on OpenSSL 3.0 (Ubuntu
# 24.04); "openssl x509 -not_before" needs 3.4.
sign_expired() {
  local work; work="$(mktemp -d)"
  touch "$work/index.txt"
  echo 1000 > "$work/serial"
  cat > "$work/ca.cnf" <<CONF
[ca]
default_ca = test
[test]
database = $work/index.txt
serial = $work/serial
new_certs_dir = $work
default_md = sha256
policy = any
unique_subject = no
[any]
commonName = supplied
CONF
  printf '%s\n' \
    "basicConstraints=critical,CA:false" \
    "keyUsage=critical,digitalSignature" \
    "extendedKeyUsage=serverAuth" \
    "subjectAltName=DNS:expired.citusmail.test" > "$work/ext"
  new_key "$OUT_DIR/expired.key"
  openssl req -new -key "$OUT_DIR/expired.key" -subj "/CN=expired.citusmail.test" \
    -out "$work/expired.csr"
  openssl ca -batch -notext -config "$work/ca.cnf" \
    -cert "$OUT_DIR/ca.crt" -keyfile "$OUT_DIR/ca.key" \
    -startdate 20200101000000Z -enddate 20210101000000Z \
    -extfile "$work/ext" -in "$work/expired.csr" -out "$OUT_DIR/expired.crt" 2>/dev/null
  rm -rf "$work"
}

make_server_certs() {
  if $FORCE || ! still_valid "$OUT_DIR/mail.crt"; then
    log "creating mail.citusmail.test certificate"
    sign_cert mail "DNS:mail.citusmail.test,DNS:localhost,IP:127.0.0.1" -days 365
  fi
  if $FORCE || [[ ! -f "$OUT_DIR/expired.crt" ]]; then
    log "creating expired certificate"
    sign_expired
  fi
  if $FORCE || ! still_valid "$OUT_DIR/untrusted.crt"; then
    log "creating self-signed (untrusted) certificate"
    new_key "$OUT_DIR/untrusted.key"
    openssl req -x509 -new -key "$OUT_DIR/untrusted.key" -sha256 -days 365 \
      -subj "/CN=untrusted.citusmail.test" \
      -addext "subjectAltName=DNS:untrusted.citusmail.test" \
      -out "$OUT_DIR/untrusted.crt"
  fi
}

verify() {
  openssl verify -CAfile "$OUT_DIR/ca.crt" "$OUT_DIR/mail.crt" >/dev/null
  if openssl verify -CAfile "$OUT_DIR/ca.crt" "$OUT_DIR/expired.crt" >/dev/null 2>&1; then
    log "expired.crt unexpectedly verifies"; exit 1
  fi
  if openssl verify -CAfile "$OUT_DIR/ca.crt" "$OUT_DIR/untrusted.crt" >/dev/null 2>&1; then
    log "untrusted.crt unexpectedly verifies"; exit 1
  fi
}

main() {
  mkdir -p "$OUT_DIR"
  chmod 700 "$OUT_DIR"
  make_ca
  make_server_certs
  verify
  log "certificates ready in $OUT_DIR"
}

main
