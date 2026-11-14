-- Operational measures: how each visit went against its plan, and how a vendor is doing across visits.
--
-- Everything here is computed in SQL from what the crew and the client already record (check-in and check-out, the planned and
-- ticked areas, the photos, the client's verdicts and complaints). Nothing is typed in and nothing is estimated by a model.
-- These are read-only functions that check access themselves: the vendor's staff, the client's members and Duly can see a
-- visit's measures; a vendor's staff and Duly can see that vendor's summary; only Duly sees the comparison across vendors.
-- Safeguarding reports are never counted: only the person who raised one and Duly may see those.

-- Minutes planned for a visit: the vendor's minutes for each planned cleaning area when a work schedule decides the check,
-- otherwise the brief's minutes for the visit.
create function private.job_planned_minutes(p_job uuid)
returns integer language sql stable security definer set search_path = ''
as $$
  select case
    when private.job_uses_plan(p_job) then coalesce((
      select sum(coalesce((ws.legend -> (a -> 'days' ->> private.job_weekday(p_job)) ->> 'minutes')::integer, 0))
        from public.jobs j
        join public.work_schedules ws on ws.quote_id = j.quote_id and ws.status = 'locked',
             jsonb_array_elements(ws.plan -> 'sections') s,
             jsonb_array_elements(coalesce(s -> 'subsections', '[]')) ss,
             jsonb_array_elements(coalesce(ss -> 'areas', '[]')) a
       where j.id = p_job and jsonb_exists(coalesce(a -> 'days', '{}'), private.job_weekday(p_job))), 0)::integer
    else (select round(private.schedule_minutes(j.brief_id, j.brief_version))::integer from public.jobs j where j.id = p_job)
  end;
$$;

-- One row for one visit. A visit that was never checked in has no measures, so it returns no row.
create function private.visit_metrics(p_job uuid)
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
  plan as (select private.job_uses_plan(p_job) as on_plan),
  areas as (
    select case when (select on_plan from plan) then (select count(*) from private.job_planned_rows(p_job))
                else (select count(*) from public.brief_versions bv, jsonb_array_elements(bv.schedule) sec, jsonb_array_elements(sec -> 'areas') a,
                             jsonb_array_elements(coalesce(a -> 'standards', '[]')) st
                       where (bv.brief_id, bv.version) = (select j.brief_id, j.brief_version from j)) end as planned,
           case when (select on_plan from plan) then (select count(*) from private.job_planned_rows(p_job) r
                                                        where exists (select 1 from public.plan_results pr where pr.job_id = p_job and pr.plan_item_id = r.item_id and pr.done))
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

-- Who may see a visit's measures: Duly, the vendor's staff, or the client's members (not crew, and not strangers).
create function public.visit_measures(p_job uuid)
returns table (
  job_id uuid, vendor_org_id uuid, scheduled_start timestamptz, status text, uses_plan boolean,
  checked_in_at timestamptz, completed_at timestamptz, late_minutes integer, tolerance_minutes integer, on_time boolean,
  planned_minutes integer, on_site_minutes integer, planned_areas integer, ticked_areas integer,
  complaints integer, first_time_right boolean, photos integer, photos_on_site integer, accepted_at timestamptz, hours_to_accept numeric)
language plpgsql stable security definer set search_path = ''
as $$
declare j public.jobs;
begin
  select * into j from public.jobs where id = p_job;
  if not found or not (private.is_platform_admin() or private.is_vendor_staff(j.vendor_org_id) or private.is_member(j.buyer_org_id)) then
    raise exception 'Job not found';
  end if;
  return query
    select m.job_id, m.vendor_org_id, m.scheduled_start, m.status, m.uses_plan, m.checked_in_at, m.completed_at, m.late_minutes, m.tolerance_minutes,
           m.on_time, m.planned_minutes, m.on_site_minutes, m.planned_areas, m.ticked_areas, m.complaints, m.first_time_right, m.photos,
           m.photos_on_site, m.accepted_at, m.hours_to_accept
      from private.visit_metrics(p_job) m;
end;
$$;

-- Time between ticks for a visit that was checked against the work schedule: from check-in to the first tick, then from one
-- tick to the next. It is the time between ticks, not a stopwatch, so it is only as exact as the crew's habit of ticking as they go.
create function public.visit_area_times(p_job uuid)
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
             pr.done_at
        from private.job_planned_rows(p_job) r
        left join public.plan_results pr on pr.job_id = p_job and pr.plan_item_id = r.item_id and pr.done)
    select (row_number() over (order by rows.done_at nulls last, rows.item_id))::integer, rows.item_id, rows.item_name, rows.group_name, rows.method,
           coalesce((v_legend -> rows.method ->> 'minutes')::integer, 0), rows.done_at,
           case when rows.done_at is null then null
                else round((extract(epoch from (rows.done_at - coalesce(lag(rows.done_at) over (order by rows.done_at nulls last, rows.item_id), v_ci))) / 60)::numeric, 1) end
      from rows
     order by 1;
end;
$$;

-- Summary of a vendor's visits that were checked in, scheduled within a date range.
create function private.vendor_ops(p_vendor uuid, p_from date, p_to date)
returns table (
  visits integer, on_time_rate numeric, avg_late_minutes numeric, avg_planned_minutes numeric, avg_on_site_minutes numeric,
  time_vs_plan numeric, plan_followed_rate numeric, first_time_right_rate numeric, complaints_per_100 numeric,
  photos_on_site_rate numeric, open_issues integer, sla_breaches integer, avg_hours_to_resolve numeric)
language sql stable security definer set search_path = ''
as $$
  with m as (
    select x.* from public.jobs j, lateral private.visit_metrics(j.id) x
     where j.vendor_org_id = p_vendor and j.scheduled_start::date between p_from and p_to),
  i as (
    select count(*) filter (where i.status <> 'resolved') as open_n,
           count(*) filter (where (i.resolved_at is not null and i.sla_due_at is not null and i.resolved_at > i.sla_due_at)
                              or (i.resolved_at is null and i.status <> 'resolved' and i.sla_due_at is not null and i.sla_due_at < now())) as breached,
           avg(extract(epoch from (i.resolved_at - i.created_at)) / 3600) filter (where i.resolved_at is not null) as hrs
      from public.issues i join public.jobs j on j.id = i.job_id
     where j.vendor_org_id = p_vendor and j.scheduled_start::date between p_from and p_to and i.kind <> 'safeguarding')
  select count(*)::integer,
         round(avg(case when m.on_time then 1 else 0 end), 3),
         round(avg(m.late_minutes), 1),
         round(avg(m.planned_minutes), 1),
         round(avg(m.on_site_minutes), 1),
         round(sum(m.on_site_minutes) filter (where m.on_site_minutes is not null and m.planned_minutes > 0)::numeric
               / nullif(sum(m.planned_minutes) filter (where m.on_site_minutes is not null and m.planned_minutes > 0), 0), 2),
         round(sum(m.ticked_areas)::numeric / nullif(sum(m.planned_areas), 0), 3),
         round(avg(case when m.first_time_right then 1 else 0 end), 3),
         round(sum(m.complaints)::numeric * 100 / nullif(count(*), 0), 1),
         round(sum(m.photos_on_site)::numeric / nullif(sum(m.photos), 0), 3),
         (select open_n from i)::integer, (select breached from i)::integer, round((select hrs from i)::numeric, 1)
    from m;
$$;

create function public.vendor_operations(p_vendor uuid, p_from date, p_to date)
returns table (
  visits integer, on_time_rate numeric, avg_late_minutes numeric, avg_planned_minutes numeric, avg_on_site_minutes numeric,
  time_vs_plan numeric, plan_followed_rate numeric, first_time_right_rate numeric, complaints_per_100 numeric,
  photos_on_site_rate numeric, open_issues integer, sla_breaches integer, avg_hours_to_resolve numeric)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (private.is_platform_admin() or private.is_vendor_staff(p_vendor)) then raise exception 'Not allowed to see these measures'; end if;
  return query select * from private.vendor_ops(p_vendor, p_from, p_to);
end;
$$;

-- Where complaints land: the cleaning areas clients reported on most, for one vendor.
create function public.vendor_problem_areas(p_vendor uuid, p_from date, p_to date)
returns table (area text, complaints integer, last_reported timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (private.is_platform_admin() or private.is_vendor_staff(p_vendor)) then raise exception 'Not allowed to see these measures'; end if;
  return query
    select i.plan_label, count(*)::integer, max(i.created_at)
      from public.issues i join public.jobs j on j.id = i.job_id
     where j.vendor_org_id = p_vendor and j.scheduled_start::date between p_from and p_to
       and i.kind <> 'safeguarding' and i.plan_label is not null
     group by i.plan_label order by count(*) desc, max(i.created_at) desc limit 20;
end;
$$;

-- A vendor's recent visits, one line each, with the measures that matter (most recent first).
create function public.vendor_visits(p_vendor uuid, p_from date, p_to date)
returns table (
  job_id uuid, scheduled_start timestamptz, site_name text, status text, late_minutes integer, on_time boolean,
  planned_minutes integer, on_site_minutes integer, planned_areas integer, ticked_areas integer, complaints integer, first_time_right boolean)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (private.is_platform_admin() or private.is_vendor_staff(p_vendor)) then raise exception 'Not allowed to see these measures'; end if;
  return query
    select m.job_id, m.scheduled_start, s.name, m.status, m.late_minutes, m.on_time, m.planned_minutes, m.on_site_minutes,
           m.planned_areas, m.ticked_areas, m.complaints, m.first_time_right
      from public.jobs j
      cross join lateral private.visit_metrics(j.id) m
      join public.sites s on s.id = m.site_id
     where j.vendor_org_id = p_vendor and j.scheduled_start::date between p_from and p_to
     order by m.scheduled_start desc limit 200;
end;
$$;

-- Duly only: every vendor with checked-in visits in the range, side by side.
create function public.platform_operations(p_from date, p_to date)
returns table (
  vendor_org_id uuid, vendor_name text, visits integer, on_time_rate numeric, avg_late_minutes numeric, time_vs_plan numeric,
  plan_followed_rate numeric, first_time_right_rate numeric, complaints_per_100 numeric, photos_on_site_rate numeric,
  open_issues integer, sla_breaches integer)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.is_platform_admin() then raise exception 'Only Duly can see the comparison across vendors'; end if;
  return query
    select o.id, o.name, m.visits, m.on_time_rate, m.avg_late_minutes, m.time_vs_plan, m.plan_followed_rate, m.first_time_right_rate,
           m.complaints_per_100, m.photos_on_site_rate, m.open_issues, m.sla_breaches
      from public.organisations o, lateral private.vendor_ops(o.id, p_from, p_to) m
     where o.kind = 'vendor' and m.visits > 0
     order by m.first_time_right_rate asc nulls last, m.visits desc;
end;
$$;

revoke execute on function private.job_planned_minutes(uuid), private.visit_metrics(uuid), private.vendor_ops(uuid, date, date) from public, anon, authenticated;
revoke execute on function public.visit_measures(uuid), public.visit_area_times(uuid), public.vendor_operations(uuid, date, date),
  public.vendor_problem_areas(uuid, date, date), public.vendor_visits(uuid, date, date), public.platform_operations(date, date) from public, anon;
grant execute on function public.visit_measures(uuid), public.visit_area_times(uuid), public.vendor_operations(uuid, date, date),
  public.vendor_problem_areas(uuid, date, date), public.vendor_visits(uuid, date, date), public.platform_operations(date, date) to authenticated;
