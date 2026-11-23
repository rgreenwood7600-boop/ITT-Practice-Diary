#!/usr/bin/env bash
# Apply supabase/schema.sql to a throwaway database and check the diary rules.
# Requires a local PostgreSQL server and permission to create a database
# (sudo -u postgres, or PGSUPERUSER). Does not touch a hosted Supabase project.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
db_name="${ITT_RLS_DB:-itt_rls_test}"
super=(sudo -u postgres)

if [[ -n "${PGSUPERUSER:-}" ]]; then
  super=(psql -U "$PGSUPERUSER" -d postgres -c)
fi

run_sql() {
  sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$1" -f "$2"
}

echo "Checking the site does not embed a key or an outside script"
if grep -RIn --include='config.js' --include='*.html' --include='*.css' -e 'eyJ' "$root/config.js" "$root/index.html" "$root/js" "$root/styles.css"; then
  echo "A JWT is committed in the site. config.js must keep the placeholder anon key." >&2
  exit 1
fi
if grep -E 'src="https?:' "$root/index.html"; then
  echo "index.html loads an external script." >&2
  exit 1
fi
if grep -RIn --include='*.html' --include='*.js' --include='*.css' --include='*.sql' -e 'service_number' -e 'serviceNumber' "$root" \
  --exclude-dir=node_modules --exclude-dir=vendor --exclude-dir=.git; then
  echo "A service-number field is present." >&2
  exit 1
fi

echo "Creating a clean database ${db_name}"
sudo -u postgres psql -d postgres -v ON_ERROR_STOP=1 -c "drop database if exists ${db_name};"
sudo -u postgres psql -d postgres -v ON_ERROR_STOP=1 -c "create database ${db_name};"

echo "Applying the auth stub and schema (twice, to check a re-run)"
run_sql "$db_name" "$root/tests/auth_stub.sql"
run_sql "$db_name" "$root/supabase/schema.sql"
run_sql "$db_name" "$root/supabase/schema.sql"

echo "Running RLS checks"
run_sql "$db_name" "$root/tests/rls.sql"

echo "Re-applying the schema over existing diaries"
run_sql "$db_name" "$root/supabase/schema.sql"
run_sql "$db_name" "$root/tests/post_rerun.sql"

echo "RLS checks passed"
