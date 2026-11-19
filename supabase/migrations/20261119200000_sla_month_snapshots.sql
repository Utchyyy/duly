-- A closed month's SLA pack, frozen.
--
-- The live pack counts "due" and "missed" against the clock and reads complaints as they stand, so a month's figures can still shift after it
-- ends. This stores a snapshot of a month once it has closed, and the Reports page shows that snapshot for a closed month, so the figures an
-- Enterprise took to a review are the figures it can show again later.
--   * A month freezes by itself once it has been closed for the complaint window (policies.balance_release_hours, 48 hours by default): a
--     daily scan (private.freeze_sla_months) takes the snapshot, for every month that had visits and no snapshot yet.
--   * The Enterprise's owner or approver can freeze a closed month sooner (enterprise_freeze_sla_month). A month still in progress cannot
--     be frozen, and a month with no visits has nothing to freeze.
--   * A snapshot keeps the pack rows and the visits behind them exactly as they were, including the service levels in force at the time. It
--     can never be changed or removed (a trigger refuses), so the live figures are the only thing that moves afterwards.
-- The pack's own queries move into private functions so the scan can run them without a person signed in; the public functions are the same
-- as before (they check access, then call these).

create function private.sla_pack_rows(p_enterprise uuid, p_month date)
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


create function private.sla_exception_rows(p_enterprise uuid, p_month date)
returns table (
  job_id uuid, vendor_org_id uuid, vendor_name text, site_id uuid, site_name text, scheduled_start timestamptz, status text,
  missed boolean, late_minutes integer, complaints integer, open_complaints integer, sla_breached boolean, complaint_kinds text)
language plpgsql stable security definer set search_path = ''
as $$
declare m0 date := date_trunc('month', p_month)::date;
begin
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


-- The public functions: the same results as before, access checked first.
create or replace function public.enterprise_sla_pack(p_enterprise uuid, p_month date)
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
begin
  if not (private.is_platform_admin() or private.is_member(p_enterprise)) then raise exception 'Not allowed to see this Enterprise''s reports'; end if;
  return query select * from private.sla_pack_rows(p_enterprise, p_month);
end;
$$;

create or replace function public.enterprise_sla_exceptions(p_enterprise uuid, p_month date)
returns table (
  job_id uuid, vendor_org_id uuid, vendor_name text, site_id uuid, site_name text, scheduled_start timestamptz, status text,
  missed boolean, late_minutes integer, complaints integer, open_complaints integer, sla_breached boolean, complaint_kinds text)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (private.is_platform_admin() or private.is_member(p_enterprise)) then raise exception 'Not allowed to see this Enterprise''s reports'; end if;
  return query select * from private.sla_exception_rows(p_enterprise, p_month);
end;
$$;

create table public.enterprise_sla_snapshots (
  id uuid not null default gen_random_uuid() unique,
  enterprise_org_id uuid not null references public.organisations(id) on delete cascade,
  month date not null check (month = date_trunc('month', month)::date),
  taken_at timestamptz not null default now(),
  taken_by uuid references auth.users(id) on delete set null,
  source text not null check (source in ('auto', 'manual')),
  pack jsonb not null,
  exceptions jsonb not null,
  primary key (enterprise_org_id, month)
);
create index enterprise_sla_snapshots_taken_by_idx on public.enterprise_sla_snapshots (taken_by);
alter table public.enterprise_sla_snapshots enable row level security;
create policy "sla snapshots visible" on public.enterprise_sla_snapshots for select to authenticated
  using (private.is_platform_admin() or private.is_member(enterprise_org_id));
create trigger audit_enterprise_sla_snapshots after insert on public.enterprise_sla_snapshots for each row execute function private.audit_row();

-- Frozen means frozen: no change, no removal (except when the Enterprise itself is deleted).
create function private.sla_snapshot_immutable()
returns trigger language plpgsql set search_path = ''
as $$
begin
  if tg_op = 'DELETE' and not exists (select 1 from public.organisations o where o.id = old.enterprise_org_id) then return old; end if;
  raise exception 'A frozen month cannot be changed';
end;
$$;
create trigger sla_snapshot_immutable before update or delete on public.enterprise_sla_snapshots for each row execute function private.sla_snapshot_immutable();

-- Takes the snapshot of one month (whoever asked), if there is anything to freeze and it is not frozen already. Returns whether it did.
create function private.take_sla_snapshot(p_enterprise uuid, p_month date, p_by uuid, p_source text)
returns boolean language plpgsql security definer set search_path = ''
as $$
declare m0 date := date_trunc('month', p_month)::date; v_pack jsonb; v_exc jsonb;
begin
  if exists (select 1 from public.enterprise_sla_snapshots where enterprise_org_id = p_enterprise and month = m0) then return false; end if;
  select coalesce(jsonb_agg(to_jsonb(x) - 'ord' order by x.ord), '[]'::jsonb) into v_pack
    from (select r.*, row_number() over () as ord from private.sla_pack_rows(p_enterprise, m0) r) x;
  if jsonb_array_length(v_pack) = 0 then return false; end if;
  select coalesce(jsonb_agg(to_jsonb(x) - 'ord' order by x.ord), '[]'::jsonb) into v_exc
    from (select r.*, row_number() over () as ord from private.sla_exception_rows(p_enterprise, m0) r) x;
  insert into public.enterprise_sla_snapshots (enterprise_org_id, month, taken_by, source, pack, exceptions)
    values (p_enterprise, m0, p_by, p_source, v_pack, v_exc);
  return true;
end;
$$;

-- The daily scan: freeze every closed month that has had its complaint window and has visits. p_now is only for tests.
create function private.freeze_sla_months(p_now timestamptz default now())
returns integer language plpgsql security definer set search_path = ''
as $$
declare r record; v_tz text; v_hours integer; v_taken integer := 0;
begin
  for r in select o.id as enterprise_id from public.organisations o where o.kind = 'buyer' and o.segment = 'enterprise' loop
    v_tz := coalesce((select mk.timezone from public.organisations o join public.markets mk on mk.code = o.market where o.id = r.enterprise_id), 'UTC');
    v_hours := coalesce((private.policy_for_org(r.enterprise_id)).balance_release_hours, 48);
    declare m record;
    begin
      for m in select distinct date_trunc('month', j.scheduled_start at time zone v_tz)::date as month
                 from public.jobs j
                where j.buyer_org_id = r.enterprise_id and j.status <> 'cancelled' and j.rework_of_issue is null loop
        -- the month's end in the Enterprise's timezone, plus the complaint window
        continue when p_now < ((m.month + interval '1 month')::timestamp at time zone v_tz) + make_interval(hours => v_hours);
        if private.take_sla_snapshot(r.enterprise_id, m.month, null, 'auto') then v_taken := v_taken + 1; end if;
      end loop;
    exception when others then
      raise warning 'freezing SLA months for % failed: %', r.enterprise_id, sqlerrm;
    end;
  end loop;
  return v_taken;
end;
$$;

-- The Enterprise freezes a closed month sooner than the scan would. Owner or approver only.
create function public.enterprise_freeze_sla_month(p_enterprise uuid, p_month date)
returns void language plpgsql security definer set search_path = ''
as $$
declare m0 date := date_trunc('month', p_month)::date; v_tz text;
begin
  if not (private.has_org_role(p_enterprise, array['owner', 'approver']::public.member_role[]) or private.is_platform_admin()) then
    raise exception 'Only the Enterprise''s owner or approvers can freeze a month';
  end if;
  if not private.is_enterprise(p_enterprise) then raise exception 'That is not an Enterprise'; end if;
  v_tz := coalesce((select mk.timezone from public.organisations o join public.markets mk on mk.code = o.market where o.id = p_enterprise), 'UTC');
  if now() < ((m0 + interval '1 month')::timestamp at time zone v_tz) then raise exception 'That month is not over yet'; end if;
  if exists (select 1 from public.enterprise_sla_snapshots where enterprise_org_id = p_enterprise and month = m0) then raise exception 'That month is already frozen'; end if;
  if not private.take_sla_snapshot(p_enterprise, m0, (select auth.uid()), 'manual') then raise exception 'There were no visits in that month to freeze'; end if;
end;
$$;

-- A frozen month, as it was: the pack rows and the visits behind them, in the order they were taken. No row if the month is not frozen.
create function public.enterprise_sla_snapshot(p_enterprise uuid, p_month date)
returns table (month date, taken_at timestamptz, source text, pack jsonb, exceptions jsonb)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (private.is_platform_admin() or private.is_member(p_enterprise)) then raise exception 'Not allowed to see this Enterprise''s reports'; end if;
  return query select s.month, s.taken_at, s.source, s.pack, s.exceptions
    from public.enterprise_sla_snapshots s where s.enterprise_org_id = p_enterprise and s.month = date_trunc('month', p_month)::date;
end;
$$;

revoke execute on function private.sla_pack_rows(uuid, date), private.sla_exception_rows(uuid, date), private.take_sla_snapshot(uuid, date, uuid, text),
  private.freeze_sla_months(timestamptz), private.sla_snapshot_immutable() from public, anon, authenticated;
revoke execute on function public.enterprise_freeze_sla_month(uuid, date), public.enterprise_sla_snapshot(uuid, date) from public, anon;
grant execute on function public.enterprise_freeze_sla_month(uuid, date), public.enterprise_sla_snapshot(uuid, date) to authenticated;

-- Run the freeze scan once a day where pg_cron is available (it is on Supabase). Elsewhere (a plain Postgres, the test database) it is
-- skipped and the scan is called directly.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    if exists (select 1 from cron.job where jobname = 'duly-freeze-sla-months') then
      perform cron.unschedule('duly-freeze-sla-months');
    end if;
    perform cron.schedule('duly-freeze-sla-months', '15 3 * * *', 'select private.freeze_sla_months()');
  end if;
end $$;
