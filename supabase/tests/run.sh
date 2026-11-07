#!/usr/bin/env bash
# Runs the SQL tests against a throwaway database on a plain Postgres.
#   PGHOST/PGPORT/PGUSER/PGPASSWORD pick the server (a superuser). The database `duly_test` is dropped and recreated.
#   Usage: supabase/tests/run.sh [pattern]     e.g. run.sh 02
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
db="${DULY_TEST_DB:-duly_test}"
psql_admin=(psql -X -q -v ON_ERROR_STOP=1)

"${psql_admin[@]}" -d postgres -c "drop database if exists $db with (force)" -c "create database $db"
run() { "${psql_admin[@]}" -d "$db" "$@"; }

run -f "$here/setup/00_stubs.sql"
for m in "$repo"/supabase/migrations/*.sql; do run -f "$m" >/dev/null; done
# Mirror the parts of Supabase that exist before any migration runs: schema usage, and table privileges on
# storage (public-table privileges for authenticated come from the migrations themselves). anon is also given
# table access so the tests prove RLS, not missing grants, keeps signed-out visitors out.
run -c "grant usage on schema public to anon, authenticated;
        grant select, insert, update, delete on all tables in schema public to anon;
        grant select, insert, update, delete on storage.objects to anon, authenticated;"
run -f "$here/setup/10_helpers.sql"

failed=0
for t in "$here"/*${1:-}*.test.sql; do
  [ -e "$t" ] || { echo "no tests match '${1:-}'"; exit 1; }
  name="$(basename "$t")"
  if out=$(run -f "$t" 2>&1); then
    echo "PASS $name ($(grep -c 'NOTICE:  ok' <<<"$out") checks)"
  else
    echo "FAIL $name"; grep -E "ERROR|FAIL|CONTEXT" <<<"$out" | head -8; failed=1
  fi
done
exit $failed
