-- Who can see and do what: RLS everywhere, no anon, no cross-tenant reads, protected fields.
do $$
declare
  f jsonb; g jsonb; v_job uuid; t record; fn record; n bigint; stranger uuid;
begin
  f := tests.book_job('sme');
  g := tests.book_job('sme');            -- a second, unrelated buyer
  v_job := (f ->> 'job')::uuid;
  stranger := tests.mk_user('stranger');

  -- Every public table has row-level security.
  perform tests.eq((select coalesce(string_agg(c.relname, ', '), '') from pg_class c join pg_namespace s on s.oid = c.relnamespace
                    where s.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity), '',
                   'every public table has RLS enabled');

  -- Signed-out visitors read nothing from any table and call no function.
  for t in select c.relname from pg_class c join pg_namespace s on s.oid = c.relnamespace where s.nspname = 'public' and c.relkind = 'r' loop
    perform tests.as_anon();
    begin
      execute format('select count(*) from public.%I', t.relname) into n;
    exception when insufficient_privilege then n := 0;
    end;
    perform tests.as_su();
    perform tests.eq(n, 0::bigint, format('anon reads no rows from %s', t.relname));
  end loop;
  for fn in select p.oid, p.proname from pg_proc p join pg_namespace s on s.oid = p.pronamespace
            where s.nspname = 'public' and p.prokind = 'f' and p.prosecdef loop
    perform tests.ok(not has_function_privilege('anon', fn.oid, 'execute'), format('anon cannot execute public.%s', fn.proname));
  end loop;

  -- Tenants are isolated.
  perform tests.as_user((g ->> 'buyer')::uuid);
  perform tests.eq((select count(*) from public.jobs where id = v_job), 0::bigint, 'another buyer cannot see the job');
  perform tests.eq((select count(*) from public.briefs where id = (f ->> 'brief')::uuid), 0::bigint, 'another buyer cannot see the brief');
  perform tests.eq((select count(*) from public.quotes where id = (f ->> 'quote')::uuid), 0::bigint, 'another buyer cannot see the quote');
  perform tests.eq((select count(*) from public.sites where id = (f ->> 'site')::uuid), 0::bigint, 'another buyer cannot see the site');
  perform tests.as_user(stranger);
  perform tests.eq((select count(*) from public.jobs), 0::bigint, 'a user with no organisation sees no jobs');
  perform tests.eq((select count(*) from public.organisations where kind = 'buyer'), 0::bigint, 'a user with no organisation sees no buyer organisations');

  -- Crew see the job they are on, never the money.
  perform tests.as_user((f ->> 'crew')::uuid);
  perform tests.eq((select count(*) from public.jobs where id = v_job), 1::bigint, 'assigned crew can see their job');
  perform tests.eq((select count(*) from public.payments), 0::bigint, 'crew cannot read payments');

  -- Protected fields: status and value, verification tier, role escalation.
  perform tests.as_user((f ->> 'buyer')::uuid);
  update public.jobs set value = 1, status = 'paid' where id = v_job;
  get diagnostics n = row_count;
  perform tests.eq(n, 0::bigint, 'a buyer cannot update a job row at all');
  perform tests.as_user((f ->> 'vendor')::uuid);
  perform tests.throws(format('update public.jobs set value = 1 where id = %L', v_job), '%workflow only%', 'vendor cannot change a job value');
  perform tests.throws(format('update public.jobs set status = %L where id = %L', 'paid', v_job), '%workflow only%', 'vendor cannot set a job status directly');
  perform tests.as_su();
  perform tests.eq((select value from public.jobs where id = v_job), 30.00::numeric, 'job value is unchanged after the attempts');
  perform tests.eq((select status::text from public.jobs where id = v_job), 'matched', 'job status is unchanged after the attempts');
  perform tests.as_user((f ->> 'buyer')::uuid);
  perform tests.throws(format('update public.organisations set verification_tier = 3 where id = %L', f ->> 'buyer_org'),
                       '%Only Duly can change%', 'owner cannot change verification tier');
  perform tests.as_user((f ->> 'vendor')::uuid);
  perform tests.throws(format('insert into public.memberships values (%L, %L, %L)', f ->> 'vendor_org', f ->> 'vendor', 'platform_admin'),
                       '%row-level security%', 'vendor admin cannot grant platform_admin');
  perform tests.throws(format('update public.organisations set verification_tier = 2 where id = %L', f ->> 'vendor_org'),
                       '%Only Duly can change%', 'vendor cannot change its own verification tier');
  perform tests.as_su();
end $$;
