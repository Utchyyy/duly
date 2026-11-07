-- The API roles' table privileges come from the migrations, not from the environment.
do $$
declare t record; missing text;
begin
  select coalesce(string_agg(c.relname, ', '), '') into missing
  from pg_class c join pg_namespace s on s.oid = c.relnamespace
  where s.nspname = 'public' and c.relkind = 'r'
    and not (has_table_privilege('authenticated', c.oid, 'select') and has_table_privilege('authenticated', c.oid, 'insert')
             and has_table_privilege('authenticated', c.oid, 'update') and has_table_privilege('authenticated', c.oid, 'delete'));
  perform tests.eq(missing, '', 'authenticated can select, insert, update and delete on every public table (RLS limits the rows)');

  select coalesce(string_agg(c.relname, ', '), '') into missing
  from pg_class c join pg_namespace s on s.oid = c.relnamespace
  where s.nspname = 'public' and c.relkind = 'r'
    and not (has_table_privilege('service_role', c.oid, 'select') and has_table_privilege('service_role', c.oid, 'insert')
             and has_table_privilege('service_role', c.oid, 'update') and has_table_privilege('service_role', c.oid, 'delete'));
  perform tests.eq(missing, '', 'service_role has full access to every public table');

  -- A table added later inherits the same privileges; anon gets none.
  create table public.zz_grants_probe (id int generated always as identity primary key);
  perform tests.ok(has_table_privilege('authenticated', 'public.zz_grants_probe', 'select, insert, update, delete'), 'a new table is usable by authenticated without extra grants');
  perform tests.ok(has_sequence_privilege('authenticated', pg_get_serial_sequence('public.zz_grants_probe', 'id'), 'usage'), 'a new identity sequence is usable by authenticated');
  perform tests.ok(not has_table_privilege('anon', 'public.zz_grants_probe', 'select'), 'a new table is not readable by anon');
  drop table public.zz_grants_probe;
end $$;
