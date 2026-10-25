#!/bin/bash
# Starts Dovecot and Postfix for the chosen mode and stops the container if
# either one exits, so a broken server never looks healthy.
set -euo pipefail

readonly MODE="${CITUSMAIL_TEST_MODE:-secure}"
readonly CERT_DIR=/etc/citusmail-certs
readonly POSTFIX_SRC=/etc/citusmail-postfix

log() { echo "[entrypoint] $*" >&2; }

validate_mode() {
  case "$MODE" in
    secure | limited | plain) ;;
    *) log "unknown CITUSMAIL_TEST_MODE '$MODE' (use secure, limited or plain)"; exit 64 ;;
  esac
}

require_certificates() {
  local name
  for name in mail expired untrusted; do
    if [[ ! -r "$CERT_DIR/$name.crt" || ! -r "$CERT_DIR/$name.key" ]]; then
      log "missing $CERT_DIR/$name.{crt,key}; run 'test-server/citusmailtest up'"
      exit 66
    fi
  done
}

apply_postconf_file() {
  local line
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    postconf -e "$line"
  done < "$1"
}

configure_dovecot() {
  ln -sf "/etc/dovecot/mode-$MODE.conf" /etc/dovecot/mode.conf
  doveconf -n > /dev/null  # fails loudly on a config error
}

configure_postfix() {
  apply_postconf_file "$POSTFIX_SRC/main.cf"
  postconf -F '*/*/chroot = n'
  postconf -MX smtp/inet  # no port 25: the app only uses submission

  # The commas belong to a Postfix value, not array syntax.
  # shellcheck disable=SC2054
  local common=(-o smtpd_sasl_auth_enable=yes -o smtpd_client_restrictions=permit_sasl_authenticated,reject)
  if [[ "$MODE" == plain ]]; then
    postconf -e smtpd_tls_security_level=none
    add_service submission "${common[@]}" -o smtpd_tls_auth_only=no
  else
    apply_postconf_file "$POSTFIX_SRC/tls.cf"
    add_service submission "${common[@]}" -o smtpd_tls_security_level=encrypt -o smtpd_tls_auth_only=yes
    add_service submissions "${common[@]}" -o smtpd_tls_wrappermode=yes -o smtpd_tls_auth_only=yes
  fi
  postfix check
}

# add_service NAME [-o key=value ...]
add_service() {
  local name="$1"; shift
  postconf -M "$name/inet=$name inet n - n - - smtpd"
  postconf -P "$name/inet/syslog_name=postfix/$name"
  while (($#)); do
    postconf -P "$name/inet/${2}"
    shift 2
  done
}

main() {
  validate_mode
  [[ "$MODE" != plain ]] && require_certificates
  configure_dovecot
  configure_postfix
  log "starting in '$MODE' mode"

  dovecot -F &
  local dovecot_pid=$!
  postfix start-fg &
  local postfix_pid=$!

  trap 'kill -TERM $dovecot_pid $postfix_pid 2>/dev/null; wait' TERM INT
  wait -n
  log "a mail service exited; stopping container"
  kill -TERM $dovecot_pid $postfix_pid 2>/dev/null || true
  wait || true
  exit 1
}

main "$@"
