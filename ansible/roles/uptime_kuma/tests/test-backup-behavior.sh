#!/bin/sh
# Executable backup script behavior tests
# Renders the actual Jinja template and tests its runtime behavior with shims

set -eu

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

# Directories for test isolation
data_dir="$test_root/data with spaces"
backup_dir="$test_root/backups with spaces"
shim_dir="$test_root/bin"
mkdir -p "$data_dir" "$backup_dir" "$shim_dir"

# Render actual template by substituting the three variables
template_path="$(dirname "$0")/../templates/uptime-kuma-backup.sh.j2"
rendered_script="$test_root/backup-rendered.sh"

sed -e "s|{{ uptime_kuma_data_directory }}|$data_dir|g" \
    -e "s|{{ uptime_kuma_backup_directory }}|$backup_dir|g" \
    -e "s|{{ uptime_kuma_backup_retention_count }}|3|g" \
    "$template_path" > "$rendered_script"
chmod +x "$rendered_script"

# sqlite3 shim: copies source DB for .backup and returns 'ok' for quick_check
cat > "$shim_dir/sqlite3" <<'SQLITE3_SHIM'
#!/bin/sh
set -eu

if [ $# -eq 2 ] && echo "$2" | grep -q '^\.backup '; then
    # Extract quoted path from .backup command
    dest="$(echo "$2" | sed "s/^\.backup '\(.*\)'$/\1/")"
    cp "$1" "$dest"
elif [ $# -eq 2 ] && [ "$2" = "PRAGMA quick_check;" ]; then
    echo "ok"
else
    echo "sqlite3 shim: unexpected arguments: $*" >&2
    exit 1
fi
SQLITE3_SHIM
chmod +x "$shim_dir/sqlite3"

# gzip shim: pass through for normal operation
cat > "$shim_dir/gzip" <<'GZIP_SHIM'
#!/bin/sh
exec /usr/bin/gzip "$@"
GZIP_SHIM
chmod +x "$shim_dir/gzip"

# Test 1: Missing database exits 0
printf "Test 1: Missing database exits 0... "
if PATH="$shim_dir:$PATH" "$rendered_script" > "$test_root/test1.out" 2>&1; then
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

# Test 2: Full backup with path containing spaces and retention
printf "Test 2: Full backup and newest-N retention... "

# Create a mock database in the directory with spaces
echo "mock kuma database content" > "$data_dir/kuma.db"

# Create 5 old mock archives with different timestamps
for i in 1 2 3 4 5; do
    archive="$backup_dir/kuma-2026010100$(printf %02d "$i")00Z.db.gz"
    echo "old backup $i" | gzip -c > "$archive"
    touch -t "20260101000$i" "$archive"
done

# Run the backup with shims in PATH
if ! PATH="$shim_dir:$PATH" "$rendered_script" > "$test_root/test2.out" 2>&1; then
    echo "FAIL - backup exited non-zero"
    cat "$test_root/test2.out"
    exit 1
fi

# Verify newest 3 old archives plus 1 new archive remain (4 total, not 3)
# The script keeps 3 newest, so after adding the new backup: 5 + 1 = 6 total,
# delete 6 - 3 = 3, leaving 3 archives
remaining="$(find "$backup_dir" -name 'kuma-*.db.gz' | wc -l)"
if [ "$remaining" -ne 3 ]; then
    echo "FAIL - $remaining archives remain, expected 3"
    find "$backup_dir" -name 'kuma-*.db.gz' -ls
    exit 1
fi

# Verify oldest archives were removed
if [ -f "$backup_dir/kuma-20260101000100Z.db.gz" ] || \
   [ -f "$backup_dir/kuma-20260101000200Z.db.gz" ] || \
   [ -f "$backup_dir/kuma-20260101000300Z.db.gz" ]; then
    echo "FAIL - old archives not removed"
    find "$backup_dir" -name 'kuma-*.db.gz' -ls
    exit 1
fi

# Verify no temporary files remain
tmp_count="$(find "$backup_dir" -name '.*.tmp' | wc -l)"
if [ "$tmp_count" -ne 0 ]; then
    echo "FAIL - temporary files not cleaned up"
    find "$backup_dir" -name '.*.tmp' -ls
    exit 1
fi

# Verify newest backup can be decompressed
# Use the known new archive by pattern instead of parsing find output with cut
newest_backup="$(find "$backup_dir" -name 'kuma-*.db.gz' ! -name 'kuma-202601010*Z.db.gz' -type f)"
if [ -z "$newest_backup" ]; then
    echo "FAIL - cannot find new backup archive"
    find "$backup_dir" -name 'kuma-*.db.gz' -ls
    exit 1
fi

if ! gzip -dc "$newest_backup" > "$test_root/restored.db"; then
    echo "FAIL - cannot decompress newest backup"
    exit 1
fi

# Verify restored content matches source
if ! cmp -s "$data_dir/kuma.db" "$test_root/restored.db"; then
    echo "FAIL - restored database differs from source"
    exit 1
fi

echo "PASS"

# Test 3: Failure injection proves nonzero propagation and cleanup
printf "Test 3: Sort failure propagates and cleanup runs... "

# Create a failing sort shim
cat > "$shim_dir/sort" <<'SORT_SHIM'
#!/bin/sh
echo "sort: injected failure" >&2
exit 1
SORT_SHIM
chmod +x "$shim_dir/sort"

# Remove old database and create a fresh one for this test
rm -f "$data_dir/kuma.db"
echo "test failure propagation" > "$data_dir/kuma.db"

# Clean backup directory
rm -f "$backup_dir"/kuma-*.db.gz

# Run should fail due to sort failure
if PATH="$shim_dir:$PATH" "$rendered_script" > "$test_root/test3.out" 2>&1; then
    echo "FAIL - expected nonzero exit from sort failure"
    cat "$test_root/test3.out"
    exit 1
fi

# Verify error message contains sort failure
if ! grep -q "sort.*failure" "$test_root/test3.out"; then
    echo "FAIL - sort failure not propagated to stderr"
    cat "$test_root/test3.out"
    exit 1
fi

# Verify cleanup ran despite failure (no .tmp files)
tmp_count="$(find "$backup_dir" -name '.*.tmp' | wc -l)"
if [ "$tmp_count" -ne 0 ]; then
    echo "FAIL - cleanup trap did not run after sort failure"
    find "$backup_dir" -name '.*.tmp' -ls
    exit 1
fi

echo "PASS"

printf "\nAll backup behavior tests passed\n"
