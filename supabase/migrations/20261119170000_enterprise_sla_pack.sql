-- The monthly SLA pack: for one calendar month, how each vendor delivered at the Enterprise's sites, per vendor and per site, with the
-- visits behind the numbers, against the service levels the Enterprise has set.
--
-- Everything is worked out here, in SQL, from what the crew and the client already record (the same measures and lateness rules as the
-- delivery view). The app shows the rows and exports them; it computes nothing. Nothing in it is personal: no crew names, no pay, no price,
-- and safeguarding reports are never counted. Members of the Enterprise and Duly only.
--
-- Service levels are the Enterprise's own and are optional: with none set the pack still shows every rate, and the "met" columns are empty.
--   enterprise_sla_targets   the lowest on-time rate, the lowest evidenced rate and the most complaints per 100 visits the Enterprise accepts
-- Which visits count: those scheduled in the month (in the Enterprise's market timezone), not cancelled, not rework visits. A visit that
-- has not yet come due counts as scheduled only, so a month in progress is a partial pack. A "missed" visit is one that was never checked
-- in and whose planned end has passed; "late" is a visit that arrived after the tolerance (or has not arrived and is past it, before its end).

create table public.enterprise_sla_targets (
  id uuid not null default gen_random_uuid() unique,
  enterprise_org_id uuid primary key references public.organisations(id) on delete cascade,
  on_time_rate numeric(4,3) check (on_time_rate between 0 and 1),
  evidenced_rate numeric(4,3) check (evidenced_rate between 0 and 1),
  max_complaints_per_100 numeric(6,1) check (max_complaints_per_100 >= 0),
  updated_by uuid default auth.uid() references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);
create index enterprise_sla_targets_updated_by_idx on public.enterprise_sla_targets (updated_by);
alter table public.enterprise_sla_targets enable row level security;
create policy "sla targets visible" on public.enterprise_sla_targets for select to authenticated
  using (private.is_platform_admin() or private.is_member(enterprise_org_id));
create trigger audit_enterprise_sla_targets after insert or update or delete on public.enterprise_sla_targets for each row execute function private.audit_row();

-- The Enterprise sets its service levels (owner or approver). A value left empty means no level for that measure.
create function public.enterprise_set_sla_targets(p_enterprise uuid, p_on_time numeric, p_evidenced numeric, p_max_complaints numeric)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not (private.has_org_role(p_enterprise, array['owner', 'approver']::public.member_role[]) or private.is_platform_admin()) then
    raise exception 'Only the Enterprise''s owner or approvers can set its service levels';
  end if;
  if not private.is_enterprise(p_enterprise) then raise exception 'That is not an Enterprise'; end if;
  if p_on_time is not null and p_on_time not between 0 and 1 then raise exception 'The on-time level is a share between 0 and 1'; end if;
  if p_evidenced is not null and p_evidenced not between 0 and 1 then raise exception 'The evidenced level is a share between 0 and 1'; end if;
  if p_max_complaints is not null and p_max_complaints < 0 then raise exception 'Complaints per 100 visits cannot be negative'; end if;
  insert into public.enterprise_sla_targets (enterprise_org_id, on_time_rate, evidenced_rate, max_complaints_per_100, updated_by, updated_at)
    values (p_enterprise, p_on_time, p_evidenced, p_max_complaints, (select auth.uid()), now())
    on conflict (enterprise_org_id) do update
      set on_time_rate = excluded.on_time_rate, evidenced_rate = excluded.evidenced_rate, max_complaints_per_100 = excluded.max_complaints_per_100,
          updated_by = excluded.updated_by, updated_at = excluded.updated_at;
end;
$$;

-- One row per vendor (is_vendor_total, site empty) and one per vendor and site, for the month containing p_month. A vendor's own row comes
-- first, then its sites by name.
create function public.enterprise_sla_pack(p_enterprise uuid, p_month date)
returns table (
  vendor_org_id uuid, vendor_name text, site_id uuid, site_name text, is_vendor_total boolean,
  scheduled_visits integer, due_visits integer, checked_in_visits integer, evidenced_visits integer, evidenced_rate numeric,
  on_time_visits integer, on_time_rate numeric, late_visits integer, missed_visits integer, avg_late_minutes numeric,
  plan_followed_rate numeric, first_time_right_rate numeric,
  complaints integer, complaints_per_100 numeric, open_complaints integer, sla_breaches integer,
  on_time_target numeric, evidenced_target numeric, max_complaints_per_100 numeric,
  on_time_met boolean, evidenced_met boolean, complaints_met boolean)
language plpgsql stable security definer set search_path = ''
as $$
declare m0 date := date_trunc('month', p_month)::date;
begin
  if not (private.is_platform_admin() or private.is_member(p_enterprise)) then raise exception 'Not allowed to see this Enterprise''s reports'; end if;
  if not private.is_enterprise(p_enterprise) then raise exception 'That is not an Enterprise'; end if;
  return query
  with tz as (
    select coalesce((select mk.timezone from public.organisations o join public.markets mk on mk.code = o.market where o.id = p_enterprise), 'UTC') as z),
  v as (
    select j.id as job_id, j.vendor_org_id, vo.name as vendor_name, j.site_id, s.name as site_name, j.status, j.scheduled_start, j.scheduled_end,
           (select min(e.at) from public.job_events e where e.job_id = j.id and e.kind = 'check_in') as ci,
           coalesce(bv.lateness_tolerance_min, (private.policy_for_org(j.buyer_org_id)).lateness_tolerance_min, 15) as tol
      from public.jobs j
      join tz on true
      join public.sites s on s.id = j.site_id
      join public.organisations vo on vo.id = j.vendor_org_id
      left join public.brief_versions bv on bv.brief_id = j.brief_id and bv.version = j.brief_version
     where j.buyer_org_id = p_enterprise and j.status <> 'cancelled' and j.rework_of_issue is null
       and (j.scheduled_start at time zone tz.z)::date >= m0 and (j.scheduled_start at time zone tz.z)::date < (m0 + interval '1 month')::date),
  m as (
    select v.*, x.on_time, x.late_minutes, x.planned_areas, x.ticked_areas, x.photos, x.first_time_right,
           (select count(*) from public.issues i where i.job_id = v.job_id and i.kind <> 'safeguarding') as complaints,
           (select count(*) from public.issues i where i.job_id = v.job_id and i.kind <> 'safeguarding' and i.status <> 'resolved') as open_complaints,
           (select count(*) from public.issues i where i.job_id = v.job_id and i.kind <> 'safeguarding'
              and ((i.resolved_at is not null and i.sla_due_at is not null and i.resolved_at > i.sla_due_at)
                or (i.resolved_at is null and i.status <> 'resolved' and i.sla_due_at is not null and i.sla_due_at < now()))) as breaches,
           v.status in ('matched', 'en_route', 'requested') as booked
      from v left join lateral private.visit_metrics(v.job_id) x on true),
  g as (
    select m.vendor_org_id, m.vendor_name, m.site_id, m.site_name, (grouping(m.site_id) = 1) as is_total,
           count(*) as scheduled,
           count(*) filter (where m.scheduled_start <= now()) as due,
           count(*) filter (where m.ci is not null) as checked_in,
           count(*) filter (where m.ci is not null and coalesce(m.photos, 0) > 0 and coalesce(m.ticked_areas, 0) >= coalesce(m.planned_areas, 0)) as evidenced,
           count(*) filter (where m.on_time) as on_time,
           count(*) filter (where (m.ci is not null and not m.on_time)
                               or (m.ci is null and m.booked and now() >= m.scheduled_start + make_interval(mins => m.tol) and now() < m.scheduled_end)) as late,
           count(*) filter (where m.ci is null and m.booked and now() >= m.scheduled_end) as missed,
           avg(m.late_minutes) filter (where m.ci is not null) as avg_late,
           sum(m.ticked_areas) as ticked, sum(m.planned_areas) as planned,
           avg(case when m.first_time_right then 1 else 0 end) filter (where m.ci is not null) as ftr,
           sum(m.complaints) as complaints, sum(m.open_complaints) as open_complaints, sum(m.breaches) as breaches
      from m
     group by grouping sets ((m.vendor_org_id, m.vendor_name, m.site_id, m.site_name), (m.vendor_org_id, m.vendor_name))),
  r as (
    select g.*,
           round(g.evidenced::numeric / nullif(g.due, 0), 3) as ev_rate,
           round(g.on_time::numeric / nullif(g.checked_in, 0), 3) as ot_rate,
           round(g.complaints::numeric * 100 / nullif(g.due, 0), 1) as c100
      from g)
  select r.vendor_org_id, r.vendor_name, r.site_id, r.site_name, r.is_total,
         r.scheduled::integer, r.due::integer, r.checked_in::integer, r.evidenced::integer, r.ev_rate,
         r.on_time::integer, r.ot_rate, r.late::integer, r.missed::integer, round(r.avg_late, 1),
         round(r.ticked::numeric / nullif(r.planned, 0), 3), round(r.ftr, 3),
         coalesce(r.complaints, 0)::integer, r.c100, coalesce(r.open_complaints, 0)::integer, coalesce(r.breaches, 0)::integer,
         t.on_time_rate, t.evidenced_rate, t.max_complaints_per_100,
         case when t.on_time_rate is null or r.ot_rate is null then null else r.ot_rate >= t.on_time_rate end,
         case when t.evidenced_rate is null or r.ev_rate is null then null else r.ev_rate >= t.evidenced_rate end,
         case when t.max_complaints_per_100 is null or r.c100 is null then null else r.c100 <= t.max_complaints_per_100 end
    from r
    left join public.enterprise_sla_targets t on t.enterprise_org_id = p_enterprise
   order by r.vendor_name, r.vendor_org_id, (not r.is_total), r.site_name nulls first, r.site_id;
end;
$$;

-- The visits behind the numbers: every visit in the month that was missed, late, or complained about, in vendor, site and date order.
create function public.enterprise_sla_exceptions(p_enterprise uuid, p_month date)
returns table (
  job_id uuid, vendor_org_id uuid, vendor_name text, site_id uuid, site_name text, scheduled_start timestamptz, status text,
  missed boolean, late_minutes integer, complaints integer, open_complaints integer, sla_breached boolean, complaint_kinds text)
language plpgsql stable security definer set search_path = ''
as $$
declare m0 date := date_trunc('month', p_month)::date;
begin
  if not (private.is_platform_admin() or private.is_member(p_enterprise)) then raise exception 'Not allowed to see this Enterprise''s reports'; end if;
  if not private.is_enterprise(p_enterprise) then raise exception 'That is not an Enterprise'; end if;
  return query
  with tz as (
    select coalesce((select mk.timezone from public.organisations o join public.markets mk on mk.code = o.market where o.id = p_enterprise), 'UTC') as z),
  v as (
    select j.id as jid, j.vendor_org_id as vid, vo.name as vname, j.site_id as sid, s.name as sname, j.status as st, j.scheduled_start as sstart, j.scheduled_end as send,
           (select min(e.at) from public.job_events e where e.job_id = j.id and e.kind = 'check_in') as ci,
           coalesce(bv.lateness_tolerance_min, (private.policy_for_org(j.buyer_org_id)).lateness_tolerance_min, 15) as tol
      from public.jobs j
      join tz on true
      join public.sites s on s.id = j.site_id
      join public.organisations vo on vo.id = j.vendor_org_id
      left join public.brief_versions bv on bv.brief_id = j.brief_id and bv.version = j.brief_version
     where j.buyer_org_id = p_enterprise and j.status <> 'cancelled' and j.rework_of_issue is null
       and (j.scheduled_start at time zone tz.z)::date >= m0 and (j.scheduled_start at time zone tz.z)::date < (m0 + interval '1 month')::date),
  f as (
    select v.*, (v.ci is null and v.st in ('matched', 'en_route', 'requested') and now() >= v.send) as is_missed,
           (select x.late_minutes from private.visit_metrics(v.jid) x where not x.on_time) as lm,
           (select count(*) from public.issues i where i.job_id = v.jid and i.kind <> 'safeguarding') as nc,
           (select count(*) from public.issues i where i.job_id = v.jid and i.kind <> 'safeguarding' and i.status <> 'resolved') as noc,
           (select count(*) from public.issues i where i.job_id = v.jid and i.kind <> 'safeguarding'
              and ((i.resolved_at is not null and i.sla_due_at is not null and i.resolved_at > i.sla_due_at)
                or (i.resolved_at is null and i.status <> 'resolved' and i.sla_due_at is not null and i.sla_due_at < now()))) as nb,
           (select string_agg(distinct i.kind::text, ', ' order by i.kind::text) from public.issues i where i.job_id = v.jid and i.kind <> 'safeguarding') as kinds
      from v)
  select f.jid, f.vid, f.vname, f.sid, f.sname, f.sstart, f.st::text, f.is_missed, f.lm, f.nc::integer, f.noc::integer, f.nb > 0, f.kinds
    from f
   where f.is_missed or f.lm is not null or f.nc > 0
   order by f.vname, f.vid, f.sname, f.sid, f.sstart, f.jid;
end;
$$;

revoke execute on function public.enterprise_set_sla_targets(uuid, numeric, numeric, numeric), public.enterprise_sla_pack(uuid, date),
  public.enterprise_sla_exceptions(uuid, date) from public, anon;
grant execute on function public.enterprise_set_sla_targets(uuid, numeric, numeric, numeric), public.enterprise_sla_pack(uuid, date),
  public.enterprise_sla_exceptions(uuid, date) to authenticated;
