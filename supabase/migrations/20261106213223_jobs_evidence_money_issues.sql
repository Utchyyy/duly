-- Jobs, evidence, review results, the payments ledger, issues, and evidence storage.

create type public.job_status as enum (
  'requested', 'matched', 'en_route', 'on_site', 'in_progress',
  'completed', 'quality_verified', 'paid', 'cancelled', 'disputed'
);

create table public.jobs (
  id uuid primary key default gen_random_uuid(),
  buyer_org_id uuid not null references public.organisations(id) on delete cascade,
  vendor_org_id uuid not null references public.organisations(id) on delete cascade,
  site_id uuid not null references public.sites(id) on delete cascade,
  brief_id uuid not null,
  brief_version integer not null,
  contract_id uuid references public.contracts(id) on delete set null,
  quote_id uuid references public.quotes(id) on delete set null,
  status public.job_status not null default 'requested',
  scheduled_start timestamptz not null,
  scheduled_end timestamptz not null,
  value numeric(10,2),
  currency text not null default 'GBP',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (scheduled_end > scheduled_start),
  foreign key (brief_id, brief_version) references public.brief_versions(brief_id, version)
);
create index jobs_buyer_idx on public.jobs (buyer_org_id);
create index jobs_vendor_idx on public.jobs (vendor_org_id, scheduled_start);
create index jobs_site_idx on public.jobs (site_id);
create index jobs_brief_idx on public.jobs (brief_id, brief_version);
create index jobs_contract_idx on public.jobs (contract_id);
create index jobs_quote_idx on public.jobs (quote_id);

create table public.job_assignments (
  job_id uuid not null references public.jobs(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'crew' check (role in ('lead', 'crew')),
  created_at timestamptz not null default now(),
  primary key (job_id, user_id)
);
create index job_assignments_user_idx on public.job_assignments (user_id);

-- Append-only log: check-in, check-out, status changes, alerts.
create table public.job_events (
  id bigint generated always as identity primary key,
  job_id uuid not null references public.jobs(id) on delete cascade,
  kind text not null check (kind in ('check_in', 'check_out', 'status_change', 'late_alert', 'skipped_area', 'note', 'robot_handoff')),
  actor uuid default auth.uid() references auth.users(id) on delete set null,
  at timestamptz not null default now(),
  lat numeric(9,6),
  lng numeric(9,6),
  within_geofence boolean,
  data jsonb not null default '{}'::jsonb
);
create index job_events_job_idx on public.job_events (job_id, at);
create index job_events_actor_idx on public.job_events (actor);

-- Evidence can be added, never edited or removed.
create type public.evidence_kind as enum ('photo_before', 'photo_after', 'robot_log', 'other');

create table public.evidence (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs(id) on delete cascade,
  area_id text not null,
  kind public.evidence_kind not null,
  storage_path text not null,
  taken_at timestamptz,
  uploaded_by uuid default auth.uid() references auth.users(id) on delete set null,
  lat numeric(9,6),
  lng numeric(9,6),
  within_geofence boolean,
  created_at timestamptz not null default now()
);
create index evidence_job_idx on public.evidence (job_id, area_id);
create index evidence_uploaded_by_idx on public.evidence (uploaded_by);

-- One row per standard per area per job: ticked by the operative, judged by the buyer.
create table public.area_results (
  job_id uuid not null references public.jobs(id) on delete cascade,
  area_id text not null,
  standard_id text not null,
  done_by_operative boolean not null default false,
  done_at timestamptz,
  done_by uuid references auth.users(id) on delete set null,
  verdict text check (verdict in ('met', 'not_met')),
  verdict_at timestamptz,
  verdict_by uuid references auth.users(id) on delete set null,
  primary key (job_id, area_id, standard_id)
);
create index area_results_done_by_idx on public.area_results (done_by);
create index area_results_verdict_by_idx on public.area_results (verdict_by);

-- Payments ledger: written only by the server (payment webhooks), never by the app directly.
create type public.payment_kind as enum ('escrow_hold', 'release', 'refund', 'payout', 'direct_debit', 'service_credit', 'platform_fee');

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  job_id uuid references public.jobs(id) on delete restrict,
  contract_id uuid references public.contracts(id) on delete restrict,
  kind public.payment_kind not null,
  amount numeric(10,2) not null,
  currency text not null default 'GBP',
  provider text not null check (provider in ('stripe', 'gocardless', 'manual')),
  provider_ref text,
  status text not null default 'pending' check (status in ('pending', 'succeeded', 'failed', 'cancelled')),
  created_at timestamptz not null default now(),
  check (job_id is not null or contract_id is not null)
);
create index payments_job_idx on public.payments (job_id);
create index payments_contract_idx on public.payments (contract_id);

create type public.issue_kind as enum ('quality', 'damage', 'conduct', 'no_show', 'access', 'safeguarding', 'other');
create type public.issue_status as enum ('open', 'vendor_fix', 'partial_refund', 'mediation', 'resolved');

create table public.issues (
  id uuid primary key default gen_random_uuid(),
  job_id uuid references public.jobs(id) on delete set null,
  site_id uuid references public.sites(id) on delete set null,
  raised_by uuid not null default auth.uid() references auth.users(id) on delete set null,
  kind public.issue_kind not null,
  description text not null,
  status public.issue_status not null default 'open',
  sla_due_at timestamptz,
  resolution text,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  check (job_id is not null or site_id is not null)
);
create index issues_job_idx on public.issues (job_id);
create index issues_site_idx on public.issues (site_id);
create index issues_raised_by_idx on public.issues (raised_by);

-- ---------------------------------------------------------------------------
-- Access helpers
-- ---------------------------------------------------------------------------
create function private.can_see_job(p_job uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select private.is_platform_admin()
    or exists (
      select 1 from public.jobs j
      where j.id = p_job and (private.is_member(j.buyer_org_id) or private.is_member(j.vendor_org_id))
    )
    or exists (select 1 from public.job_assignments a where a.job_id = p_job and a.user_id = (select auth.uid()));
$$;

create function private.can_work_job(p_job uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.job_assignments a where a.job_id = p_job and a.user_id = (select auth.uid()))
    or exists (select 1 from public.jobs j where j.id = p_job and private.is_vendor_staff(j.vendor_org_id))
    or private.is_platform_admin();
$$;

create function private.is_job_buyer(p_job uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.jobs j
    where j.id = p_job and private.has_org_role(j.buyer_org_id, array['owner', 'approver']::public.member_role[])
  );
$$;

-- Operatives can see the sites of jobs they're rostered on.
create or replace function private.can_see_site(p_site uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select private.is_platform_admin()
    or exists (select 1 from public.sites s where s.id = p_site and private.is_member(s.org_id))
    or exists (
      select 1 from public.briefs b join public.quotes q on q.brief_id = b.id
      where b.site_id = p_site and private.is_member(q.vendor_org_id)
    )
    or exists (select 1 from public.contracts c where c.site_id = p_site and private.is_member(c.vendor_org_id))
    or exists (
      select 1 from public.jobs j join public.job_assignments a on a.job_id = j.id
      where j.site_id = p_site and a.user_id = (select auth.uid())
    );
$$;

create or replace function private.can_see_brief(p_brief uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select private.is_platform_admin()
    or exists (select 1 from public.briefs b where b.id = p_brief and private.is_member(b.buyer_org_id))
    or exists (select 1 from public.quotes q where q.brief_id = p_brief and private.is_member(q.vendor_org_id))
    or exists (select 1 from public.contracts c where c.brief_id = p_brief and private.is_member(c.vendor_org_id))
    or exists (
      select 1 from public.jobs j join public.job_assignments a on a.job_id = j.id
      where j.brief_id = p_brief and a.user_id = (select auth.uid())
    );
$$;

revoke execute on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated, service_role;
revoke execute on function private.handle_new_user(), private.protect_locked_brief_version() from authenticated;

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------
alter table public.jobs enable row level security;
alter table public.job_assignments enable row level security;
alter table public.job_events enable row level security;
alter table public.evidence enable row level security;
alter table public.area_results enable row level security;
alter table public.payments enable row level security;
alter table public.issues enable row level security;

create policy "jobs visible" on public.jobs for select to authenticated using (private.can_see_job(id));
create policy "jobs managed by vendor" on public.jobs for update to authenticated
  using (private.is_vendor_staff(vendor_org_id) or private.is_platform_admin())
  with check (private.is_vendor_staff(vendor_org_id) or private.is_platform_admin());
create policy "jobs created by vendor or admin" on public.jobs for insert to authenticated
  with check (private.is_vendor_staff(vendor_org_id) or private.is_platform_admin());
create policy "jobs deleted by admin" on public.jobs for delete to authenticated using (private.is_platform_admin());

create policy "assignments visible" on public.job_assignments for select to authenticated using (private.can_see_job(job_id));
create policy "assignments managed by vendor" on public.job_assignments for all to authenticated
  using (exists (select 1 from public.jobs j where j.id = job_id and private.is_vendor_staff(j.vendor_org_id)) or private.is_platform_admin())
  with check (exists (select 1 from public.jobs j where j.id = job_id and private.is_vendor_staff(j.vendor_org_id)) or private.is_platform_admin());

create policy "events visible" on public.job_events for select to authenticated using (private.can_see_job(job_id));
create policy "events added by people on the job" on public.job_events for insert to authenticated
  with check (actor = (select auth.uid()) and private.can_see_job(job_id));

create policy "evidence visible" on public.evidence for select to authenticated using (private.can_see_job(job_id));
create policy "evidence added by crew" on public.evidence for insert to authenticated
  with check (uploaded_by = (select auth.uid()) and private.can_work_job(job_id));

create policy "results visible" on public.area_results for select to authenticated using (private.can_see_job(job_id));
create policy "results ticked by crew" on public.area_results for insert to authenticated
  with check (private.can_work_job(job_id) and verdict is null);
create policy "results updated by crew or buyer" on public.area_results for update to authenticated
  using (private.can_work_job(job_id) or private.is_job_buyer(job_id))
  with check (private.can_work_job(job_id) or private.is_job_buyer(job_id));

create policy "payments visible to the parties" on public.payments for select to authenticated
  using (
    private.is_platform_admin()
    or (job_id is not null and exists (
      select 1 from public.jobs j where j.id = job_id and (private.is_member(j.buyer_org_id) or private.has_org_role(j.vendor_org_id, array['vendor_admin']::public.member_role[]))
    ))
    or (contract_id is not null and exists (
      select 1 from public.contracts c where c.id = contract_id and (private.is_member(c.buyer_org_id) or private.has_org_role(c.vendor_org_id, array['vendor_admin']::public.member_role[]))
    ))
  );

-- Safeguarding reports are visible only to the person who raised them and platform admins.
create policy "issues visible" on public.issues for select to authenticated
  using (
    raised_by = (select auth.uid())
    or private.is_platform_admin()
    or (kind <> 'safeguarding' and (
      (job_id is not null and private.can_see_job(job_id))
      or (site_id is not null and private.can_see_site(site_id))
    ))
  );
create policy "issues raised by people involved" on public.issues for insert to authenticated
  with check (
    raised_by = (select auth.uid())
    and ((job_id is not null and private.can_see_job(job_id)) or (site_id is not null and private.can_see_site(site_id)))
  );
create policy "issues worked by parties" on public.issues for update to authenticated
  using (private.is_platform_admin() or (kind <> 'safeguarding' and job_id is not null and private.can_see_job(job_id)))
  with check (private.is_platform_admin() or (kind <> 'safeguarding' and job_id is not null and private.can_see_job(job_id)));

revoke all on public.jobs, public.job_assignments, public.job_events, public.evidence, public.area_results,
  public.payments, public.issues from anon;
revoke insert, update, delete on public.payments from authenticated;

-- ---------------------------------------------------------------------------
-- Evidence storage: private bucket, files stored under <job_id>/...
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('evidence', 'evidence', false, 15728640, array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/json'])
on conflict (id) do nothing;

create policy "evidence files readable by job parties" on storage.objects for select to authenticated
  using (bucket_id = 'evidence' and private.can_see_job(((storage.foldername(name))[1])::uuid));
create policy "evidence files uploaded by crew" on storage.objects for insert to authenticated
  with check (bucket_id = 'evidence' and private.can_work_job(((storage.foldername(name))[1])::uuid));
