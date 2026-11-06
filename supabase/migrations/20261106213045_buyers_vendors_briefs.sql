-- Buyers, vendors, briefs, standards, verification, quotes and contracts.

-- ---------------------------------------------------------------------------
-- Sites
-- ---------------------------------------------------------------------------
create table public.sites (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organisations(id) on delete cascade,
  name text not null,
  address_line1 text,
  town text,
  postcode text,
  lat numeric(9,6),
  lng numeric(9,6),
  floor_area_m2 integer check (floor_area_m2 > 0),
  access_notes text,
  geofence_m integer not null default 150 check (geofence_m between 25 and 2000),
  created_at timestamptz not null default now()
);
create index sites_org_idx on public.sites (org_id);

-- ---------------------------------------------------------------------------
-- Standards library and schedule templates
-- A schedule is JSON: [{ "section", "subsection", "areas": [{ "id", "name", "area_type",
--   "intensity": {"mon":"S|W|C|M|-", ...}, "minutes", "standards": [{ "id", "text" }],
--   "evidence": "before_after|after", "assignee": "person|robot|both" }] }]
-- ---------------------------------------------------------------------------
create table public.standards_library (
  id uuid primary key default gen_random_uuid(),
  segment text not null references public.segments(code),
  area_type text not null,
  text text not null,
  created_at timestamptz not null default now()
);
create index standards_library_segment_idx on public.standards_library (segment, area_type);

create table public.schedule_templates (
  id uuid primary key default gen_random_uuid(),
  vendor_org_id uuid references public.organisations(id) on delete cascade, -- null = shared library template
  name text not null,
  segment text references public.segments(code),
  sections jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index schedule_templates_vendor_idx on public.schedule_templates (vendor_org_id);
create index schedule_templates_segment_idx on public.schedule_templates (segment);

-- ---------------------------------------------------------------------------
-- Briefs (the contract) and their locked versions
-- ---------------------------------------------------------------------------
create type public.brief_status as enum ('draft', 'locked', 'archived');

create table public.briefs (
  id uuid primary key default gen_random_uuid(),
  buyer_org_id uuid not null references public.organisations(id) on delete cascade,
  site_id uuid not null references public.sites(id) on delete cascade,
  title text not null,
  status public.brief_status not null default 'draft',
  current_version integer not null default 1,
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index briefs_buyer_idx on public.briefs (buyer_org_id);
create index briefs_site_idx on public.briefs (site_id);
create index briefs_created_by_idx on public.briefs (created_by);

create table public.brief_versions (
  brief_id uuid not null references public.briefs(id) on delete cascade,
  version integer not null check (version > 0),
  schedule jsonb not null default '[]'::jsonb,
  visits_per_week numeric(4,1),
  preferred_days text[],
  preferred_start time,
  lateness_tolerance_min smallint,
  notes text,
  locked_at timestamptz,
  locked_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (brief_id, version)
);
create index brief_versions_locked_by_idx on public.brief_versions (locked_by);

-- A locked version never changes. Changes after booking go into a new version.
create function private.protect_locked_brief_version()
returns trigger language plpgsql set search_path = ''
as $$
begin
  if old.locked_at is not null then
    raise exception 'Brief version % is locked; create a new version instead', old.version;
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;
create trigger brief_versions_locked
  before update or delete on public.brief_versions
  for each row execute function private.protect_locked_brief_version();

-- AI drafts land here and nowhere else until a person approves them.
create type public.approval_status as enum ('pending', 'approved', 'rejected');

create table public.approval_queue (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organisations(id) on delete cascade,
  kind text not null default 'brief_draft' check (kind in ('brief_draft')),
  status public.approval_status not null default 'pending',
  source jsonb not null default '{}'::jsonb,   -- uploaded file path, transcript reference
  draft jsonb not null default '{}'::jsonb,    -- the drafted site, schedule and standards
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);
create index approval_queue_org_idx on public.approval_queue (org_id, status);
create index approval_queue_created_by_idx on public.approval_queue (created_by);
create index approval_queue_reviewed_by_idx on public.approval_queue (reviewed_by);

-- ---------------------------------------------------------------------------
-- Vendors: storefront, verification and scores
-- ---------------------------------------------------------------------------
create table public.vendor_profiles (
  org_id uuid primary key references public.organisations(id) on delete cascade,
  description text,
  base_lat numeric(9,6),
  base_lng numeric(9,6),
  service_radius_km numeric(6,1) not null default 15,
  hourly_rate numeric(8,2) check (hourly_rate > 0),
  urgency_pct jsonb not null default '{"next_slot":0,"same_day":15,"within_2h":50}'::jsonb,
  add_ons jsonb not null default '[]'::jsonb,   -- [{ "code", "name", "price" }]
  updated_at timestamptz not null default now()
);

create type public.claim_kind as enum (
  'companies_house', 'public_liability_insurance', 'dbs', 'right_to_work',
  'iso_9001', 'chas', 'safecontractor', 'other'
);
create type public.claim_status as enum ('self_declared', 'pending', 'verified', 'rejected', 'expired');

create table public.verification_claims (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organisations(id) on delete cascade,
  subject_user_id uuid references auth.users(id) on delete cascade, -- set for operative-level claims (DBS, right to work)
  kind public.claim_kind not null,
  status public.claim_status not null default 'self_declared',
  reference text,
  evidence_path text,
  valid_until date,
  notes text,
  verified_by uuid references auth.users(id) on delete set null,
  verified_at timestamptz,
  created_at timestamptz not null default now()
);
create index verification_claims_org_idx on public.verification_claims (org_id);
create index verification_claims_subject_idx on public.verification_claims (subject_user_id);
create index verification_claims_verified_by_idx on public.verification_claims (verified_by);
create index verification_claims_status_idx on public.verification_claims (status);

create table public.vendor_scores (
  org_id uuid primary key references public.organisations(id) on delete cascade,
  quality_score numeric(5,2),
  standards_met_rate numeric(5,2),
  on_time_rate numeric(5,2),
  dispute_rate numeric(5,2),
  repeat_client_rate numeric(5,2),
  jobs_completed integer not null default 0,
  computed_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Quotes and contracts
-- ---------------------------------------------------------------------------
create type public.quote_status as enum ('invited', 'submitted', 'accepted', 'declined', 'expired', 'withdrawn');

create table public.quotes (
  id uuid primary key default gen_random_uuid(),
  brief_id uuid not null,
  brief_version integer not null,
  vendor_org_id uuid not null references public.organisations(id) on delete cascade,
  status public.quote_status not null default 'invited',
  urgency text not null default 'next_slot' check (urgency in ('next_slot', 'same_day', 'within_2h')),
  lines jsonb not null default '[]'::jsonb,   -- priced by public.price_quote, shown line by line
  total numeric(10,2),
  currency text not null default 'GBP',
  valid_until date,
  submitted_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (brief_id, brief_version) references public.brief_versions(brief_id, version) on delete cascade,
  unique (brief_id, brief_version, vendor_org_id)
);
create index quotes_vendor_idx on public.quotes (vendor_org_id);

create type public.contract_status as enum ('draft', 'active', 'paused', 'ended');

create table public.contracts (
  id uuid primary key default gen_random_uuid(),
  buyer_org_id uuid not null references public.organisations(id) on delete cascade,
  vendor_org_id uuid not null references public.organisations(id) on delete cascade,
  site_id uuid not null references public.sites(id) on delete cascade,
  brief_id uuid not null,
  brief_version integer not null,
  quote_id uuid references public.quotes(id) on delete set null,
  status public.contract_status not null default 'draft',
  starts_on date,
  ends_on date,
  billing text not null default 'monthly' check (billing in ('per_job', 'monthly')),
  monthly_value numeric(10,2),
  currency text not null default 'GBP',
  payment_terms_days smallint not null default 14,
  sla_response_hours smallint not null default 24,
  quality_target smallint not null default 90 check (quality_target between 0 and 100),
  service_terms jsonb not null default '[]'::jsonb,
  loyalty jsonb,
  created_at timestamptz not null default now(),
  foreign key (brief_id, brief_version) references public.brief_versions(brief_id, version)
);
create index contracts_buyer_idx on public.contracts (buyer_org_id);
create index contracts_vendor_idx on public.contracts (vendor_org_id);
create index contracts_site_idx on public.contracts (site_id);
create index contracts_brief_idx on public.contracts (brief_id, brief_version);
create index contracts_quote_idx on public.contracts (quote_id);

-- ---------------------------------------------------------------------------
-- Access helpers for this layer
-- ---------------------------------------------------------------------------
create function private.is_vendor_staff(p_org uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select private.has_org_role(p_org, array['vendor_admin', 'dispatcher']::public.member_role[]);
$$;

create function private.can_see_brief(p_brief uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select private.is_platform_admin()
    or exists (select 1 from public.briefs b where b.id = p_brief and private.is_member(b.buyer_org_id))
    or exists (select 1 from public.quotes q where q.brief_id = p_brief and private.is_member(q.vendor_org_id))
    or exists (select 1 from public.contracts c where c.brief_id = p_brief and private.is_member(c.vendor_org_id));
$$;

create function private.can_see_site(p_site uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select private.is_platform_admin()
    or exists (select 1 from public.sites s where s.id = p_site and private.is_member(s.org_id))
    or exists (
      select 1 from public.briefs b join public.quotes q on q.brief_id = b.id
      where b.site_id = p_site and private.is_member(q.vendor_org_id)
    )
    or exists (select 1 from public.contracts c where c.site_id = p_site and private.is_member(c.vendor_org_id));
$$;

revoke execute on all functions in schema private from public, anon;
grant execute on function private.is_vendor_staff(uuid), private.can_see_brief(uuid), private.can_see_site(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------
alter table public.sites enable row level security;
alter table public.standards_library enable row level security;
alter table public.schedule_templates enable row level security;
alter table public.briefs enable row level security;
alter table public.brief_versions enable row level security;
alter table public.approval_queue enable row level security;
alter table public.vendor_profiles enable row level security;
alter table public.verification_claims enable row level security;
alter table public.vendor_scores enable row level security;
alter table public.quotes enable row level security;
alter table public.contracts enable row level security;

-- Sites
create policy "sites visible" on public.sites for select to authenticated using (private.can_see_site(id));
create policy "sites managed by buyer" on public.sites for all to authenticated
  using (private.has_org_role(org_id, array['owner', 'approver']::public.member_role[]) or private.is_platform_admin())
  with check (private.has_org_role(org_id, array['owner', 'approver']::public.member_role[]) or private.is_platform_admin());

-- Standards library: readable by all signed-in users, maintained by admins
create policy "standards readable" on public.standards_library for select to authenticated using (true);
create policy "standards admin" on public.standards_library for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

-- Schedule templates: shared library for everyone; a vendor's own for its staff
create policy "templates visible" on public.schedule_templates for select to authenticated
  using (vendor_org_id is null or private.is_member(vendor_org_id) or private.is_platform_admin());
create policy "templates managed" on public.schedule_templates for all to authenticated
  using ((vendor_org_id is not null and private.is_vendor_staff(vendor_org_id)) or private.is_platform_admin())
  with check ((vendor_org_id is not null and private.is_vendor_staff(vendor_org_id)) or private.is_platform_admin());

-- Briefs
create policy "briefs visible" on public.briefs for select to authenticated using (private.can_see_brief(id));
create policy "briefs managed by buyer" on public.briefs for all to authenticated
  using (private.has_org_role(buyer_org_id, array['owner', 'approver']::public.member_role[]) or private.is_platform_admin())
  with check (private.has_org_role(buyer_org_id, array['owner', 'approver']::public.member_role[]) or private.is_platform_admin());

create policy "brief versions visible" on public.brief_versions for select to authenticated using (private.can_see_brief(brief_id));
create policy "brief versions managed by buyer" on public.brief_versions for all to authenticated
  using (exists (select 1 from public.briefs b where b.id = brief_id and private.has_org_role(b.buyer_org_id, array['owner', 'approver']::public.member_role[])) or private.is_platform_admin())
  with check (exists (select 1 from public.briefs b where b.id = brief_id and private.has_org_role(b.buyer_org_id, array['owner', 'approver']::public.member_role[])) or private.is_platform_admin());

-- Approval queue: only the organisation that owns the draft
create policy "approval queue visible" on public.approval_queue for select to authenticated
  using (private.is_member(org_id) or private.is_platform_admin());
create policy "approval queue managed" on public.approval_queue for all to authenticated
  using (private.has_org_role(org_id, array['owner', 'approver', 'vendor_admin', 'dispatcher']::public.member_role[]) or private.is_platform_admin())
  with check (private.has_org_role(org_id, array['owner', 'approver', 'vendor_admin', 'dispatcher']::public.member_role[]) or private.is_platform_admin());

-- Vendor storefront: readable by signed-in buyers; edited by the vendor's admins
create policy "vendor profiles readable" on public.vendor_profiles for select to authenticated using (true);
create policy "vendor profiles managed" on public.vendor_profiles for all to authenticated
  using (private.has_org_role(org_id, array['vendor_admin']::public.member_role[]) or private.is_platform_admin())
  with check (private.has_org_role(org_id, array['vendor_admin']::public.member_role[]) or private.is_platform_admin());

-- Verification claims: company-level claims are public badges; operative claims stay private.
create policy "claims visible" on public.verification_claims for select to authenticated
  using (subject_user_id is null or subject_user_id = (select auth.uid()) or private.is_member(org_id) or private.is_platform_admin());
create policy "claims submitted by vendor" on public.verification_claims for insert to authenticated
  with check ((private.is_vendor_staff(org_id) and status in ('self_declared', 'pending') and verified_by is null) or private.is_platform_admin());
create policy "claims edited by vendor before review" on public.verification_claims for update to authenticated
  using ((private.is_vendor_staff(org_id) and status in ('self_declared', 'pending')) or private.is_platform_admin())
  with check ((private.is_vendor_staff(org_id) and status in ('self_declared', 'pending') and verified_by is null) or private.is_platform_admin());
create policy "claims deleted by admin" on public.verification_claims for delete to authenticated
  using (private.is_platform_admin());

-- Scores: readable by everyone signed in; written only by the platform
create policy "scores readable" on public.vendor_scores for select to authenticated using (true);
create policy "scores admin" on public.vendor_scores for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

-- Quotes: the buyer sees quotes once submitted; the vendor sees its own.
create policy "quotes visible" on public.quotes for select to authenticated
  using (
    private.is_member(vendor_org_id)
    or private.is_platform_admin()
    or (status <> 'invited' and exists (select 1 from public.briefs b where b.id = brief_id and private.is_member(b.buyer_org_id)))
  );
create policy "quotes invited by buyer" on public.quotes for insert to authenticated
  with check (
    status = 'invited'
    and exists (select 1 from public.briefs b where b.id = brief_id and private.has_org_role(b.buyer_org_id, array['owner', 'approver']::public.member_role[]))
  );
create policy "quotes priced by vendor" on public.quotes for update to authenticated
  using (private.is_vendor_staff(vendor_org_id) and status in ('invited', 'submitted'))
  with check (private.is_vendor_staff(vendor_org_id) and status in ('invited', 'submitted', 'withdrawn'));
create policy "quotes admin" on public.quotes for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

-- Contracts: both parties can read; changes go through functions in later steps.
create policy "contracts visible" on public.contracts for select to authenticated
  using (private.is_member(buyer_org_id) or private.is_member(vendor_org_id) or private.is_platform_admin());
create policy "contracts admin" on public.contracts for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

revoke all on public.sites, public.standards_library, public.schedule_templates, public.briefs, public.brief_versions,
  public.approval_queue, public.vendor_profiles, public.verification_claims, public.vendor_scores, public.quotes,
  public.contracts from anon;
