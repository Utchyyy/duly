-- Duly foundations: configuration, organisations, people, roles and access helpers.
-- Rule: behaviour comes from markets / segments / policies rows, never hard-coded values.

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------
create table public.markets (
  code text primary key,
  name text not null,
  currency text not null,
  locale text not null,
  tax_name text,
  tax_rate numeric(5,2),
  data_region text not null,
  postcode_pattern text,
  created_at timestamptz not null default now()
);

create table public.segments (
  code text primary key,
  name text not null,
  description text,
  created_at timestamptz not null default now()
);

create table public.policies (
  market text not null references public.markets(code),
  segment text not null references public.segments(code),
  payment_model text not null check (payment_model in ('escrow_one_off', 'monthly_in_advance', 'invoice_terms')),
  -- Release rules as set in the PRD: a first release, then the balance once no complaint is raised.
  first_release_pct smallint not null default 55 check (first_release_pct between 0 and 100),
  first_release_on text not null default 'approval' check (first_release_on in ('approval', 'check_in', 'month_end')),
  balance_release_hours smallint not null default 48 check (balance_release_hours > 0),
  platform_fee_pct numeric(5,2),
  min_verification_tier smallint not null default 1 check (min_verification_tier between 0 and 3),
  reclean_window_hours smallint not null default 24,
  lateness_tolerance_min smallint not null default 15,
  ranking_weights jsonb not null default '{"standards_met":0.4,"on_time":0.2,"dispute_free":0.15,"repeat_clients":0.1,"verification":0.15}'::jsonb,
  standards_library text,
  created_at timestamptz not null default now(),
  primary key (market, segment)
);

-- ---------------------------------------------------------------------------
-- Organisations, people and roles
-- ---------------------------------------------------------------------------
create type public.org_kind as enum ('buyer', 'vendor', 'platform');

create type public.member_role as enum (
  'owner',          -- buyer organisation owner (a homeowner is the owner of a one-person buyer org)
  'approver',       -- organisation member who can approve work and spend
  'viewer',         -- organisation member with read access
  'vendor_admin',   -- runs a vendor in Duly Pro
  'dispatcher',     -- vendor staff who schedule and dispatch
  'operative',      -- cleaner using Duly Crew
  'platform_admin'  -- Duly Admin staff
);

create table public.organisations (
  id uuid primary key default gen_random_uuid(),
  kind public.org_kind not null,
  name text not null,
  market text not null default 'UK' references public.markets(code),
  segment text references public.segments(code),
  companies_house_no text,
  verification_tier smallint not null default 0 check (verification_tier between 0 and 3),
  created_at timestamptz not null default now()
);
create index organisations_kind_idx on public.organisations (kind);
create index organisations_market_idx on public.organisations (market);
create index organisations_segment_idx on public.organisations (segment);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  phone text,
  created_at timestamptz not null default now()
);

create table public.memberships (
  org_id uuid not null references public.organisations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role public.member_role not null,
  created_at timestamptz not null default now(),
  primary key (org_id, user_id, role)
);
create index memberships_user_idx on public.memberships (user_id);

-- A profile row for every new account.
create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', null))
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Access helpers (security definer so policies don't recurse through memberships)
-- ---------------------------------------------------------------------------
create function public.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.memberships
    where user_id = (select auth.uid()) and role = 'platform_admin'
  );
$$;

create function public.is_member(p_org uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.memberships
    where org_id = p_org and user_id = (select auth.uid())
  );
$$;

create function public.has_org_role(p_org uuid, p_roles public.member_role[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.memberships
    where org_id = p_org and user_id = (select auth.uid()) and role = any (p_roles)
  );
$$;

-- Lets a signed-in person start a buyer organisation (a home or a business) and own it.
create function public.create_buyer_org(p_name text, p_segment text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org uuid;
begin
  if (select auth.uid()) is null then
    raise exception 'Sign in first';
  end if;
  if p_segment not in (select code from public.segments) then
    raise exception 'Unknown segment %', p_segment;
  end if;
  insert into public.organisations (kind, name, segment)
  values ('buyer', p_name, p_segment)
  returning id into v_org;
  insert into public.memberships (org_id, user_id, role)
  values (v_org, (select auth.uid()), 'owner');
  return v_org;
end;
$$;

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------
alter table public.markets enable row level security;
alter table public.segments enable row level security;
alter table public.policies enable row level security;
alter table public.organisations enable row level security;
alter table public.profiles enable row level security;
alter table public.memberships enable row level security;

-- Configuration: readable by signed-in users; changed only by platform admins.
create policy "config readable" on public.markets for select to authenticated using (true);
create policy "config admin" on public.markets for all to authenticated using (public.is_platform_admin()) with check (public.is_platform_admin());
create policy "config readable" on public.segments for select to authenticated using (true);
create policy "config admin" on public.segments for all to authenticated using (public.is_platform_admin()) with check (public.is_platform_admin());
create policy "config readable" on public.policies for select to authenticated using (true);
create policy "config admin" on public.policies for all to authenticated using (public.is_platform_admin()) with check (public.is_platform_admin());

-- Organisations: members see their own; vendors are a directory any signed-in user can browse.
create policy "orgs visible" on public.organisations for select to authenticated
  using (kind = 'vendor' or public.is_member(id) or public.is_platform_admin());
create policy "orgs updatable by owners" on public.organisations for update to authenticated
  using (public.has_org_role(id, array['owner', 'vendor_admin']::public.member_role[]) or public.is_platform_admin())
  with check (public.has_org_role(id, array['owner', 'vendor_admin']::public.member_role[]) or public.is_platform_admin());
create policy "orgs created by admins" on public.organisations for insert to authenticated
  with check (public.is_platform_admin());
create policy "orgs deleted by admins" on public.organisations for delete to authenticated
  using (public.is_platform_admin());

-- Profiles: you see and edit your own; colleagues in the same organisation can see each other.
create policy "own profile" on public.profiles for select to authenticated
  using (
    id = (select auth.uid())
    or public.is_platform_admin()
    or exists (
      select 1 from public.memberships mine
      join public.memberships theirs on theirs.org_id = mine.org_id
      where mine.user_id = (select auth.uid()) and theirs.user_id = profiles.id
    )
  );
create policy "edit own profile" on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- Memberships: you see your own and your organisation's; owners and vendor admins manage them.
create policy "memberships visible" on public.memberships for select to authenticated
  using (user_id = (select auth.uid()) or public.is_member(org_id) or public.is_platform_admin());
create policy "memberships managed" on public.memberships for all to authenticated
  using (public.has_org_role(org_id, array['owner', 'vendor_admin']::public.member_role[]) or public.is_platform_admin())
  with check (public.has_org_role(org_id, array['owner', 'vendor_admin']::public.member_role[]) or public.is_platform_admin());

-- Signed-out visitors get nothing from these tables.
revoke all on public.markets, public.segments, public.policies, public.organisations, public.profiles, public.memberships from anon;
revoke execute on function public.is_platform_admin(), public.is_member(uuid), public.has_org_role(uuid, public.member_role[]), public.create_buyer_org(text, text) from anon, public;
grant execute on function public.is_platform_admin(), public.is_member(uuid), public.has_org_role(uuid, public.member_role[]), public.create_buyer_org(text, text) to authenticated;
revoke execute on function public.handle_new_user() from anon, authenticated, public;
