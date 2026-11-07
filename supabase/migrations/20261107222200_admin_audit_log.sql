-- An append-only record of who did what and when, for Duly Admin to use as evidence when arbitrating.
--
-- Triggers write one row for every insert, change and delete on the tables that make up a request and its
-- consequences: the brief and its locked versions, quotes (invitation, submission, acceptance), contracts, jobs,
-- crew assignments, photos, ticks and verdicts, issues, payments, vendor verification claims and AI drafts.
-- Only changed columns are kept for updates. Rows are never changed or removed (a trigger refuses it), they hold
-- plain ids rather than foreign keys so they survive a deleted job, and only a platform admin can read them.
-- Notifications and check-in / late-alert job events are not duplicated here: the admin timeline joins job_events.
--
-- History from before this migration was not logged. The backfill below records what the current rows still
-- show (created, submitted, locked, verdict times) and marks those rows source = 'backfill'.

create table public.audit_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default clock_timestamp(),
  actor uuid,                -- auth.uid(); null for the system (cron, triggers) or for a backfilled row
  table_name text not null,
  op text not null check (op in ('INSERT', 'UPDATE', 'DELETE')),
  row_id text,
  brief_id uuid,
  quote_id uuid,
  job_id uuid,
  org_ids uuid[] not null default '{}',
  summary text not null,
  changes jsonb not null default '{}'::jsonb,
  source text not null default 'trigger' check (source in ('trigger', 'backfill'))
);
create index audit_log_brief_idx on public.audit_log (brief_id, at);
create index audit_log_job_idx on public.audit_log (job_id, at);
create index audit_log_quote_idx on public.audit_log (quote_id);
create index audit_log_at_idx on public.audit_log (at);
create index audit_log_actor_idx on public.audit_log (actor);
create index audit_log_orgs_idx on public.audit_log using gin (org_ids);

alter table public.audit_log enable row level security;
create policy "audit log readable by Duly" on public.audit_log for select to authenticated
  using (private.is_platform_admin());
-- No insert, update or delete policy: people cannot write to it. The triggers below are SECURITY DEFINER.

create function private.audit_log_immutable()
returns trigger language plpgsql set search_path = ''
as $$
begin
  raise exception 'The audit log is append-only';
end;
$$;
create trigger audit_log_no_change before update or delete on public.audit_log
  for each row execute function private.audit_log_immutable();
create trigger audit_log_no_truncate before truncate on public.audit_log
  for each statement execute function private.audit_log_immutable();

-- Writes one row. p_new / p_old are the row as jsonb; p_skip lists columns to leave out (large or personal text).
create function private.audit_write(
  p_table text, p_op text, p_new jsonb, p_old jsonb, p_actor uuid, p_at timestamptz, p_source text, p_skip text[])
returns void language plpgsql security definer set search_path = ''
as $$
declare
  j jsonb := coalesce(p_new, p_old);
  v_brief uuid; v_quote uuid; v_job uuid; v_row text; v_orgs uuid[] := '{}';
  v_buyer uuid; v_vendor uuid; v_org uuid; v_contract uuid;
  v_changes jsonb := '{}'::jsonb; v_summary text; v_kind text; k text; v_noun text;
begin
  -- Which brief, quote and job this belongs to.
  v_brief := nullif(coalesce(j ->> 'brief_id', case when p_table = 'briefs' then j ->> 'id' end), '')::uuid;
  v_quote := nullif(coalesce(case when p_table = 'quotes' then j ->> 'id' end, j ->> 'quote_id'), '')::uuid;
  v_job := nullif(coalesce(case when p_table = 'jobs' then j ->> 'id' end, j ->> 'job_id'), '')::uuid;
  v_row := coalesce(j ->> 'id', concat_ws('/', j ->> 'job_id', j ->> 'area_id', j ->> 'standard_id', j ->> 'user_id', j ->> 'brief_id', j ->> 'version'));
  v_buyer := nullif(j ->> 'buyer_org_id', '')::uuid;
  v_vendor := nullif(j ->> 'vendor_org_id', '')::uuid;
  v_org := nullif(j ->> 'org_id', '')::uuid;
  v_contract := nullif(j ->> 'contract_id', '')::uuid;

  if v_job is not null and (v_brief is null or v_buyer is null or v_vendor is null) then
    select coalesce(v_brief, jb.brief_id), coalesce(v_quote, jb.quote_id), coalesce(v_buyer, jb.buyer_org_id), coalesce(v_vendor, jb.vendor_org_id)
      into v_brief, v_quote, v_buyer, v_vendor from public.jobs jb where jb.id = v_job;
  end if;
  if v_contract is not null and v_job is null and (v_buyer is null or v_vendor is null) then
    select coalesce(v_brief, c.brief_id), coalesce(v_quote, c.quote_id), coalesce(v_buyer, c.buyer_org_id), coalesce(v_vendor, c.vendor_org_id)
      into v_brief, v_quote, v_buyer, v_vendor from public.contracts c where c.id = v_contract;
  end if;
  if v_brief is not null and v_buyer is null then
    select b.buyer_org_id into v_buyer from public.briefs b where b.id = v_brief;
  end if;
  select coalesce(array_agg(distinct o), '{}') into v_orgs from unnest(array[v_buyer, v_vendor, v_org]) o where o is not null;

  -- What changed: everything for an insert or delete, only the changed columns for an update.
  if p_op = 'UPDATE' then
    for k in select key from jsonb_object_keys(p_new) key loop
      continue when k = 'updated_at' or k = any (coalesce(p_skip, '{}'));
      if p_new -> k is distinct from p_old -> k then
        v_changes := v_changes || jsonb_build_object(k, jsonb_build_object('from', p_old -> k, 'to', p_new -> k));
      end if;
    end loop;
    if v_changes = '{}'::jsonb then return; end if;   -- nothing worth recording changed
  else
    v_changes := j - coalesce(p_skip, '{}') - 'updated_at';
  end if;

  v_kind := coalesce(j ->> 'kind', '');
  v_noun := case p_table
    when 'briefs' then 'Brief' when 'brief_versions' then 'Brief version' when 'quotes' then 'Quote' when 'contracts' then 'Contract'
    when 'jobs' then 'Job' when 'job_assignments' then 'Crew assignment' when 'evidence' then 'Photo' when 'area_results' then 'Standard'
    when 'issues' then 'Issue' when 'payments' then 'Payment' when 'verification_claims' then 'Verification claim'
    when 'approval_queue' then 'AI draft' else initcap(replace(p_table, '_', ' ')) end;
  v_summary := v_noun || case p_op when 'INSERT' then ' created' when 'DELETE' then ' deleted' else ' updated' end;
  if p_op = 'UPDATE' then
    if v_changes ? 'status' then
      v_summary := v_noun || ' status ' || coalesce(p_old ->> 'status', 'none') || ' to ' || coalesce(p_new ->> 'status', 'none');
    elsif v_changes ? 'verdict' then
      v_summary := 'Standard marked ' || replace(coalesce(p_new ->> 'verdict', 'cleared'), '_', ' ');
    elsif v_changes ? 'locked_at' then
      v_summary := 'Brief version ' || (p_new ->> 'version') || ' locked';
    elsif v_changes ? 'done_by_operative' then
      v_summary := 'Standard ' || case when (p_new ->> 'done_by_operative')::boolean then 'ticked' else 'unticked' end || ' by crew';
    end if;
  elsif p_table = 'area_results' and p_op = 'INSERT' then
    v_summary := case when (p_new ->> 'done_by_operative')::boolean then 'Standard ticked by crew' else 'Standard added to the checklist' end;
  elsif v_kind <> '' then
    v_summary := v_summary || ' (' || replace(v_kind, '_', ' ') || ')';
  end if;
  if p_source = 'backfill' then
    v_summary := v_summary || ' (recorded from the current row: who did it and any earlier changes were not logged)';
  end if;

  insert into public.audit_log (at, actor, table_name, op, row_id, brief_id, quote_id, job_id, org_ids, summary, changes, source)
  values (coalesce(p_at, clock_timestamp()), p_actor, p_table, p_op, v_row, v_brief, v_quote, v_job, v_orgs, v_summary, v_changes, p_source);
end;
$$;

create function private.audit_row()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  perform private.audit_write(
    tg_table_name, tg_op,
    case when tg_op <> 'DELETE' then to_jsonb(new) end,
    case when tg_op <> 'INSERT' then to_jsonb(old) end,
    (select auth.uid()), clock_timestamp(), 'trigger', tg_argv);
  return null;
end;
$$;

revoke execute on function private.audit_write(text, text, jsonb, jsonb, uuid, timestamptz, text, text[]), private.audit_row(),
  private.audit_log_immutable() from public, anon, authenticated;

create trigger audit_briefs after insert or update or delete on public.briefs for each row execute function private.audit_row();
create trigger audit_brief_versions after insert or update or delete on public.brief_versions for each row execute function private.audit_row();
create trigger audit_quotes after insert or update or delete on public.quotes for each row execute function private.audit_row();
create trigger audit_contracts after insert or update or delete on public.contracts for each row execute function private.audit_row();
create trigger audit_jobs after insert or update or delete on public.jobs for each row execute function private.audit_row();
create trigger audit_job_assignments after insert or update or delete on public.job_assignments for each row execute function private.audit_row();
create trigger audit_evidence after insert or update or delete on public.evidence for each row execute function private.audit_row();
create trigger audit_area_results after insert or update or delete on public.area_results for each row execute function private.audit_row();
create trigger audit_issues after insert or update or delete on public.issues for each row execute function private.audit_row();
create trigger audit_payments after insert or update or delete on public.payments for each row execute function private.audit_row();
create trigger audit_verification_claims after insert or update or delete on public.verification_claims for each row execute function private.audit_row();
-- AI drafts: keep who approved or rejected and when, not the pasted text or the drafted brief.
create trigger audit_approval_queue after insert or update or delete on public.approval_queue
  for each row execute function private.audit_row('draft', 'final_draft', 'source');

-- Backfill from the rows as they stand, once, at their own timestamps.
do $$
declare r record;
begin
  for r in select * from public.briefs loop
    perform private.audit_write('briefs', 'INSERT', to_jsonb(r), null, r.created_by, r.created_at, 'backfill', null);
  end loop;
  for r in select * from public.brief_versions loop
    perform private.audit_write('brief_versions', 'INSERT', to_jsonb(r) - 'locked_at' - 'locked_by', null, null, r.created_at, 'backfill', null);
    if r.locked_at is not null then
      perform private.audit_write('brief_versions', 'UPDATE', to_jsonb(r), to_jsonb(r) - 'locked_at' - 'locked_by', r.locked_by, r.locked_at, 'backfill', null);
    end if;
  end loop;
  for r in select * from public.quotes loop
    perform private.audit_write('quotes', 'INSERT', to_jsonb(r) || jsonb_build_object('status', 'invited'), null, null, r.created_at, 'backfill', null);
    if r.submitted_at is not null then
      perform private.audit_write('quotes', 'UPDATE', to_jsonb(r),
        to_jsonb(r) || jsonb_build_object('status', 'invited'), null, r.submitted_at, 'backfill', null);
    end if;
  end loop;
  for r in select * from public.contracts loop
    perform private.audit_write('contracts', 'INSERT', to_jsonb(r), null, null, r.created_at, 'backfill', null);
  end loop;
  for r in select * from public.jobs loop
    perform private.audit_write('jobs', 'INSERT', to_jsonb(r), null, null, r.created_at, 'backfill', null);
  end loop;
  for r in select * from public.job_assignments loop
    perform private.audit_write('job_assignments', 'INSERT', to_jsonb(r), null, null, r.created_at, 'backfill', null);
  end loop;
  for r in select * from public.evidence loop
    perform private.audit_write('evidence', 'INSERT', to_jsonb(r), null, r.uploaded_by, r.created_at, 'backfill', null);
  end loop;
  for r in select * from public.area_results where done_at is not null or verdict_at is not null loop
    if r.done_at is not null then
      perform private.audit_write('area_results', 'UPDATE', to_jsonb(r),
        to_jsonb(r) || jsonb_build_object('done_by_operative', false), r.done_by, r.done_at, 'backfill', null);
    end if;
    if r.verdict_at is not null then
      perform private.audit_write('area_results', 'UPDATE', to_jsonb(r),
        to_jsonb(r) || jsonb_build_object('verdict', null), r.verdict_by, r.verdict_at, 'backfill', null);
    end if;
  end loop;
  for r in select * from public.issues loop
    perform private.audit_write('issues', 'INSERT', to_jsonb(r), null, r.raised_by, r.created_at, 'backfill', null);
  end loop;
  for r in select * from public.payments loop
    perform private.audit_write('payments', 'INSERT', to_jsonb(r), null, null, r.created_at, 'backfill', null);
  end loop;
  for r in select * from public.verification_claims loop
    perform private.audit_write('verification_claims', 'INSERT', to_jsonb(r), null, r.subject_user_id, r.created_at, 'backfill', null);
  end loop;
  for r in select * from public.approval_queue loop
    perform private.audit_write('approval_queue', 'INSERT', to_jsonb(r), null, null, r.created_at, 'backfill', array['draft', 'final_draft', 'source']);
  end loop;
end $$;

-- The one way to read it, merged with the job's own events (check-in, late alerts, notes), with who did each thing.
-- Pass a brief, a job, or an organisation (or any mix: a row matching any of them is returned).
create function public.admin_case_timeline(
  p_brief uuid default null, p_job uuid default null, p_org uuid default null, p_limit integer default 1000)
returns table (
  at timestamptz, kind text, table_name text, op text, summary text, changes jsonb,
  actor_id uuid, actor_name text, actor_email text, brief_id uuid, quote_id uuid, job_id uuid, org_ids uuid[],
  lat numeric, lng numeric, within_geofence boolean, source text)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.is_platform_admin() then raise exception 'Only Duly can read the case timeline'; end if;
  if p_brief is null and p_job is null and p_org is null then raise exception 'Choose a brief, a job or an organisation'; end if;
  return query
    with a as (
      select l.at, 'audit'::text as kind, l.table_name, l.op, l.summary, l.changes, l.actor,
             l.brief_id, l.quote_id, l.job_id, l.org_ids, null::numeric as lat, null::numeric as lng, null::boolean as geo, l.source
        from public.audit_log l
       where l.brief_id = p_brief or l.job_id = p_job or p_org = any (l.org_ids)
      union all
      select e.at, 'job_event', 'job_events', 'INSERT',
             'Job event: ' || replace(e.kind, '_', ' '), e.data, e.actor,
             jb.brief_id, jb.quote_id, e.job_id, array[jb.buyer_org_id, jb.vendor_org_id], e.lat, e.lng, e.within_geofence, 'trigger'
        from public.job_events e join public.jobs jb on jb.id = e.job_id
       where jb.brief_id = p_brief or e.job_id = p_job or p_org in (jb.buyer_org_id, jb.vendor_org_id))
    select a.at, a.kind, a.table_name, a.op, a.summary, a.changes, a.actor, p.full_name, u.email::text,
           a.brief_id, a.quote_id, a.job_id, a.org_ids, a.lat, a.lng, a.geo, a.source
      from a left join public.profiles p on p.id = a.actor left join auth.users u on u.id = a.actor
     order by a.at, a.kind
     limit greatest(1, least(coalesce(p_limit, 1000), 5000));
end;
$$;
revoke execute on function public.admin_case_timeline(uuid, uuid, uuid, integer) from public, anon;
grant execute on function public.admin_case_timeline(uuid, uuid, uuid, integer) to authenticated;
