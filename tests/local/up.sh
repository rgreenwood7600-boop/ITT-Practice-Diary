#!/usr/bin/env bash
# Builds a throwaway local database and starts PostgREST plus the auth stand-in.
# Not used in production. Requires PostgreSQL and a PostgREST binary
# (POSTGREST_BIN, or postgrest on PATH).
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
db_name="itt_diary"
secret="${ITT_JWT_SECRET:-itt-local-test-secret-not-for-production-00}"
postgrest_bin="${POSTGREST_BIN:-postgrest}"

sudo -u postgres psql -d postgres -v ON_ERROR_STOP=1 -c "drop database if exists ${db_name};"
sudo -u postgres psql -d postgres -v ON_ERROR_STOP=1 -c "create database ${db_name};"
sudo -u postgres psql -d "$db_name" -v ON_ERROR_STOP=1 -f "$root/tests/auth_stub.sql"
sudo -u postgres psql -d "$db_name" -v ON_ERROR_STOP=1 -f "$root/supabase/schema.sql"
sudo -u postgres psql -d "$db_name" -v ON_ERROR_STOP=1 -f "$root/tests/local/api_roles.sql"

cd "$root/tests/local"
if [[ ! -d node_modules/pg ]]; then
  npm install --silent
fi

node seed.mjs

if ! command -v "$postgrest_bin" >/dev/null 2>&1 && [[ ! -x "$postgrest_bin" ]]; then
  echo "PostgREST binary not found. Set POSTGREST_BIN." >&2
  exit 1
fi

export PGRST_DB_URI="postgres://authenticator:itt_local_only@127.0.0.1:5432/${db_name}"
export PGRST_DB_SCHEMAS="public"
export PGRST_DB_ANON_ROLE="anon"
export PGRST_JWT_SECRET="$secret"
export PGRST_SERVER_HOST="127.0.0.1"
export PGRST_SERVER_PORT="3001"
export ITT_JWT_SECRET="$secret"

"$postgrest_bin" &
echo $! > /tmp/itt-postgrest.pid
node gateway.mjs
