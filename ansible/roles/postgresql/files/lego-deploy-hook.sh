#!/bin/sh
set -eu
umask 077

SRC_CRT=/var/lib/lego/certificates/postgres.crt
SRC_KEY=/var/lib/lego/certificates/postgres.key
DST_CRT=/etc/postgresql/18/main/tls/server.crt
DST_KEY=/etc/postgresql/18/main/tls/server.key
NEW_CRT="${DST_CRT}.new"
NEW_KEY="${DST_KEY}.new"
OLD_CRT="${DST_CRT}.old"
OLD_KEY="${DST_KEY}.old"
TMP_DIR="$(mktemp -d)"
CERT_PUB_DER="$TMP_DIR/cert.pub.der"
KEY_PUB_DER="$TMP_DIR/key.pub.der"
CERT_PUB_SHA_FILE="$TMP_DIR/cert.pub.sha256"
KEY_PUB_SHA_FILE="$TMP_DIR/key.pub.sha256"
rollback_enabled=0

cleanup_path() {
  path=$1
  if [ -e "$path" ] || [ -L "$path" ]; then
    if ! rm -f "$path"; then
      echo "failed to remove $path" >&2
      return 1
    fi
  fi
}

cleanup_tmp_dir() {
  if [ -d "$TMP_DIR" ]; then
    if ! rm -rf "$TMP_DIR"; then
      echo "failed to remove $TMP_DIR" >&2
      return 1
    fi
  fi
}

rollback_transaction() {
  rollback_status=0
  cert_restore_succeeded=0
  key_restore_succeeded=0

  if [ -e "$OLD_CRT" ] || [ -L "$OLD_CRT" ]; then
    if [ -e "$DST_CRT" ] || [ -L "$DST_CRT" ]; then
      if ! rm -f "$DST_CRT"; then
        echo "failed to remove $DST_CRT during rollback" >&2
        rollback_status=1
      elif mv -f "$OLD_CRT" "$DST_CRT"; then
        cert_restore_succeeded=1
      else
        echo "failed to restore $DST_CRT" >&2
        rollback_status=1
      fi
    elif mv -f "$OLD_CRT" "$DST_CRT"; then
      cert_restore_succeeded=1
    else
      echo "failed to restore $DST_CRT" >&2
      rollback_status=1
    fi
  else
    echo "rollback backup missing for $DST_CRT" >&2
    rollback_status=1
  fi

  if [ -e "$OLD_KEY" ] || [ -L "$OLD_KEY" ]; then
    if [ -e "$DST_KEY" ] || [ -L "$DST_KEY" ]; then
      if ! rm -f "$DST_KEY"; then
        echo "failed to remove $DST_KEY during rollback" >&2
        rollback_status=1
      elif mv -f "$OLD_KEY" "$DST_KEY"; then
        key_restore_succeeded=1
      else
        echo "failed to restore $DST_KEY" >&2
        rollback_status=1
      fi
    elif mv -f "$OLD_KEY" "$DST_KEY"; then
      key_restore_succeeded=1
    else
      echo "failed to restore $DST_KEY" >&2
      rollback_status=1
    fi
  else
    echo "rollback backup missing for $DST_KEY" >&2
    rollback_status=1
  fi

  if ! cleanup_path "$NEW_CRT"; then
    rollback_status=1
  fi
  if ! cleanup_path "$NEW_KEY"; then
    rollback_status=1
  fi

  if [ "$cert_restore_succeeded" -eq 1 ]; then
    if ! cleanup_path "$OLD_CRT"; then
      rollback_status=1
    fi
  fi
  if [ "$key_restore_succeeded" -eq 1 ]; then
    if ! cleanup_path "$OLD_KEY"; then
      rollback_status=1
    fi
  fi

  if [ "$cert_restore_succeeded" -eq 1 ] && [ "$key_restore_succeeded" -eq 1 ]; then
    if ! pg_ctlcluster 18 main reload; then
      echo "failed to reload PostgreSQL during rollback" >&2
      rollback_status=1
    fi
  else
    echo "rollback incomplete; retained recovery files for manual recovery" >&2
    rollback_status=1
  fi

  return "$rollback_status"
}

on_exit() {
  exit_code=$?
  trap - EXIT HUP INT TERM

  if [ "$rollback_enabled" -eq 1 ]; then
    if [ "$exit_code" -eq 0 ]; then
      exit_code=1
    fi
    if ! rollback_transaction; then
      exit_code=1
    fi
  fi

  if ! cleanup_tmp_dir; then
    exit_code=1
  fi

  exit "$exit_code"
}

trap 'on_exit' EXIT HUP INT TERM

if ! openssl x509 -in "$SRC_CRT" -checkend 0 -noout; then
  echo "source certificate is expired or invalid" >&2
  exit 1
fi

if ! openssl x509 -in "$SRC_CRT" -pubkey -noout | openssl pkey -pubin -outform DER >"$CERT_PUB_DER"; then
  echo "failed to extract certificate public key" >&2
  exit 1
fi

if ! openssl pkey -in "$SRC_KEY" -pubout -outform DER >"$KEY_PUB_DER"; then
  echo "failed to extract private key public key" >&2
  exit 1
fi

if ! sha256sum "$CERT_PUB_DER" | awk '{print $1}' >"$CERT_PUB_SHA_FILE"; then
  echo "failed to digest certificate public key" >&2
  exit 1
fi

if ! sha256sum "$KEY_PUB_DER" | awk '{print $1}' >"$KEY_PUB_SHA_FILE"; then
  echo "failed to digest private key public key" >&2
  exit 1
fi

if ! read -r cert_pub_sha <"$CERT_PUB_SHA_FILE"; then
  echo "failed to read certificate public key digest" >&2
  exit 1
fi

if ! read -r key_pub_sha <"$KEY_PUB_SHA_FILE"; then
  echo "failed to read private key public key digest" >&2
  exit 1
fi

if [ "$cert_pub_sha" != "$key_pub_sha" ]; then
  echo "certificate and private key do not match" >&2
  exit 1
fi

if ! cleanup_path "$NEW_CRT"; then
  exit 1
fi
if ! cleanup_path "$NEW_KEY"; then
  exit 1
fi
if ! cleanup_path "$OLD_CRT"; then
  exit 1
fi
if ! cleanup_path "$OLD_KEY"; then
  exit 1
fi

install -o postgres -g postgres -m 0644 "$SRC_CRT" "$NEW_CRT"
install -o postgres -g postgres -m 0600 "$SRC_KEY" "$NEW_KEY"

if ! su -s /bin/sh postgres -c "test -r '$NEW_CRT'"; then
  echo "postgres cannot read staged certificate" >&2
  exit 1
fi

if ! su -s /bin/sh postgres -c "test -r '$NEW_KEY'"; then
  echo "postgres cannot read staged private key" >&2
  exit 1
fi

if ! su -s /bin/sh postgres -c "openssl x509 -in '$NEW_CRT' -checkend 0 -noout >/dev/null"; then
  echo "postgres cannot parse staged certificate" >&2
  exit 1
fi

if ! su -s /bin/sh postgres -c "openssl pkey -in '$NEW_KEY' -pubout >/dev/null 2>&1"; then
  echo "postgres cannot parse staged private key" >&2
  exit 1
fi

if ! su -s /bin/sh postgres -c "\
  /usr/lib/postgresql/18/bin/postgres \
    -D /var/lib/postgresql/18/main \
    -c config_file=/etc/postgresql/18/main/postgresql.conf \
    -c ssl_cert_file='$NEW_CRT' \
    -c ssl_key_file='$NEW_KEY' \
    -C ssl_cert_file >/dev/null"; then
  echo "postgresql configuration validation failed for staged identity" >&2
  exit 1
fi

rollback_enabled=1

if ! mv -f "$DST_CRT" "$OLD_CRT"; then
  echo "failed to back up active certificate" >&2
  exit 1
fi

if ! mv -f "$DST_KEY" "$OLD_KEY"; then
  echo "failed to back up active private key" >&2
  exit 1
fi

if ! mv -f "$NEW_CRT" "$DST_CRT"; then
  echo "failed to activate staged certificate" >&2
  exit 1
fi

if ! mv -f "$NEW_KEY" "$DST_KEY"; then
  echo "failed to activate staged private key" >&2
  exit 1
fi

if ! pg_ctlcluster 18 main reload; then
  echo "failed to reload PostgreSQL with new identity" >&2
  exit 1
fi

rollback_enabled=0

if ! cleanup_path "$OLD_CRT"; then
  exit 1
fi
if ! cleanup_path "$OLD_KEY"; then
  exit 1
fi
