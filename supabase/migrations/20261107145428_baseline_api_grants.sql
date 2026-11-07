-- The migrations assumed Supabase's default privileges on new tables. A project or branch that doesn't
-- have them (a fresh Supabase branch only had REFERENCES, TRIGGER and TRUNCATE for the API roles) answers
-- every signed-in request with 403, because the roles lack SELECT/INSERT/UPDATE/DELETE.
-- State the grants here so an environment built from this repo alone works. Row-level security, enabled on
-- every table, is what limits which rows each person can touch. Signed-out visitors (anon) get nothing.

grant usage on schema public to authenticated, service_role;
grant select, insert, update, delete on all tables in schema public to authenticated, service_role;
grant usage, select on all sequences in schema public to authenticated, service_role;

revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;

-- Tables and sequences created by later migrations get the same treatment.
alter default privileges in schema public grant select, insert, update, delete on tables to authenticated, service_role;
alter default privileges in schema public grant usage, select on sequences to authenticated, service_role;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on sequences from anon;
