#!/bin/sh
# Executable backup script behavior tests
# Tests shell orchestration without mutating live kuma or installing host packages

set -eu

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

data_dir="$test_root/data"
backup_dir="$test_root/backups"
mkdir -p "$data_dir" "$backup_dir"

# Render test script with mock variables
test_script="$test_root/backup-test.sh"
cat > "$test_script" <<'BACKUP_SCRIPT'
#!/bin/sh
set -eu
umask 077

DATA_DIR="__DATA_DIR__"
BACKUP_DIR="__BACKUP_DIR__"
RETENTION_COUNT="__RETENTION_COUNT__"
DATABASE="$DATA_DIR/kuma.db"

if [ ! -f "$DATABASE" ]; then
    echo "Uptime Kuma database does not exist yet; nothing to back up"
    exit 0
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
temporary_database="$BACKUP_DIR/.kuma-$timestamp.db.tmp"
temporary_archive="$BACKUP_DIR/.kuma-$timestamp.db.gz.tmp"
final_archive="$BACKUP_DIR/kuma-$timestamp.db.gz"
temporary_manifest="$BACKUP_DIR/.retention-manifest-$timestamp.tmp"

cleanup() {
    rm -f "$temporary_database" "$temporary_archive" "$temporary_manifest"
}
trap cleanup EXIT HUP INT TERM

# SQLite CLI section 3.2: text within single quotes is treated as one argument with
# delimiters removed, including embedded whitespace. The '$temporary_database' syntax
# ensures the path is passed as a single literal argument to the .backup command.
sqlite3 "$DATABASE" ".backup '$temporary_database'"
test "$(sqlite3 "$temporary_database" 'PRAGMA quick_check;')" = "ok"
gzip -c "$temporary_database" > "$temporary_archive"
mv -f "$temporary_archive" "$final_archive"

# Retention: sequential stages with explicit error propagation (POSIX sh set -e
# only catches the final pipeline command). Uses root-private manifest.
find "$BACKUP_DIR" -type f -name 'kuma-*.db.gz' -printf '%T@ %p\n' > "$temporary_manifest"
sort -nr "$temporary_manifest" -o "$temporary_manifest"
awk -v keep="$RETENTION_COUNT" 'NR > keep { $1=""; sub(/^ /, ""); print }' "$temporary_manifest" |
  while IFS= read -r expired_archive; do
    rm -f -- "$expired_archive"
  done
BACKUP_SCRIPT

sed -e "s|__DATA_DIR__|$data_dir|g" \
    -e "s|__BACKUP_DIR__|$backup_dir|g" \
    -e "s|__RETENTION_COUNT__|3|g" \
    "$test_script" > "$test_script.rendered"
chmod +x "$test_script.rendered"

# Test 1: Missing database exits successfully
printf "Test 1: Missing database exits 0... "
if "$test_script.rendered" > "$test_root/test1.out" 2>&1; then
    if grep -q "database does not exist yet" "$test_root/test1.out"; then
        echo "PASS"
    else
        echo "FAIL - unexpected output"
        cat "$test_root/test1.out"
        exit 1
    fi
else
    echo "FAIL - non-zero exit"
    cat "$test_root/test1.out"
    exit 1
fi

# Test 2: Retention stages and cleanup (mock archives, no SQLite)
printf "Test 2: Retention stages and cleanup... "

# Create mock archives with different timestamps using touch format
# Format: YYYYMMDDhhmm (12 digits for touch -t)
for i in 1 2 3 4 5; do
    archive="$backup_dir/kuma-2026010100$(printf %02d $i)00Z.db.gz"
    echo "mock backup $i" | gzip -c > "$archive"
    # Set different modification times (oldest first): 202601010001, 202601010002, etc.
    touch -t "20260101000$i" "$archive"
done

# Verify we have 5 archives
archive_count="$(find "$backup_dir" -name 'kuma-*.db.gz' | wc -l)"
if [ "$archive_count" -ne 5 ]; then
    echo "FAIL - setup created $archive_count archives, expected 5"
    exit 1
fi

# Create test script for retention-only test (no SQLite operations)
retention_test="$test_root/retention-test.sh"
cat > "$retention_test" <<'RETENTION_SCRIPT'
#!/bin/sh
set -eu

BACKUP_DIR="__BACKUP_DIR__"
RETENTION_COUNT="__RETENTION_COUNT__"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
temporary_manifest="$BACKUP_DIR/.retention-manifest-$timestamp.tmp"

cleanup() {
    rm -f "$temporary_manifest"
}
trap cleanup EXIT HUP INT TERM

find "$BACKUP_DIR" -type f -name 'kuma-*.db.gz' -printf '%T@ %p\n' > "$temporary_manifest"
sort -nr "$temporary_manifest" -o "$temporary_manifest"
awk -v keep="$RETENTION_COUNT" 'NR > keep { $1=""; sub(/^ /, ""); print }' "$temporary_manifest" |
  while IFS= read -r expired_archive; do
    rm -f -- "$expired_archive"
  done
RETENTION_SCRIPT

sed -e "s|__BACKUP_DIR__|$backup_dir|g" \
    -e "s|__RETENTION_COUNT__|3|g" \
    "$retention_test" > "$retention_test.rendered"
chmod +x "$retention_test.rendered"

# Run retention test
"$retention_test.rendered"

# Verify retention: newest 3 should remain (timestamps 00003, 00004, 00005)
remaining="$(find "$backup_dir" -name 'kuma-*.db.gz' | wc -l)"
if [ "$remaining" -ne 3 ]; then
    echo "FAIL - $remaining archives remain, expected 3"
    find "$backup_dir" -name 'kuma-*.db.gz' | sort
    exit 1
fi

# Verify oldest 2 were removed
if [ -f "$backup_dir/kuma-20260101000100Z.db.gz" ] || [ -f "$backup_dir/kuma-20260101000200Z.db.gz" ]; then
    echo "FAIL - old archives not removed"
    find "$backup_dir" -name 'kuma-*.db.gz' | sort
    exit 1
fi

# Verify newest 3 remain
if [ ! -f "$backup_dir/kuma-20260101000300Z.db.gz" ] || \
   [ ! -f "$backup_dir/kuma-20260101000400Z.db.gz" ] || \
   [ ! -f "$backup_dir/kuma-20260101000500Z.db.gz" ]; then
    echo "FAIL - new archives missing"
    find "$backup_dir" -name 'kuma-*.db.gz' | sort
    exit 1
fi

# Verify manifest was cleaned up (check no .tmp files remain)
tmp_count="$(find "$backup_dir" -name '.retention-manifest-*.tmp' | wc -l)"
if [ "$tmp_count" -ne 0 ]; then
    echo "FAIL - temporary manifest not cleaned up"
    find "$backup_dir" -name '.retention-manifest-*.tmp'
    exit 1
fi

echo "PASS"

# Test 3: Cleanup on simulated failure (manifest cleanup in trap)
printf "Test 3: Cleanup trap on failure... "

failure_test="$test_root/failure-test.sh"
cat > "$failure_test" <<'FAILURE_SCRIPT'
#!/bin/sh
set -eu

BACKUP_DIR="__BACKUP_DIR__"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
temporary_manifest="$BACKUP_DIR/.retention-manifest-$timestamp.tmp"

cleanup() {
    rm -f "$temporary_manifest"
}
trap cleanup EXIT HUP INT TERM

# Create manifest
echo "test data" > "$temporary_manifest"

# Simulate failure
false
FAILURE_SCRIPT

sed -e "s|__BACKUP_DIR__|$backup_dir|g" \
    "$failure_test" > "$failure_test.rendered"
chmod +x "$failure_test.rendered"

# Should exit non-zero but cleanup should happen
if "$failure_test.rendered" 2>/dev/null; then
    echo "FAIL - expected failure"
    exit 1
fi

# Verify cleanup happened despite failure
tmp_count="$(find "$backup_dir" -name '.retention-manifest-*.tmp' | wc -l)"
if [ "$tmp_count" -ne 0 ]; then
    echo "FAIL - trap cleanup did not run"
    find "$backup_dir" -name '.retention-manifest-*.tmp'
    exit 1
fi

echo "PASS"

printf "\nAll backup behavior tests passed\n"
