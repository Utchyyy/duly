-- Per-area ticks and photos for jobs that have a work schedule.
--
-- For a visit, the cleaning areas planned for that weekday are the checklist: the crew tick each one and take at least one
-- after photo for every sub-section worked; the client then checks the same areas and either accepts them or reports a
-- problem on an exact area. A job with no work schedule, or whose schedule plans nothing on the visit's weekday, keeps the
-- brief-standards check exactly as before. The weekday is taken in the buyer's market timezone.

-- The locked plan for a job, and the weekday of its visit.
create function private.job_workplan(p_job uuid)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select ws.plan from public.jobs j join public.work_schedules ws on ws.quote_id = j.quote_id and ws.status = 'locked' where j.id = p_job;
$$;

create function private.job_weekday(p_job uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select lower(to_char(j.scheduled_start at time zone coalesce(
           (select m.timezone from public.organisations o join public.markets m on m.code = o.market where o.id = j.buyer_org_id), 'UTC'), 'dy'))
    from public.jobs j where j.id = p_job;
$$;

-- The cleaning areas planned for this visit's weekday, with the sub-section and section each belongs to.
create function private.job_planned_rows(p_job uuid)
returns table (item_id text, item_name text, group_id text, group_name text, section_name text)
language sql stable security definer set search_path = ''
as $$
  select a ->> 'id', a ->> 'name', ss ->> 'id', ss ->> 'name', s ->> 'name'
    from jsonb_array_elements(coalesce(private.job_workplan(p_job) -> 'sections', '[]')) s,
         jsonb_array_elements(coalesce(s -> 'subsections', '[]')) ss,
         jsonb_array_elements(coalesce(ss -> 'areas', '[]')) a
   where jsonb_exists(coalesce(a -> 'days', '{}'), private.job_weekday(p_job));
$$;

create function private.job_uses_plan(p_job uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from private.job_planned_rows(p_job));
$$;

-- For the app: the visit's weekday when the schedule decides the check, otherwise null (the standards check applies).
create function public.job_plan_day(p_job uuid)
returns text language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.can_see_job(p_job) then raise exception 'Job not found'; end if;
  if not private.job_uses_plan(p_job) then return null; end if;
  return private.job_weekday(p_job);
end;
$$;

create table public.plan_results (
  job_id uuid not null references public.jobs(id) on delete cascade,
  plan_item_id text not null check (length(plan_item_id) between 1 and 60),
  done boolean not null default false,
  done_at timestamptz,
  done_by uuid references auth.users(id) on delete set null,
  verdict text check (verdict in ('met', 'not_met')),
  verdict_at timestamptz,
  verdict_by uuid references auth.users(id) on delete set null,
  primary key (job_id, plan_item_id)
);
create index plan_results_done_by_idx on public.plan_results (done_by);
create index plan_results_verdict_by_idx on public.plan_results (verdict_by);
alter table public.plan_results enable row level security;

create policy "plan results visible" on public.plan_results for select to authenticated using (private.can_see_job(job_id));
create policy "plan results ticked by crew" on public.plan_results for insert to authenticated
  with check (private.can_work_job(job_id) and verdict is null);
create policy "plan results updated by crew or buyer" on public.plan_results for update to authenticated
  using (private.can_work_job(job_id) or private.is_job_buyer(job_id))
  with check (private.can_work_job(job_id) or private.is_job_buyer(job_id));

create function private.protect_plan_result_fields()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare v_status public.job_status;
begin
  select status into v_status from public.jobs where id = new.job_id;
  if tg_op = 'INSERT' then
    if not exists (select 1 from private.job_planned_rows(new.job_id) r where r.item_id = new.plan_item_id) then
      raise exception 'That cleaning area is not planned for this visit';
    end if;
  elsif new.plan_item_id <> old.plan_item_id or new.job_id <> old.job_id then
    raise exception 'A result cannot be moved';
  end if;

  -- Only the client gives a verdict, and only once the cleaner has finished.
  if (tg_op = 'INSERT' and new.verdict is not null) or (tg_op = 'UPDATE' and new.verdict is distinct from old.verdict) then
    if not (private.is_job_buyer(new.job_id) or private.is_platform_admin()) then
      raise exception 'Only the client can mark a cleaning area met or not met';
    end if;
    if v_status not in ('completed', 'disputed') and not private.is_platform_admin() then
      raise exception 'The client checks the work once the cleaner has finished';
    end if;
    new.verdict_at := now();
    new.verdict_by := (select auth.uid());
  end if;

  -- Only the crew tick, and only while the job is in progress.
  if (tg_op = 'INSERT' and new.done) or (tg_op = 'UPDATE' and new.done is distinct from old.done) then
    if not private.can_work_job(new.job_id) then raise exception 'Only the crew can tick a cleaning area'; end if;
    if v_status <> 'in_progress' and not private.is_platform_admin() then
      raise exception 'Cleaning areas can only be ticked while the job is in progress';
    end if;
  end if;
  if new.done and (tg_op = 'INSERT' or not old.done) then
    new.done_at := now();
    new.done_by := (select auth.uid());
  elsif not new.done then
    new.done_at := null;
    new.done_by := null;
  end if;
  return new;
end;
$$;
create trigger plan_results_protect before insert or update on public.plan_results
  for each row execute function private.protect_plan_result_fields();

-- A photo can name the cleaning area it shows; it is filed under that area's sub-section, worked out here.
alter table public.evidence add column plan_item_id text check (length(plan_item_id) <= 60);
create function private.evidence_plan_item()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare v_group text;
begin
  if new.plan_item_id is null then return new; end if;
  select r.group_id into v_group from private.job_planned_rows(new.job_id) r where r.item_id = new.plan_item_id;
  if v_group is null then raise exception 'That cleaning area is not planned for this visit'; end if;
  new.area_id := v_group;
  return new;
end;
$$;
create trigger evidence_plan_item before insert on public.evidence
  for each row execute function private.evidence_plan_item();

-- A problem the client reports on an exact area marks that area not met, so the job cannot be approved until it is put right.
create function private.issue_marks_area()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare v_status public.job_status;
begin
  if new.plan_item_id is null or new.job_id is null then return null; end if;
  if not (private.is_job_buyer(new.job_id) or private.is_platform_admin()) then return null; end if;
  select status into v_status from public.jobs where id = new.job_id;
  if v_status not in ('completed', 'disputed') then return null; end if;
  if not exists (select 1 from private.job_planned_rows(new.job_id) r where r.item_id = new.plan_item_id) then return null; end if;
  insert into public.plan_results (job_id, plan_item_id, done, verdict) values (new.job_id, new.plan_item_id, false, 'not_met')
    on conflict (job_id, plan_item_id) do update set verdict = 'not_met';
  return null;
end;
$$;
create trigger issues_mark_area after insert on public.issues
  for each row execute function private.issue_marks_area();

-- Finishing a job: with a schedule, every planned area ticked and an after photo for every sub-section worked.
create or replace function public.complete_job(p_job uuid, p_lat numeric default null, p_lng numeric default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_job public.jobs;
  v_no_photo integer;
  v_unticked integer;
  v_lat numeric; v_lng numeric; v_fence integer;
begin
  if not private.can_work_job(p_job) then raise exception 'You are not on this job'; end if;
  select * into v_job from public.jobs where id = p_job for update;
  if v_job.status <> 'in_progress' then raise exception 'Check in before completing the job'; end if;

  if private.job_uses_plan(p_job) then
    select count(*) into v_no_photo from (select distinct group_id from private.job_planned_rows(p_job)) g
     where not exists (select 1 from public.evidence e where e.job_id = p_job and e.area_id = g.group_id and e.kind = 'photo_after');
    select count(*) into v_unticked from private.job_planned_rows(p_job) r
     where not exists (select 1 from public.plan_results pr where pr.job_id = p_job and pr.plan_item_id = r.item_id and pr.done);
    if v_no_photo > 0 then raise exception '% part(s) of the site still need an after photo', v_no_photo; end if;
    if v_unticked > 0 then raise exception '% cleaning area(s) still need ticking', v_unticked; end if;
  else
    with areas as (
      select a ->> 'id' as area_id, coalesce(a -> 'standards', '[]'::jsonb) as standards
      from public.brief_versions bv, jsonb_array_elements(bv.schedule) sec, jsonb_array_elements(sec -> 'areas') a
      where bv.brief_id = v_job.brief_id and bv.version = v_job.brief_version
    )
    select
      (select count(*) from areas where not exists (
         select 1 from public.evidence e where e.job_id = p_job and e.area_id = areas.area_id and e.kind = 'photo_after')),
      (select count(*) from areas, jsonb_array_elements(areas.standards) st where not exists (
         select 1 from public.area_results r where r.job_id = p_job and r.area_id = areas.area_id
           and r.standard_id = st ->> 'id' and r.done_by_operative))
    into v_no_photo, v_unticked;

    if v_no_photo > 0 then raise exception '% area(s) still need an after photo', v_no_photo; end if;
    if v_unticked > 0 then raise exception '% standard(s) still need ticking', v_unticked; end if;
  end if;

  select s.lat, s.lng, s.geofence_m into v_lat, v_lng, v_fence from public.sites s where s.id = v_job.site_id;
  insert into public.job_events (job_id, kind, lat, lng, within_geofence)
  values (p_job, 'check_out', p_lat, p_lng,
          case when v_lat is null or p_lat is null then null
               else public.haversine_km(v_lat, v_lng, p_lat, p_lng) * 1000 <= v_fence end);
  update public.jobs set status = 'completed', updated_at = now() where id = p_job;
end;
$$;

-- Approving a job: with a schedule, every planned area must have been accepted and none marked not met.
create or replace function public.approve_job(p_job uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_job public.jobs;
  v_pol public.policies;
  v_first numeric; v_fee numeric; v_balance numeric;
  v_first_due timestamptz;
begin
  if not (private.is_job_buyer(p_job) or private.is_platform_admin()) then
    raise exception 'Only the client can approve this job';
  end if;
  select * into v_job from public.jobs where id = p_job for update;
  if v_job.status <> 'completed' then raise exception 'Only a completed job can be approved'; end if;
  if private.job_uses_plan(p_job) then
    if exists (select 1 from private.job_planned_rows(p_job) r
                where not exists (select 1 from public.plan_results pr where pr.job_id = p_job and pr.plan_item_id = r.item_id and pr.verdict is not null)) then
      raise exception 'Check every cleaning area first: accept it or report a problem';
    end if;
    if exists (select 1 from public.plan_results where job_id = p_job and verdict = 'not_met') then
      raise exception 'Some cleaning areas were not right: report a problem so the vendor can put it right';
    end if;
  else
    if exists (select 1 from public.area_results where job_id = p_job and verdict is null) then
      raise exception 'Mark every standard met or not met first';
    end if;
    if exists (select 1 from public.area_results where job_id = p_job and verdict = 'not_met') then
      raise exception 'Some standards were not met: report an issue so the vendor can put it right';
    end if;
  end if;

  v_pol := private.policy_for_org(v_job.buyer_org_id);
  v_first := round(coalesce(v_job.value, 0) * v_pol.first_release_pct / 100, 2);
  v_fee := round(coalesce(v_job.value, 0) * coalesce(v_pol.platform_fee_pct, 0) / 100, 2);
  v_balance := coalesce(v_job.value, 0) - v_first - v_fee;
  v_first_due := case v_pol.first_release_on
    when 'month_end' then date_trunc('month', now()) + interval '1 month' - interval '1 minute'
    else now() end;

  update public.jobs set status = 'quality_verified', updated_at = now() where id = p_job;
  insert into public.job_events (job_id, kind, data) values (p_job, 'status_change', jsonb_build_object('to', 'quality_verified'));

  insert into public.payments (job_id, contract_id, kind, amount, currency, provider, status, due_at, note) values
    (p_job, v_job.contract_id, 'release', v_first, v_job.currency, 'manual', 'pending', v_first_due,
     format('First release (%s%%) on %s', v_pol.first_release_pct, replace(v_pol.first_release_on, '_', ' '))),
    (p_job, v_job.contract_id, 'release', v_balance, v_job.currency, 'manual', 'pending',
     now() + make_interval(hours => v_pol.balance_release_hours),
     format('Balance, released %s hours after approval if no complaint', v_pol.balance_release_hours));
  if v_fee > 0 then
    insert into public.payments (job_id, contract_id, kind, amount, currency, provider, status, due_at, note)
    values (p_job, v_job.contract_id, 'platform_fee', v_fee, v_job.currency, 'manual', 'pending',
            now() + make_interval(hours => v_pol.balance_release_hours),
            format('Duly fee (%s%%), taken from the balance', v_pol.platform_fee_pct));
  end if;

  perform private.recompute_vendor_score(v_job.vendor_org_id);
end;
$$;

revoke execute on function private.job_workplan(uuid), private.job_weekday(uuid), private.job_planned_rows(uuid), private.job_uses_plan(uuid),
  private.protect_plan_result_fields(), private.evidence_plan_item(), private.issue_marks_area() from public, anon, authenticated;
revoke execute on function public.job_plan_day(uuid) from public, anon;
grant execute on function public.job_plan_day(uuid) to authenticated;

-- The audit log records each tick and verdict on a cleaning area, with who and when.
create or replace function private.audit_write(
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
  v_row := coalesce(j ->> 'id', concat_ws('/', j ->> 'job_id', j ->> 'area_id', j ->> 'standard_id', j ->> 'plan_item_id', j ->> 'user_id', j ->> 'brief_id', j ->> 'version'));
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
    when 'approval_queue' then 'AI draft' when 'work_schedules' then 'Work schedule' when 'plan_results' then 'Cleaning area' else initcap(replace(p_table, '_', ' ')) end;
  v_summary := v_noun || case p_op when 'INSERT' then ' created' when 'DELETE' then ' deleted' else ' updated' end;
  if p_op = 'UPDATE' then
    if v_changes ? 'status' then
      v_summary := v_noun || ' status ' || coalesce(p_old ->> 'status', 'none') || ' to ' || coalesce(p_new ->> 'status', 'none');
    elsif v_changes ? 'verdict' then
      v_summary := case when p_table = 'plan_results' then 'Cleaning area' else 'Standard' end || ' marked ' || replace(coalesce(p_new ->> 'verdict', 'cleared'), '_', ' ');
    elsif v_changes ? 'locked_at' then
      v_summary := 'Brief version ' || (p_new ->> 'version') || ' locked';
    elsif p_table = 'plan_results' and v_changes ? 'done' then
      v_summary := 'Cleaning area ' || case when (p_new ->> 'done')::boolean then 'ticked' else 'unticked' end || ' by crew';
    elsif v_changes ? 'done_by_operative' then
      v_summary := 'Standard ' || case when (p_new ->> 'done_by_operative')::boolean then 'ticked' else 'unticked' end || ' by crew';
    end if;
  elsif p_table = 'plan_results' and p_op = 'INSERT' then
    v_summary := case when (p_new ->> 'done')::boolean then 'Cleaning area ticked by crew' else 'Cleaning area result added' end;
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
create trigger audit_plan_results after insert or update or delete on public.plan_results for each row execute function private.audit_row();
