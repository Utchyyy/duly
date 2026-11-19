-- The Enterprise's delivery view across all its vendors: what needs attention now, how each vendor is delivering, and the problems
-- that are open, with a way to hand one to Duly.
--
-- Everything is worked out here, in SQL, from what the crew and the client already record (the same rules as the vendor dispatch board
-- and the reminder scan: lateness tolerance from the brief, then the policy, then 15 minutes). The app shows rows in the order given
-- and never ranks or re-sorts them. No pay, no price and no crew names appear: the Enterprise sees which vendor, which site and what
-- happened. Members of the Enterprise and Duly only (client site managers use the Client view, not this).
--   missed          booked, nobody checked in, and the planned end has passed
--   late            booked, nobody checked in, past the tolerance but before the planned end
--   no_crew         nobody is assigned and the visit starts within 24 hours (or already should have)
--   overrunning     in progress past its planned end
--   held            a complaint holds the visit
--   awaiting_check  the cleaner has finished and the Enterprise (or the site manager) has not yet checked the work
-- Safeguarding reports are never counted or shown.

create function public.enterprise_delivery_board(p_enterprise uuid, p_from date, p_to date)
returns table (
  job_id uuid, vendor_org_id uuid, vendor_name text, site_id uuid, site_name text, town text,
  scheduled_start timestamptz, scheduled_end timestamptz, status text, is_rework boolean, rework_area text,
  checked_in_at timestamptz, late_minutes integer, crew_count integer, planned_minutes integer, on_site_minutes integer,
  planned_areas integer, ticked_areas integer, photos integer, open_issues integer, attention text)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (private.is_platform_admin() or private.is_member(p_enterprise)) then raise exception 'Not allowed to see this Enterprise''s visits'; end if;
  if not private.is_enterprise(p_enterprise) then raise exception 'That is not an Enterprise'; end if;
  return query
  with tz as (
    select coalesce((select m.timezone from public.organisations o join public.markets m on m.code = o.market where o.id = p_enterprise), 'UTC') as z),
  base as (
    select j.*, s.name as site_name, s.town as site_town, vo.name as vendor_name,
           (select min(e.at) from public.job_events e where e.job_id = j.id and e.kind = 'check_in') as ci,
           (select max(e.at) from public.job_events e where e.job_id = j.id and e.kind = 'check_out') as co,
           coalesce(bv.lateness_tolerance_min, (private.policy_for_org(j.buyer_org_id)).lateness_tolerance_min, 15) as tol,
           j.status in ('matched', 'en_route', 'requested') as booked,
           (select count(*) from public.job_assignments a where a.job_id = j.id) as crew_n,
           (select count(*) from public.issues i where i.job_id = j.id and i.status <> 'resolved' and i.kind <> 'safeguarding') as open_n
      from public.jobs j
      join public.sites s on s.id = j.site_id
      join public.organisations vo on vo.id = j.vendor_org_id
      left join public.brief_versions bv on bv.brief_id = j.brief_id and bv.version = j.brief_version
     where j.buyer_org_id = p_enterprise and j.status <> 'cancelled'),
  shown as (
    select b.* from base b, tz
     where (b.scheduled_start at time zone tz.z)::date between p_from and p_to
        or (b.scheduled_start at time zone tz.z)::date < p_from and b.status in ('matched', 'en_route', 'on_site', 'in_progress', 'requested', 'completed', 'disputed')),
  flagged as (
    select b.*,
           case
             when b.booked and b.ci is null and now() >= b.scheduled_end then 'missed'
             when b.booked and b.ci is null and now() >= b.scheduled_start + make_interval(mins => b.tol) then 'late'
             when b.crew_n = 0 and b.status in ('matched', 'requested') and b.scheduled_start <= now() + interval '24 hours' then 'no_crew'
             when b.status = 'in_progress' and now() > b.scheduled_end then 'overrunning'
             when b.status = 'disputed' then 'held'
             when b.status = 'completed' then 'awaiting_check'
           end as att
      from shown b)
  select f.id, f.vendor_org_id, f.vendor_name, f.site_id, f.site_name, f.site_town, f.scheduled_start, f.scheduled_end, f.status::text,
         f.rework_of_issue is not null, (select i.plan_label from public.issues i where i.id = f.rework_of_issue),
         f.ci,
         case when f.ci is null then case when f.booked and now() >= f.scheduled_start then floor(extract(epoch from (now() - f.scheduled_start)) / 60)::integer end
              else greatest(0, floor(extract(epoch from (f.ci - f.scheduled_start)) / 60))::integer end,
         f.crew_n::integer, private.job_planned_minutes(f.id),
         case when f.ci is null then null else floor(extract(epoch from (coalesce(f.co, now()) - f.ci)) / 60)::integer end,
         (select m.planned_areas from private.visit_metrics(f.id) m), (select m.ticked_areas from private.visit_metrics(f.id) m),
         (select count(*)::integer from public.evidence e where e.job_id = f.id),
         f.open_n::integer, f.att
    from flagged f
   order by (case f.att when 'missed' then 1 when 'late' then 2 when 'no_crew' then 3 when 'overrunning' then 4 when 'held' then 5 when 'awaiting_check' then 6 else 7 end),
            f.scheduled_start, f.id;
end;
$$;

-- Each roster vendor's delivery over a date range (visits scheduled in it; rework visits are left out). Counts and rates are worked out
-- here. "Due" is a visit whose start has passed; "evidenced" is due, checked in, with every planned area ticked and at least one photo.
create function public.enterprise_vendor_delivery(p_enterprise uuid, p_from date, p_to date)
returns table (
  vendor_org_id uuid, vendor_name text, roster_status text,
  due_visits integer, evidenced_visits integer, evidenced_rate numeric,
  checked_in_visits integer, on_time_visits integer, on_time_rate numeric,
  late_visits integer, missed_visits integer, upcoming_visits integer, awaiting_check integer,
  complaints integer, open_issues integer, sla_breaches integer, first_time_right_rate numeric)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (private.is_platform_admin() or private.is_member(p_enterprise)) then raise exception 'Not allowed to see this Enterprise''s vendors'; end if;
  if not private.is_enterprise(p_enterprise) then raise exception 'That is not an Enterprise'; end if;
  return query
  with tz as (
    select coalesce((select m.timezone from public.organisations o join public.markets m on m.code = o.market where o.id = p_enterprise), 'UTC') as z),
  v as (
    select j.id as job_id, j.vendor_org_id, j.status, j.scheduled_start, j.scheduled_end,
           (select min(e.at) from public.job_events e where e.job_id = j.id and e.kind = 'check_in') as ci,
           coalesce(bv.lateness_tolerance_min, (private.policy_for_org(j.buyer_org_id)).lateness_tolerance_min, 15) as tol
      from public.jobs j
      join tz on true
      left join public.brief_versions bv on bv.brief_id = j.brief_id and bv.version = j.brief_version
     where j.buyer_org_id = p_enterprise and j.status <> 'cancelled' and j.rework_of_issue is null
       and (j.scheduled_start at time zone tz.z)::date between p_from and p_to),
  m as (
    select v.*, x.on_time, x.late_minutes, x.planned_areas, x.ticked_areas, x.photos, x.first_time_right
      from v left join lateral private.visit_metrics(v.job_id) x on true),
  iss as (
    select v.vendor_org_id,
           count(*) filter (where i.kind <> 'safeguarding') as n,
           count(*) filter (where i.kind <> 'safeguarding' and i.status <> 'resolved') as open_n,
           count(*) filter (where i.kind <> 'safeguarding' and ((i.resolved_at is not null and i.sla_due_at is not null and i.resolved_at > i.sla_due_at)
                              or (i.resolved_at is null and i.status <> 'resolved' and i.sla_due_at is not null and i.sla_due_at < now()))) as breached
      from v join public.issues i on i.job_id = v.job_id group by v.vendor_org_id)
  select ev.vendor_org_id, o.name, ev.status,
         (count(m.job_id) filter (where m.scheduled_start <= now()))::integer,
         (count(m.job_id) filter (where m.ci is not null and coalesce(m.photos, 0) > 0 and coalesce(m.ticked_areas, 0) >= coalesce(m.planned_areas, 0)))::integer,
         round((count(m.job_id) filter (where m.ci is not null and coalesce(m.photos, 0) > 0 and coalesce(m.ticked_areas, 0) >= coalesce(m.planned_areas, 0)))::numeric
               / nullif(count(m.job_id) filter (where m.scheduled_start <= now()), 0), 3),
         (count(m.job_id) filter (where m.ci is not null))::integer,
         (count(m.job_id) filter (where m.on_time))::integer,
         round((count(m.job_id) filter (where m.on_time))::numeric / nullif(count(m.job_id) filter (where m.ci is not null), 0), 3),
         (count(m.job_id) filter (where (m.ci is not null and not m.on_time)
                                     or (m.ci is null and m.status in ('matched', 'en_route', 'requested') and now() >= m.scheduled_start + make_interval(mins => m.tol) and now() < m.scheduled_end)))::integer,
         (count(m.job_id) filter (where m.ci is null and m.status in ('matched', 'en_route', 'requested') and now() >= m.scheduled_end))::integer,
         (count(m.job_id) filter (where m.scheduled_start > now()))::integer,
         (count(m.job_id) filter (where m.status = 'completed'))::integer,
         coalesce((select n from iss where iss.vendor_org_id = ev.vendor_org_id), 0)::integer,
         coalesce((select open_n from iss where iss.vendor_org_id = ev.vendor_org_id), 0)::integer,
         coalesce((select breached from iss where iss.vendor_org_id = ev.vendor_org_id), 0)::integer,
         round(avg(case when m.first_time_right then 1 else 0 end) filter (where m.ci is not null), 3)
    from public.enterprise_vendors ev
    join public.organisations o on o.id = ev.vendor_org_id
    left join m on m.vendor_org_id = ev.vendor_org_id
   where ev.enterprise_org_id = p_enterprise
   group by ev.vendor_org_id, o.name, ev.status
   order by o.name;
end;
$$;

-- Open problems across the Enterprise's vendors, most urgent first: past their response time, then the nearest deadline, then the oldest.
create function public.enterprise_open_issues(p_enterprise uuid)
returns table (
  issue_id uuid, job_id uuid, vendor_org_id uuid, vendor_name text, site_name text, scheduled_start timestamptz,
  kind text, status text, plan_label text, description text, created_at timestamptz, sla_due_at timestamptz, breached boolean, hours_open integer)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (private.is_platform_admin() or private.is_member(p_enterprise)) then raise exception 'Not allowed to see this Enterprise''s problems'; end if;
  if not private.is_enterprise(p_enterprise) then raise exception 'That is not an Enterprise'; end if;
  return query
  select i.id, j.id, j.vendor_org_id, vo.name, s.name, j.scheduled_start, i.kind::text, i.status::text, i.plan_label, i.description, i.created_at, i.sla_due_at,
         i.sla_due_at is not null and i.sla_due_at < now(), floor(extract(epoch from (now() - i.created_at)) / 3600)::integer
    from public.issues i
    join public.jobs j on j.id = i.job_id
    join public.sites s on s.id = j.site_id
    join public.organisations vo on vo.id = j.vendor_org_id
   where j.buyer_org_id = p_enterprise and i.status <> 'resolved' and i.kind <> 'safeguarding'
   order by (i.sla_due_at is not null and i.sla_due_at < now()) desc, i.sla_due_at nulls last, i.created_at, i.id;
end;
$$;

-- The Enterprise hands an open problem to Duly (mediation). Owner or approver only; not a resolved problem and never a safeguarding report.
create function public.enterprise_escalate_issue(p_issue uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare i public.issues; j public.jobs;
begin
  select * into i from public.issues where id = p_issue;
  if not found or i.job_id is null then raise exception 'Problem not found'; end if;
  select * into j from public.jobs where id = i.job_id;
  if not (private.has_org_role(j.buyer_org_id, array['owner', 'approver']::public.member_role[]) or private.is_platform_admin()) then
    raise exception 'Only the Enterprise''s owner or approvers can hand a problem to Duly';
  end if;
  if not private.is_enterprise(j.buyer_org_id) then raise exception 'That is not an Enterprise''s problem'; end if;
  if i.kind = 'safeguarding' then raise exception 'Safeguarding reports are handled by Duly already'; end if;
  if i.status = 'resolved' then raise exception 'That problem is already resolved'; end if;
  if i.status = 'mediation' then raise exception 'Duly is already looking at this'; end if;
  update public.issues set status = 'mediation' where id = p_issue;
end;
$$;

revoke execute on function public.enterprise_delivery_board(uuid, date, date), public.enterprise_vendor_delivery(uuid, date, date),
  public.enterprise_open_issues(uuid), public.enterprise_escalate_issue(uuid) from public, anon;
grant execute on function public.enterprise_delivery_board(uuid, date, date), public.enterprise_vendor_delivery(uuid, date, date),
  public.enterprise_open_issues(uuid), public.enterprise_escalate_issue(uuid) to authenticated;
