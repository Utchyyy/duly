-- WFX labour layer (towns, workers, WIIx, shifts, DBS) and the deterministic SQL that ranks and prices.
-- Rule: ranking, matching, pricing and scoring live here. The app shows results in order and never re-sorts.

create table public.towns (
  id integer generated always as identity primary key,
  name text not null unique,
  lat numeric(9,6) not null,
  lng numeric(9,6) not null,
  market text not null default 'UK' references public.markets(code)
);
create index towns_market_idx on public.towns (market);

create table public.workers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique references auth.users(id) on delete set null,
  vendor_org_id uuid references public.organisations(id) on delete set null, -- employer, if any
  full_name text not null,
  phone text,
  home_town_id integer references public.towns(id),
  max_commute_km numeric(5,1) not null default 15,
  available_early boolean not null default false,
  available_evening boolean not null default false,
  dbs_cleared boolean not null default false,
  created_at timestamptz not null default now()
);
create index workers_vendor_idx on public.workers (vendor_org_id);
create index workers_town_idx on public.workers (home_town_id);

create table public.wiix_screens (
  worker_id uuid primary key references public.workers(id) on delete cascade,
  reliability smallint check (reliability between 1 and 5),
  shift_fit smallint check (shift_fit between 1 and 5),
  capability smallint check (capability between 1 and 5),
  commute_tolerance smallint check (commute_tolerance between 1 and 5),
  wiix_score numeric(5,2) not null,
  screened_at timestamptz not null default now()
);

create type public.shift_status as enum ('open', 'offered', 'filled', 'completed', 'cancelled', 'no_show');

create table public.shifts (
  id uuid primary key default gen_random_uuid(),
  vendor_org_id uuid not null references public.organisations(id) on delete cascade,
  job_id uuid references public.jobs(id) on delete set null,
  town_id integer not null references public.towns(id),
  shift_date date not null,
  start_time time not null,
  end_time time not null,
  hourly_pay numeric(6,2) not null check (hourly_pay > 0),  -- no default: pay is set per shift, never hard-coded
  status public.shift_status not null default 'open',
  filled_by uuid references public.workers(id) on delete set null,
  created_at timestamptz not null default now()
);
create index shifts_vendor_idx on public.shifts (vendor_org_id, shift_date);
create index shifts_job_idx on public.shifts (job_id);
create index shifts_town_idx on public.shifts (town_id);
create index shifts_filled_by_idx on public.shifts (filled_by);
create index shifts_status_idx on public.shifts (status);

create table public.shift_events (
  id uuid primary key default gen_random_uuid(),
  shift_id uuid not null references public.shifts(id) on delete cascade,
  worker_id uuid references public.workers(id) on delete set null,
  event_type text not null check (event_type in ('offered', 'accepted', 'declined', 'arrived', 'completed', 'no_show', 'cancelled')),
  occurred_at timestamptz not null default now(),
  notes text
);
create index shift_events_shift_idx on public.shift_events (shift_id, occurred_at);
create index shift_events_worker_idx on public.shift_events (worker_id);

create type public.dbs_path as enum ('new_check', 'existing_certificate');
create type public.dbs_status as enum ('submitted_by_worker', 'sent_to_ucheck', 'cleared', 'not_cleared', 'withdrawn');
create type public.dbs_certificate_type as enum ('basic', 'standard', 'enhanced');

create table public.dbs_applications (
  id uuid primary key default gen_random_uuid(),
  worker_id uuid not null references public.workers(id) on delete cascade,
  path public.dbs_path not null,
  status public.dbs_status not null default 'submitted_by_worker',
  certificate_type public.dbs_certificate_type,
  certificate_reference text,
  update_service_id text,
  form_data jsonb not null default '{}'::jsonb,
  admin_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Existing certificates count only if Standard or Enhanced and on the DBS Update Service.
  check (path <> 'existing_certificate' or (certificate_type in ('standard', 'enhanced') and update_service_id is not null))
);
create index dbs_applications_worker_idx on public.dbs_applications (worker_id);

-- ---------------------------------------------------------------------------
-- Helpers and triggers
-- ---------------------------------------------------------------------------
create function private.is_worker_self(p_worker uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.workers w where w.id = p_worker and w.user_id = (select auth.uid()));
$$;

create function private.employs_worker(p_worker uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.workers w where w.id = p_worker and w.vendor_org_id is not null and private.is_vendor_staff(w.vendor_org_id));
$$;

create function private.has_worker_record()
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.workers w where w.user_id = (select auth.uid()));
$$;

create function private.is_any_vendor_staff()
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.memberships
    where user_id = (select auth.uid()) and role in ('vendor_admin', 'dispatcher')
  );
$$;

-- Only platform admins can mark someone DBS cleared directly.
create function private.protect_worker_fields()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.dbs_cleared is distinct from old.dbs_cleared and not private.is_platform_admin()
     and current_setting('duly.dbs_sync', true) is distinct from 'on' then
    raise exception 'Only the DBS workflow can change clearance';
  end if;
  return new;
end;
$$;
create trigger workers_protect_fields before update on public.workers
  for each row execute function private.protect_worker_fields();

-- A cleared DBS application marks the worker cleared.
create function private.dbs_sync_worker_clearance()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  new.updated_at := now();
  if new.status is distinct from old.status then
    perform set_config('duly.dbs_sync', 'on', true);
    update public.workers set dbs_cleared = (new.status = 'cleared') where id = new.worker_id
      and (new.status in ('cleared', 'not_cleared'));
    perform set_config('duly.dbs_sync', 'off', true);
  end if;
  return new;
end;
$$;
create trigger dbs_applications_sync before update on public.dbs_applications
  for each row execute function private.dbs_sync_worker_clearance();

revoke execute on all functions in schema private from public, anon;
grant execute on function private.is_worker_self(uuid), private.employs_worker(uuid), private.has_worker_record(), private.is_any_vendor_staff() to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Matching, ranking and pricing (ported from the WFX pilot where noted)
-- ---------------------------------------------------------------------------
create function public.haversine_km(lat1 numeric, lon1 numeric, lat2 numeric, lon2 numeric)
returns numeric language sql immutable parallel safe set search_path = ''
as $$
  select 6371 * 2 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2)
  ));
$$;

create function public.commute_band(km numeric)
returns table (band text, paid_minutes integer, note text)
language sql immutable parallel safe set search_path = ''
as $$
  select
    case when km <= 8 then 'Local' when km <= 25 then 'Corridor' else 'Extended' end,
    case when km <= 8 then 0 when km <= 25 then 30 else 45 end,
    case
      when km <= 8 then 'No cross-town travel: standard shift pay only.'
      when km <= 25 then 'Corridor placement: first 30 minutes of travel paid.'
      else 'Extended placement: first 45 minutes of travel paid, surge-pay eligible.'
    end;
$$;

-- Pilot logic: eligible within commute limit and availability window (whole shift checked), ranked by WIIx minus distance.
create function public.rank_candidates(p_shift_id uuid)
returns table (worker_id uuid, full_name text, home_town text, km numeric, band text, paid_minutes integer, note text,
               wiix_score numeric, rank_score numeric, cross_town boolean)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
begin
  if not exists (
    select 1 from public.shifts sh
    where sh.id = p_shift_id and (private.is_vendor_staff(sh.vendor_org_id) or private.is_platform_admin())
  ) then
    raise exception 'Not allowed to rank candidates for this shift';
  end if;

  return query
  with s as (
    select sh.start_time, sh.end_time, t.lat as shift_lat, t.lng as shift_lng, t.name as shift_town
    from public.shifts sh join public.towns t on t.id = sh.town_id
    where sh.id = p_shift_id
  ),
  eligible as (
    select w.id as worker_id, w.full_name, wt.name as home_town, wt.name <> s.shift_town as cross_town,
           round(public.haversine_km(wt.lat, wt.lng, s.shift_lat, s.shift_lng), 1) as km, wx.wiix_score
    from public.workers w
    join public.towns wt on wt.id = w.home_town_id
    join public.wiix_screens wx on wx.worker_id = w.id
    cross join s
    where public.haversine_km(wt.lat, wt.lng, s.shift_lat, s.shift_lng) <= w.max_commute_km
      and (s.start_time >= '07:00' or w.available_early)
      and (s.end_time <= '19:00' or w.available_evening)
  )
  select e.worker_id, e.full_name, e.home_town, e.km, cb.band, cb.paid_minutes, cb.note, e.wiix_score,
         round(e.wiix_score - e.km * 0.05, 2) as rank_score, e.cross_town
  from eligible e
  cross join lateral public.commute_band(e.km) cb
  order by rank_score desc, e.worker_id;
end;
$$;

create function public.demand_by_town()
returns table (town text, open_shifts bigint, workers bigint, balance bigint, status text)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
begin
  if not (private.is_any_vendor_staff() or private.is_platform_admin()) then
    raise exception 'Not allowed';
  end if;
  return query
  select t.name, coalesce(o.open_shifts, 0), coalesce(w.workers, 0),
         coalesce(w.workers, 0) - coalesce(o.open_shifts, 0),
         case
           when coalesce(w.workers, 0) - coalesce(o.open_shifts, 0) > 0 then 'Surplus'
           when coalesce(w.workers, 0) - coalesce(o.open_shifts, 0) < 0 then 'Deficit'
           else 'Balanced'
         end
  from public.towns t
  left join (select town_id, count(*) as open_shifts from public.shifts where status = 'open' group by town_id) o on o.town_id = t.id
  left join (select home_town_id, count(*) as workers from public.workers group by home_town_id) w on w.home_town_id = t.id
  order by t.name;
end;
$$;

create function public.corridor_suggestions()
returns table (from_town text, to_town text, km numeric, band text, paid_minutes integer, surplus_avail bigint, deficit bigint)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
begin
  if not (private.is_any_vendor_staff() or private.is_platform_admin()) then
    raise exception 'Not allowed';
  end if;
  return query
  with d as (select * from public.demand_by_town()),
  ranked as (
    select dd.town as to_town, dd.balance as deficit_balance, ss.town as from_town, ss.balance as surplus_balance,
           public.haversine_km(ts.lat, ts.lng, td.lat, td.lng) as km,
           row_number() over (partition by dd.town order by public.haversine_km(ts.lat, ts.lng, td.lat, td.lng)) as rn
    from d dd
    join d ss on ss.balance > 0
    join public.towns td on td.name = dd.town
    join public.towns ts on ts.name = ss.town
    where dd.balance < 0
  )
  select r.from_town, r.to_town, round(r.km, 1), cb.band, cb.paid_minutes, r.surplus_balance, -r.deficit_balance
  from ranked r cross join lateral public.commute_band(r.km) cb
  where r.rn = 1;
end;
$$;

-- Vendors for a site: within service radius, meeting the segment's minimum verification tier,
-- ranked by delivered quality, then verification, then distance. Price is not a ranking input.
create function public.rank_vendors(p_site uuid)
returns table (org_id uuid, name text, km numeric, quality_score numeric, verification_tier smallint,
               hourly_rate numeric, rank integer)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
begin
  if not private.can_see_site(p_site) then
    raise exception 'Not allowed to search for this site';
  end if;
  return query
  with s as (
    select si.lat, si.lng, o.market, coalesce(o.segment, 'homeowner') as segment
    from public.sites si join public.organisations o on o.id = si.org_id
    where si.id = p_site
  ),
  candidates as (
    select v.id, v.name, round(public.haversine_km(s.lat, s.lng, vp.base_lat, vp.base_lng), 1) as km,
           sc.quality_score, v.verification_tier, vp.hourly_rate
    from public.organisations v
    join public.vendor_profiles vp on vp.org_id = v.id
    left join public.vendor_scores sc on sc.org_id = v.id
    cross join s
    left join public.policies p on p.market = s.market and p.segment = s.segment
    where v.kind = 'vendor'
      and v.market = s.market
      and vp.base_lat is not null and s.lat is not null
      and public.haversine_km(s.lat, s.lng, vp.base_lat, vp.base_lng) <= vp.service_radius_km
      and v.verification_tier >= coalesce(p.min_verification_tier, 1)
  )
  select c.id, c.name, c.km, c.quality_score, c.verification_tier, c.hourly_rate,
         (row_number() over (order by c.quality_score desc nulls last, c.verification_tier desc, c.km asc, c.id))::integer
  from candidates c
  order by 7;
end;
$$;

-- A quote priced line by line from the brief's schedule: minutes per area x the vendor's rate, plus urgency.
create function public.price_quote(p_brief uuid, p_version integer, p_vendor uuid, p_urgency text default 'next_slot')
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_rate numeric;
  v_urgency_pct numeric;
  v_lines jsonb;
  v_minutes numeric;
  v_labour numeric;
  v_urgency numeric;
begin
  if not (private.is_vendor_staff(p_vendor) or private.is_platform_admin()
          or exists (select 1 from public.briefs b where b.id = p_brief and private.is_member(b.buyer_org_id))) then
    raise exception 'Not allowed to price this brief';
  end if;

  select vp.hourly_rate, coalesce((vp.urgency_pct ->> p_urgency)::numeric, 0)
    into v_rate, v_urgency_pct
  from public.vendor_profiles vp where vp.org_id = p_vendor;
  if v_rate is null then
    raise exception 'Vendor has no hourly rate set';
  end if;

  with areas as (
    select a ->> 'id' as area_id, a ->> 'name' as name, coalesce((a ->> 'minutes')::numeric, 0) as minutes
    from public.brief_versions bv,
         jsonb_array_elements(bv.schedule) sec,
         jsonb_array_elements(sec -> 'areas') a
    where bv.brief_id = p_brief and bv.version = p_version
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'area_id', area_id, 'name', name, 'minutes', minutes,
           'amount', round(minutes / 60 * v_rate, 2)) order by name), '[]'::jsonb),
         coalesce(sum(minutes), 0)
    into v_lines, v_minutes
  from areas;

  v_labour := round(v_minutes / 60 * v_rate, 2);
  v_urgency := round(v_labour * v_urgency_pct / 100, 2);

  return jsonb_build_object(
    'hourly_rate', v_rate,
    'minutes', v_minutes,
    'lines', v_lines,
    'labour', v_labour,
    'urgency', p_urgency,
    'urgency_pct', v_urgency_pct,
    'urgency_amount', v_urgency,
    'total', v_labour + v_urgency
  );
end;
$$;

revoke execute on function public.rank_candidates(uuid), public.demand_by_town(), public.corridor_suggestions(),
  public.rank_vendors(uuid), public.price_quote(uuid, integer, uuid, text) from public, anon;
grant execute on function public.rank_candidates(uuid), public.demand_by_town(), public.corridor_suggestions(),
  public.rank_vendors(uuid), public.price_quote(uuid, integer, uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------
alter table public.towns enable row level security;
alter table public.workers enable row level security;
alter table public.wiix_screens enable row level security;
alter table public.shifts enable row level security;
alter table public.shift_events enable row level security;
alter table public.dbs_applications enable row level security;

create policy "towns readable" on public.towns for select to authenticated using (true);
create policy "towns admin" on public.towns for all to authenticated using (private.is_platform_admin()) with check (private.is_platform_admin());

create policy "workers visible" on public.workers for select to authenticated
  using (user_id = (select auth.uid()) or private.employs_worker(id) or private.is_platform_admin());
create policy "workers register themselves" on public.workers for insert to authenticated
  with check ((user_id = (select auth.uid()) and vendor_org_id is null and dbs_cleared = false)
              or (vendor_org_id is not null and private.is_vendor_staff(vendor_org_id) and dbs_cleared = false)
              or private.is_platform_admin());
create policy "workers update" on public.workers for update to authenticated
  using (user_id = (select auth.uid()) or private.employs_worker(id) or private.is_platform_admin())
  with check (user_id = (select auth.uid()) or private.employs_worker(id) or private.is_platform_admin());

create policy "wiix visible" on public.wiix_screens for select to authenticated
  using (private.is_worker_self(worker_id) or private.employs_worker(worker_id) or private.is_platform_admin());
create policy "wiix managed" on public.wiix_screens for all to authenticated
  using (private.employs_worker(worker_id) or private.is_platform_admin())
  with check (private.employs_worker(worker_id) or private.is_platform_admin());

create policy "shifts visible" on public.shifts for select to authenticated
  using (private.is_member(vendor_org_id) or private.is_platform_admin()
         or private.is_worker_self(filled_by)
         or (status = 'open' and private.has_worker_record()));
create policy "shifts managed by vendor" on public.shifts for all to authenticated
  using (private.is_vendor_staff(vendor_org_id) or private.is_platform_admin())
  with check (private.is_vendor_staff(vendor_org_id) or private.is_platform_admin());

create policy "shift events visible" on public.shift_events for select to authenticated
  using (private.is_worker_self(worker_id) or private.is_platform_admin()
         or exists (select 1 from public.shifts s where s.id = shift_id and private.is_vendor_staff(s.vendor_org_id)));
create policy "shift events added" on public.shift_events for insert to authenticated
  with check ((private.is_worker_self(worker_id) and event_type in ('accepted', 'declined'))
              or exists (select 1 from public.shifts s where s.id = shift_id and private.is_vendor_staff(s.vendor_org_id))
              or private.is_platform_admin());

create policy "dbs visible" on public.dbs_applications for select to authenticated
  using (private.is_worker_self(worker_id) or private.is_platform_admin()
         or exists (select 1 from public.workers w where w.id = worker_id and w.vendor_org_id is not null
                    and private.has_org_role(w.vendor_org_id, array['vendor_admin']::public.member_role[])));
create policy "dbs submitted by worker" on public.dbs_applications for insert to authenticated
  with check ((private.is_worker_self(worker_id) and status = 'submitted_by_worker') or private.is_platform_admin());
create policy "dbs processed by admin" on public.dbs_applications for update to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

revoke all on public.towns, public.workers, public.wiix_screens, public.shifts, public.shift_events, public.dbs_applications from anon;
