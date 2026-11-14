-- One checklist: the work schedule is the checklist for every new job; the brief's standards live on inside it.
--
-- Before this, a job used the vendor's work schedule if there was one, and otherwise the client's brief standards, ticked and
-- judged one by one (a second, parallel checklist). A complaint on that second path could not name a cleaning area, so it could
-- not get a rework visit. Now:
--
--  1. No vendor schedule: when the client accepts a quote the vendor sent no schedule for, Duly builds one from the brief and locks
--     it. Each brief area becomes a sub-section (with the same id, so photos stay filed under it and it stays linked to the brief
--     area), each standard a cleaning area, on every day, with the brief's minutes shared across them (so planned time still
--     matches the booking). An area with no standards is one cleaning area. A brief with nothing in it gets no schedule.
--  2. A vendor schedule: a sub-section the vendor linked to a brief area (the link the editor already saved) also carries that
--     area's standards, written into the locked plan as extra cleaning areas flagged `standard` (the client's own requirements)
--     on the days the sub-section is worked. They are ticked, judged, complained about and measured like any other area, and
--     add no planned minutes: the vendor's minutes are for the vendor's work.
--  3. A weekday the schedule plans nothing: no area checklist. The crew take at least one after photo and finish; the client
--     approves the visit as a whole or reports a problem on it.
--  Jobs with no locked schedule at all (made before this, or from an empty brief) keep the old standards check.
-- `job_check_mode` tells the app which applies: 'plan', 'photos' or 'standards'.

create function private.job_has_schedule(p_job uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.jobs j join public.work_schedules ws on ws.quote_id = j.quote_id and ws.status = 'locked' where j.id = p_job);
$$;

create function public.job_check_mode(p_job uuid)
returns text language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.can_see_job(p_job) then raise exception 'Job not found'; end if;
  return case when private.job_uses_plan(p_job) then 'plan' when private.job_has_schedule(p_job) then 'photos' else 'standards' end;
end;
$$;

-- A schedule from the brief: its areas as sub-sections, its standards as cleaning areas, every day, 'clean' with shared minutes.
create function private.derive_work_schedule(p_brief uuid, p_version integer)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  v_sched jsonb; sec jsonb; ar jsonb; st jsonb;
  v_sections jsonb := '[]'; v_subs jsonb; v_areas jsonb;
  v_all jsonb := '{"mon":"clean","tue":"clean","wed":"clean","thu":"clean","fri":"clean","sat":"clean","sun":"clean"}';
  i integer := 0; n integer := 0; v_min numeric; m integer;
begin
  select bv.schedule into v_sched from public.brief_versions bv where bv.brief_id = p_brief and bv.version = p_version;
  if v_sched is null or jsonb_typeof(v_sched) <> 'array' then return null; end if;
  for sec in select * from jsonb_array_elements(v_sched) loop
    i := i + 1; v_subs := '[]';
    for ar in select * from jsonb_array_elements(coalesce(sec -> 'areas', '[]')) loop
      v_areas := '[]';
      if jsonb_typeof(coalesce(ar -> 'standards', '[]')) = 'array' and jsonb_array_length(coalesce(ar -> 'standards', '[]')) > 0 then
        for st in select * from jsonb_array_elements(ar -> 'standards') loop
          n := n + 1;
          v_areas := v_areas || jsonb_build_array(jsonb_build_object('id', 'd' || n,
            'name', left(coalesce(nullif(trim(st ->> 'text'), ''), 'Standard'), 200), 'days', v_all));
        end loop;
      else
        n := n + 1;
        v_areas := jsonb_build_array(jsonb_build_object('id', 'd' || n, 'name', left(coalesce(nullif(trim(ar ->> 'name'), ''), 'Area'), 200), 'days', v_all));
      end if;
      v_subs := v_subs || jsonb_build_array(jsonb_build_object('id', left(coalesce(ar ->> 'id', 'a' || i || '-' || n), 60),
        'name', left(coalesce(nullif(trim(ar ->> 'name'), ''), 'Area'), 120), 'brief_area_id', ar ->> 'id', 'areas', v_areas));
    end loop;
    v_sections := v_sections || jsonb_build_array(jsonb_build_object('id', 's' || i,
      'name', left(coalesce(nullif(trim(sec ->> 'name'), ''), 'Areas'), 120), 'subsections', v_subs));
  end loop;
  if n = 0 then return null; end if;
  v_min := private.schedule_minutes(p_brief, p_version);
  m := greatest(1, least(600, round(coalesce(v_min, 0) / n)::integer));
  return jsonb_build_object('plan', jsonb_build_object('sections', v_sections),
                            'legend', jsonb_build_object('clean', jsonb_build_object('label', 'Clean', 'minutes', m)));
end;
$$;

-- A vendor's plan with the client's standards written in: each sub-section linked to a brief area gets that area's standards as
-- extra cleaning areas flagged `standard`, on every day the sub-section's own areas are worked.
create function private.plan_with_standards(p_plan jsonb, p_brief jsonb)
returns jsonb language plpgsql stable set search_path = ''
as $$
declare
  v_secs jsonb := '[]'; v_subs jsonb; v_areas jsonb; v_days jsonb; s jsonb; ss jsonb; a jsonb; d text; v_area jsonb; v_std jsonb;
  n integer := 0; taken text[]; v_id text;
begin
  if p_brief is null or jsonb_typeof(p_brief) <> 'array' then return p_plan; end if;
  select coalesce(array_agg(ar ->> 'id'), '{}') into taken
    from jsonb_array_elements(coalesce(p_plan -> 'sections', '[]')) sx, jsonb_array_elements(coalesce(sx -> 'subsections', '[]')) sy,
         jsonb_array_elements(coalesce(sy -> 'areas', '[]')) ar;
  for s in select * from jsonb_array_elements(coalesce(p_plan -> 'sections', '[]')) loop
    v_subs := '[]';
    for ss in select * from jsonb_array_elements(coalesce(s -> 'subsections', '[]')) loop
      v_areas := coalesce(ss -> 'areas', '[]');
      v_days := '{}';
      for a in select * from jsonb_array_elements(v_areas) loop
        for d in select jsonb_object_keys(coalesce(a -> 'days', '{}')) loop v_days := v_days || jsonb_build_object(d, 'clean'); end loop;
      end loop;
      if coalesce(ss ->> 'brief_area_id', '') <> '' and v_days <> '{}'::jsonb then
        select ba into v_area from jsonb_array_elements(p_brief) bs, jsonb_array_elements(coalesce(bs -> 'areas', '[]')) ba
         where ba ->> 'id' = ss ->> 'brief_area_id' limit 1;
        if v_area is not null then
          for v_std in select * from jsonb_array_elements(coalesce(v_area -> 'standards', '[]')) loop
            continue when coalesce(trim(v_std ->> 'text'), '') = '';
            loop n := n + 1; v_id := 'std-' || n; exit when not (v_id = any (taken)); end loop;
            taken := taken || v_id;
            v_areas := v_areas || jsonb_build_array(jsonb_build_object('id', v_id, 'name', left(trim(v_std ->> 'text'), 200), 'days', v_days, 'standard', true));
          end loop;
        end if;
      end if;
      v_subs := v_subs || jsonb_build_array(ss || jsonb_build_object('areas', v_areas));
    end loop;
    v_secs := v_secs || jsonb_build_array(s || jsonb_build_object('subsections', v_subs));
  end loop;
  return p_plan || jsonb_build_object('sections', v_secs);
end;
$$;

-- The shape check ignores the placeholder method on a client standard: it adds no minutes, so it must not demand any.
create or replace function private.validate_work_schedule(p_plan jsonb, p_legend jsonb, p_complete boolean)
returns void language plpgsql immutable set search_path = ''
as $$
declare
  s jsonb; ss jsonb; a jsonb; k text; v text; ids text[] := '{}'; v_id text; n integer := 0; used text[] := '{}';
  methods constant text[] := array['scrub', 'wash', 'clean', 'mop'];
  weekdays constant text[] := array['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];
begin
  if jsonb_typeof(p_plan) <> 'object' or jsonb_typeof(p_plan -> 'sections') <> 'array' then raise exception 'The work schedule is not in the right shape'; end if;
  if octet_length(p_plan::text) > 400000 then raise exception 'The work schedule is too large'; end if;
  if jsonb_typeof(p_legend) <> 'object' then raise exception 'The method times are not in the right shape'; end if;
  for k in select jsonb_object_keys(p_legend) loop
    if k <> all (methods) then raise exception 'Unknown cleaning method %', k; end if;
    if p_legend -> k ->> 'minutes' is not null and ((p_legend -> k ->> 'minutes') !~ '^[0-9]+$' or (p_legend -> k ->> 'minutes')::integer > 600) then
      raise exception 'Minutes for % must be a whole number up to 600', k;
    end if;
  end loop;
  for s in select * from jsonb_array_elements(p_plan -> 'sections') loop
    if coalesce(length(trim(s ->> 'name')), 0) not between 1 and 120 then raise exception 'Every section needs a name'; end if;
    for ss in select * from jsonb_array_elements(coalesce(s -> 'subsections', '[]')) loop
      if coalesce(length(trim(ss ->> 'name')), 0) not between 1 and 120 then raise exception 'Every sub-section needs a name'; end if;
      for a in select * from jsonb_array_elements(coalesce(ss -> 'areas', '[]')) loop
        v_id := a ->> 'id';
        if coalesce(length(v_id), 0) not between 1 and 60 then raise exception 'Every cleaning area needs an id'; end if;
        if v_id = any (ids) then raise exception 'Cleaning area ids must be unique'; end if;
        ids := ids || v_id; n := n + 1;
        if coalesce(length(trim(a ->> 'name')), 0) not between 1 and 200 then raise exception 'Every cleaning area needs a name'; end if;
        if jsonb_typeof(coalesce(a -> 'days', '{}')) <> 'object' then raise exception 'Days are not in the right shape'; end if;
        for k in select jsonb_object_keys(coalesce(a -> 'days', '{}')) loop
          if k <> all (weekdays) then raise exception 'Unknown weekday %', k; end if;
          v := a -> 'days' ->> k;
          if v <> all (methods) then raise exception 'Unknown cleaning method %', v; end if;
          if coalesce((a ->> 'standard')::boolean, false) is not true then used := used || v; end if;
        end loop;
      end loop;
    end loop;
  end loop;
  if p_complete then
    if n = 0 then raise exception 'Add at least one cleaning area before sending the schedule'; end if;
    if array_length(used, 1) is null then raise exception 'Set a method on at least one day'; end if;
    foreach v in array (select array_agg(distinct u) from unnest(used) u) loop
      if coalesce((p_legend -> v ->> 'minutes')::integer, 0) <= 0 then raise exception 'Set the minutes for % before sending the schedule', v; end if;
    end loop;
  end if;
end;
$$;

-- Duly's own insert, while accepting a quote, writes the derived schedule already locked; nobody else can insert one that is not a draft.
create or replace function private.work_schedule_guard()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare q public.quotes;
begin
  if tg_op = 'INSERT' then
    if current_setting('duly.locking', true) is not distinct from 'on' then
      new.status := 'locked'; new.locked_at := coalesce(new.locked_at, now()); new.submitted_at := coalesce(new.submitted_at, now());
    else
      select * into q from public.quotes where id = new.quote_id;
      if not found then raise exception 'Quote not found'; end if;
      if not private.is_vendor_staff(q.vendor_org_id) and not private.is_platform_admin() then raise exception 'Only the vendor can build the work schedule'; end if;
      if q.status not in ('invited', 'submitted') then raise exception 'A work schedule can only be built while the quote is open'; end if;
      new.brief_id := q.brief_id; new.vendor_org_id := q.vendor_org_id;
      new.status := 'draft'; new.submitted_at := null; new.locked_at := null;
    end if;
  else
    if old.status = 'locked' and (current_setting('duly.locking', true) is distinct from 'on') then
      raise exception 'This work schedule is locked: the client accepted it';
    end if;
    if new.quote_id <> old.quote_id or new.brief_id <> old.brief_id or new.vendor_org_id <> old.vendor_org_id then raise exception 'A work schedule cannot be moved'; end if;
    if new.status = 'locked' and old.status <> 'locked' and (current_setting('duly.locking', true) is distinct from 'on') then
      raise exception 'A work schedule is locked when the client accepts the quote';
    end if;
    if old.status <> 'locked' and (current_setting('duly.locking', true) is distinct from 'on') then
      select * into q from public.quotes where id = new.quote_id;
      if q.status not in ('invited', 'submitted') then raise exception 'The quote is no longer open, so the schedule cannot change'; end if;
    end if;
    if new.status = 'submitted' and old.status <> 'submitted' then new.submitted_at := now(); end if;
    if new.status = 'draft' then new.submitted_at := null; end if;
  end if;
  perform private.validate_work_schedule(new.plan, new.legend, new.status in ('submitted', 'locked'));
  new.updated_at := now();
  return new;
end;
$$;

-- Accepting a quote locks the schedule that was sent (with the client's standards written in), or builds one from the brief.
create or replace function private.lock_work_schedule_on_accept()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare v_brief jsonb; v_derived jsonb;
begin
  if new.status = 'accepted' and old.status is distinct from 'accepted' then
    perform set_config('duly.locking', 'on', true);
    select bv.schedule into v_brief from public.brief_versions bv where bv.brief_id = new.brief_id and bv.version = new.brief_version;
    if exists (select 1 from public.work_schedules where quote_id = new.id and status = 'submitted') then
      update public.work_schedules set status = 'locked', locked_at = now(), plan = private.plan_with_standards(plan, v_brief)
       where quote_id = new.id and status = 'submitted';
    else
      -- Nothing was sent (or only a draft the vendor never sent): build one from the brief.
      delete from public.work_schedules where quote_id = new.id and status = 'draft';
      v_derived := private.derive_work_schedule(new.brief_id, new.brief_version);
      if v_derived is not null then
        insert into public.work_schedules (quote_id, brief_id, vendor_org_id, status, legend, plan, submitted_at, locked_at)
        values (new.id, new.brief_id, new.vendor_org_id, 'locked', v_derived -> 'legend', v_derived -> 'plan', now(), now());
      end if;
    end if;
    perform set_config('duly.locking', 'off', true);
  end if;
  return null;
end;
$$;

-- Planned minutes are the vendor's work: a client standard adds none.
create or replace function private.job_planned_minutes(p_job uuid)
returns integer language sql stable security definer set search_path = ''
as $$
  select case
    when private.job_uses_plan(p_job) then coalesce((
      select sum(coalesce(((ws.legend -> (a -> 'days' ->> private.job_weekday(p_job))) ->> 'minutes')::integer, 0))
        from public.jobs j
        join public.work_schedules ws on ws.quote_id = j.quote_id and ws.status = 'locked',
             jsonb_array_elements(ws.plan -> 'sections') s,
             jsonb_array_elements(coalesce(s -> 'subsections', '[]')) ss,
             jsonb_array_elements(coalesce(ss -> 'areas', '[]')) a
       where j.id = p_job and jsonb_exists(coalesce(a -> 'days', '{}'), private.job_weekday(p_job))
         and coalesce((a ->> 'standard')::boolean, false) is not true
         and (private.rework_item(p_job) is null or a ->> 'id' = private.rework_item(p_job))), 0)::integer
    else (select round(private.schedule_minutes(j.brief_id, j.brief_version))::integer from public.jobs j where j.id = p_job)
  end;
$$;

create or replace function public.visit_area_times(p_job uuid)
returns table (sequence_no integer, item_id text, item_name text, group_name text, method text, planned_minutes integer, done_at timestamptz, minutes_since_previous numeric)
language plpgsql stable security definer set search_path = ''
as $$
declare j public.jobs; v_ci timestamptz; v_day text; v_legend jsonb;
begin
  select * into j from public.jobs where id = p_job;
  if not found or not (private.is_platform_admin() or private.is_vendor_staff(j.vendor_org_id) or private.is_member(j.buyer_org_id)) then
    raise exception 'Job not found';
  end if;
  if not private.job_uses_plan(p_job) then return; end if;
  v_day := private.job_weekday(p_job);
  select min(e.at) into v_ci from public.job_events e where e.job_id = p_job and e.kind = 'check_in';
  select ws.legend into v_legend from public.work_schedules ws where ws.quote_id = j.quote_id and ws.status = 'locked';
  return query
    with rows as (
      select r.item_id, r.item_name, r.group_name,
             (select a -> 'days' ->> v_day
                from jsonb_array_elements(private.job_workplan(p_job) -> 'sections') s,
                     jsonb_array_elements(coalesce(s -> 'subsections', '[]')) ss,
                     jsonb_array_elements(coalesce(ss -> 'areas', '[]')) a
               where a ->> 'id' = r.item_id) as method,
             (select coalesce((a ->> 'standard')::boolean, false)
                from jsonb_array_elements(private.job_workplan(p_job) -> 'sections') s,
                     jsonb_array_elements(coalesce(s -> 'subsections', '[]')) ss,
                     jsonb_array_elements(coalesce(ss -> 'areas', '[]')) a
               where a ->> 'id' = r.item_id) as is_standard,
             pr.done_at
        from private.job_planned_rows(p_job) r
        left join public.plan_results pr on pr.job_id = p_job and pr.plan_item_id = r.item_id and pr.done)
    select (row_number() over (order by rows.done_at nulls last, rows.item_id))::integer, rows.item_id, rows.item_name, rows.group_name,
           case when rows.is_standard then 'standard' else rows.method end,
           case when rows.is_standard then 0 else coalesce((v_legend -> rows.method ->> 'minutes')::integer, 0) end, rows.done_at,
           case when rows.done_at is null then null
                else round((extract(epoch from (rows.done_at - coalesce(lag(rows.done_at) over (order by rows.done_at nulls last, rows.item_id), v_ci))) / 60)::numeric, 1) end
      from rows
     order by 1;
end;
$$;

-- On a day the schedule plans nothing there are no areas to count.
create or replace function private.visit_metrics(p_job uuid)
returns table (
  job_id uuid, vendor_org_id uuid, buyer_org_id uuid, site_id uuid, scheduled_start timestamptz, status text,
  uses_plan boolean, checked_in_at timestamptz, completed_at timestamptz,
  late_minutes integer, tolerance_minutes integer, on_time boolean,
  planned_minutes integer, on_site_minutes integer,
  planned_areas integer, ticked_areas integer,
  complaints integer, first_time_right boolean,
  photos integer, photos_on_site integer,
  accepted_at timestamptz, hours_to_accept numeric)
language sql stable security definer set search_path = ''
as $$
  with j as (select * from public.jobs where id = p_job),
  ev as (
    select (select min(e.at) from public.job_events e where e.job_id = p_job and e.kind = 'check_in') as ci,
           (select max(e.at) from public.job_events e where e.job_id = p_job and e.kind = 'check_out') as co,
           (select min(e.at) from public.job_events e where e.job_id = p_job and e.kind = 'status_change' and e.data ->> 'to' = 'quality_verified') as acc),
  tol as (
    select coalesce(bv.lateness_tolerance_min, (private.policy_for_org(j.buyer_org_id)).lateness_tolerance_min, 15)::integer as t
      from j left join public.brief_versions bv on bv.brief_id = j.brief_id and bv.version = j.brief_version),
  plan as (select private.job_uses_plan(p_job) as on_plan, private.job_has_schedule(p_job) as has_sched),
  areas as (
    select case when (select on_plan from plan) then (select count(*) from private.job_planned_rows(p_job))
                when (select has_sched from plan) then 0
                else (select count(*) from public.brief_versions bv, jsonb_array_elements(bv.schedule) sec, jsonb_array_elements(sec -> 'areas') a,
                             jsonb_array_elements(coalesce(a -> 'standards', '[]')) st
                       where (bv.brief_id, bv.version) = (select j.brief_id, j.brief_version from j)) end as planned,
           case when (select on_plan from plan) then (select count(*) from private.job_planned_rows(p_job) r
                                                        where exists (select 1 from public.plan_results pr where pr.job_id = p_job and pr.plan_item_id = r.item_id and pr.done))
                when (select has_sched from plan) then 0
                else (select count(*) from public.area_results ar where ar.job_id = p_job and ar.done_by_operative) end as ticked),
  iss as (select count(*) as n from public.issues i where i.job_id = p_job and i.kind <> 'safeguarding'),
  ph as (select count(*) as n, count(*) filter (where e.within_geofence) as on_site from public.evidence e where e.job_id = p_job)
  select j.id, j.vendor_org_id, j.buyer_org_id, j.site_id, j.scheduled_start, j.status::text,
         (select on_plan from plan), ev.ci, ev.co,
         greatest(0, floor(extract(epoch from (ev.ci - j.scheduled_start)) / 60))::integer, tol.t,
         floor(extract(epoch from (ev.ci - j.scheduled_start)) / 60) <= tol.t,
         private.job_planned_minutes(p_job),
         case when ev.co is null then null else round(extract(epoch from (ev.co - ev.ci)) / 60)::integer end,
         areas.planned::integer, areas.ticked::integer,
         iss.n::integer,
         iss.n = 0 and not exists (select 1 from public.plan_results pr where pr.job_id = p_job and pr.verdict = 'not_met')
                   and not exists (select 1 from public.area_results ar where ar.job_id = p_job and ar.verdict = 'not_met'),
         ph.n::integer, ph.on_site::integer,
         ev.acc, case when ev.acc is null or ev.co is null then null else round((extract(epoch from (ev.acc - ev.co)) / 3600)::numeric, 1) end
    from j, ev, tol, areas, iss, ph
   where ev.ci is not null;
$$;

-- Finishing a job. A schedule that plans nothing today needs only an after photo; with no schedule at all the old standards check applies.
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
  elsif private.job_has_schedule(p_job) then
    if not exists (select 1 from public.evidence e where e.job_id = p_job and e.kind = 'photo_after') then
      raise exception 'Take at least one after photo of the work';
    end if;
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

-- Approving a job. On a day the schedule plans nothing the client approves the visit as a whole.
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
  if v_job.rework_of_issue is not null then raise exception 'A rework visit is accepted or rejected, not approved for payment'; end if;
  if private.job_uses_plan(p_job) then
    if exists (select 1 from private.job_planned_rows(p_job) r
                where not exists (select 1 from public.plan_results pr where pr.job_id = p_job and pr.plan_item_id = r.item_id and pr.verdict is not null)) then
      raise exception 'Check every cleaning area first: accept it or report a problem';
    end if;
    if exists (select 1 from public.plan_results where job_id = p_job and verdict = 'not_met') then
      raise exception 'Some cleaning areas were not right: report a problem so the vendor can put it right';
    end if;
  elsif private.job_has_schedule(p_job) then
    null;   -- nothing was planned for this day: the client approves the visit as a whole, or has reported a problem
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

revoke execute on function private.job_has_schedule(uuid), private.derive_work_schedule(uuid, integer), private.plan_with_standards(jsonb, jsonb) from public, anon, authenticated;
revoke execute on function public.job_check_mode(uuid) from public, anon;
grant execute on function public.job_check_mode(uuid) to authenticated;
