-- The admin audit log: complete, attributed, append-only, admin-only.
do $$
declare
  f jsonb; v_job uuid; v_brief uuid; v_quote uuid; n bigint; t record; v_other uuid;
begin
  f := tests.without_schedule(tests.book_job('sme'));
  v_job := (f ->> 'job')::uuid; v_brief := (f ->> 'brief')::uuid; v_quote := (f ->> 'quote')::uuid;
  perform tests.crew_completes(f);
  perform tests.buyer_approves(f);

  -- Everything from the request onwards is recorded, with who did it.
  perform tests.eq((select count(*) from public.audit_log where brief_id = v_brief and table_name = 'briefs' and op = 'INSERT'), 1::bigint, 'the brief being created is logged');
  perform tests.eq((select actor from public.audit_log where brief_id = v_brief and table_name = 'briefs' and op = 'INSERT'), (f ->> 'buyer')::uuid, 'with the buyer as the actor');
  perform tests.ok(exists (select 1 from public.audit_log where brief_id = v_brief and summary = 'Brief version 1 locked' and actor = (f ->> 'buyer')::uuid), 'locking the brief is logged against the person who locked it');
  perform tests.ok(exists (select 1 from public.audit_log where quote_id = v_quote and table_name = 'quotes' and op = 'INSERT' and (f ->> 'vendor_org')::uuid = any (org_ids) and (f ->> 'buyer_org')::uuid = any (org_ids)), 'the invitation is logged against both organisations');
  perform tests.ok(exists (select 1 from public.audit_log where quote_id = v_quote and summary = 'Quote status invited to submitted' and actor = (f ->> 'vendor')::uuid), 'the vendor submitting is logged with the vendor as actor');
  perform tests.ok(exists (select 1 from public.audit_log where quote_id = v_quote and summary like 'Quote status submitted to accepted' and actor = (f ->> 'buyer')::uuid), 'the buyer accepting is logged');
  perform tests.ok(exists (select 1 from public.audit_log where job_id = v_job and table_name = 'jobs' and op = 'INSERT'), 'the job being created is logged');
  perform tests.ok(exists (select 1 from public.audit_log where job_id = v_job and table_name = 'job_assignments' and actor = (f ->> 'vendor')::uuid), 'the vendor assigning crew is logged');
  perform tests.eq((select count(*) from public.audit_log where job_id = v_job and table_name = 'evidence'), 2::bigint, 'each photo is logged');
  perform tests.eq((select actor from public.audit_log where job_id = v_job and table_name = 'evidence' limit 1), (f ->> 'crew')::uuid, 'with the crew member who uploaded it');
  perform tests.ok(exists (select 1 from public.audit_log where job_id = v_job and summary = 'Standard ticked by crew'), 'ticks are logged');
  perform tests.eq((select count(*) from public.audit_log where job_id = v_job and summary = 'Standard marked met' and actor = (f ->> 'buyer')::uuid), 3::bigint, 'each verdict is logged with the client who gave it');
  perform tests.ok(exists (select 1 from public.audit_log where job_id = v_job and summary like 'Job status % to completed'), 'the job moving to completed is logged');
  perform tests.ok(exists (select 1 from public.audit_log where job_id = v_job and table_name = 'payments'), 'the payment lines created on approval are logged');
  perform tests.ok(not exists (select 1 from public.audit_log where changes ? 'updated_at'), 'updated_at noise is left out');

  -- An update records only what changed, from and to.
  perform tests.eq((select changes -> 'verdict' ->> 'to' from public.audit_log where job_id = v_job and summary = 'Standard marked met' limit 1), 'met', 'an update records the new value');
  perform tests.ok((select not (changes ? 'standard_id') from public.audit_log where job_id = v_job and summary = 'Standard marked met' limit 1), 'and only the changed columns');

  -- Only Duly reads the log.
  perform tests.as_user((f ->> 'admin')::uuid);
  perform tests.ok((select count(*) from public.audit_log) > 0, 'a platform admin can read the log');
  foreach v_other in array array[(f ->> 'buyer')::uuid, (f ->> 'vendor')::uuid, (f ->> 'crew')::uuid, tests.mk_user('stranger')] loop
    perform tests.as_user(v_other);
    select count(*) into n from public.audit_log;
    perform tests.eq(n, 0::bigint, 'a buyer, vendor, crew member or stranger sees no log rows');
    perform tests.throws(format('select * from public.admin_case_timeline(%L)', v_brief), '%Only Duly%', 'and cannot call the timeline');
    perform tests.throws('insert into public.audit_log (table_name, op, summary) values (''x'', ''INSERT'', ''forged'')', '%row-level security%', 'and cannot write to the log');
  end loop;
  perform tests.as_anon();
  select count(*) into n from public.audit_log;
  perform tests.eq(n, 0::bigint, 'signed-out visitors see no log rows');

  -- Append-only, even for the platform admin and the database owner.
  perform tests.as_user((f ->> 'admin')::uuid);
  update public.audit_log set summary = 'edited';
  get diagnostics n = row_count;
  perform tests.eq(n, 0::bigint, 'a platform admin cannot edit the log (no row is changed)');
  delete from public.audit_log;
  get diagnostics n = row_count;
  perform tests.eq(n, 0::bigint, 'or delete from it');
  perform tests.as_su();
  perform tests.throws('update public.audit_log set summary = ''edited''', '%append-only%', 'the owner cannot edit it either');
  perform tests.throws('delete from public.audit_log where id = (select min(id) from public.audit_log)', '%append-only%', 'or delete a row');
  perform tests.throws('truncate public.audit_log', '%append-only%', 'or truncate it');

  -- The timeline merges the log with the job's own events, with names and addresses for each actor.
  perform tests.as_user((f ->> 'admin')::uuid);
  perform tests.throws('select * from public.admin_case_timeline()', '%Choose a brief%', 'the timeline needs something to look at');
  select count(*) into n from public.admin_case_timeline(v_brief);
  perform tests.ok(n > 15, 'the timeline for a brief returns the whole chain');
  perform tests.ok(exists (select 1 from public.admin_case_timeline(v_brief) where kind = 'job_event' and summary = 'Job event: check in' and within_geofence), 'it includes the crew check-in with its geofence result');
  perform tests.ok((select bool_and(at >= lag_at) from (select at, coalesce(lag(at) over (order by ordinality), at) as lag_at from public.admin_case_timeline(v_brief) with ordinality) x), 'in time order');
  perform tests.ok(exists (select 1 from public.admin_case_timeline(p_job => v_job) where actor_id = (f ->> 'crew')::uuid), 'a job can be looked up on its own');
  perform tests.ok(exists (select 1 from public.admin_case_timeline(p_org => (f ->> 'vendor_org')::uuid) where table_name = 'quotes'), 'an organisation can be looked up on its own');
  perform tests.ok(exists (select 1 from public.admin_case_timeline(v_brief) where actor_email like 'buyer-%'), 'each actor is named by email so the admin knows who it was');

  -- The log survives the thing it describes being deleted (a job with no money against it can be removed).
  declare f2 jsonb; j2 uuid;
  begin
    f2 := tests.book_job('sme'); j2 := (f2 ->> 'job')::uuid;
    perform tests.as_su();
    select count(*) into n from public.audit_log where job_id = j2;
    delete from public.jobs where id = j2;
    perform tests.ok((select count(*) from public.audit_log where job_id = j2) > n, 'deleting a job leaves its history in place and adds to it');
    perform tests.ok(exists (select 1 from public.audit_log where job_id = j2 and table_name = 'jobs' and op = 'DELETE'), 'and records the deletion');
  end;
end $$;

-- Issues, AI drafts and verification claims, and what is kept out.
do $$
declare
  f jsonb := tests.book_job('sme'); v_job uuid; v_item uuid; v_claim uuid; v_issue uuid;
begin
  v_job := (f ->> 'job')::uuid;
  perform tests.as_user((f ->> 'buyer')::uuid);
  insert into public.issues (job_id, kind, description) values (v_job, 'quality', 'Floors were not cleaned') returning id into v_issue;
  perform tests.as_user((f ->> 'admin')::uuid);
  update public.issues set status = 'vendor_fix', resolution = 'Vendor to redo' where id = v_issue;
  perform tests.ok(exists (select 1 from public.audit_log where job_id = v_job and table_name = 'issues' and op = 'INSERT' and actor = (f ->> 'buyer')::uuid), 'raising an issue is logged against the person who raised it');
  perform tests.ok(exists (select 1 from public.audit_log where table_name = 'issues' and summary = 'Issue status open to vendor_fix' and actor = (f ->> 'admin')::uuid), 'Duly changing its status is logged against Duly');
  perform tests.eq((select changes -> 'resolution' ->> 'to' from public.audit_log where table_name = 'issues' and row_id = v_issue::text and op = 'UPDATE' and changes ? 'resolution'), 'Vendor to redo', 'including what was decided');

  -- AI drafts: who approved and when, never the pasted text or the drafted brief.
  perform tests.as_user((f ->> 'buyer')::uuid);
  insert into public.approval_queue (org_id, draft, source) values ((f ->> 'buyer_org')::uuid, '{"title":"SECRET DRAFT TEXT"}', '{"pasted":"PRIVATE PASTE"}') returning id into v_item;
  perform tests.as_su();
  perform tests.ok(exists (select 1 from public.audit_log where table_name = 'approval_queue' and row_id = v_item::text), 'an AI draft arriving is logged');
  perform tests.ok(not exists (select 1 from public.audit_log where changes::text like '%SECRET DRAFT TEXT%' or changes::text like '%PRIVATE PASTE%'), 'but its text is not copied into the log');

  -- Vendor verification claims.
  perform tests.as_user((f ->> 'vendor')::uuid);
  insert into public.verification_claims (org_id, kind, reference, status) values ((f ->> 'vendor_org')::uuid, 'companies_house', '00000000', 'pending') returning id into v_claim;
  perform tests.as_su();
  perform tests.ok(exists (select 1 from public.audit_log where table_name = 'verification_claims' and row_id = v_claim::text), 'a verification claim is logged');
end $$;

-- A change that alters nothing is not logged.
do $$
declare f jsonb := tests.book_job('sme'); before bigint;
begin
  select count(*) into before from public.audit_log;
  update public.jobs set updated_at = now() where id = (f ->> 'job')::uuid;
  perform tests.eq((select count(*) from public.audit_log), before, 'touching only updated_at adds nothing');
end $$;

-- Rows that existed before the log are recorded once at their own time, marked as backfilled.
do $$
declare f jsonb := tests.book_job('sme'); j public.jobs;
begin
  select * into j from public.jobs where id = (f ->> 'job')::uuid;
  perform private.audit_write('jobs', 'INSERT', to_jsonb(j), null, null, j.created_at - interval '1 day', 'backfill', null);
  perform tests.eq((select count(*) from public.audit_log where job_id = j.id and source = 'backfill'), 1::bigint, 'a backfilled row is stored once');
  perform tests.eq((select at from public.audit_log where job_id = j.id and source = 'backfill'), j.created_at - interval '1 day', 'at the time the row says');
  perform tests.ok((select summary like '%who did it and any earlier changes were not logged%' from public.audit_log where job_id = j.id and source = 'backfill'), 'with a note that the actor and earlier changes are unknown');
  perform tests.ok(not exists (select 1 from public.audit_log where source = 'trigger' and summary like '%not logged%'), 'only backfilled rows carry that note');
end $$;
