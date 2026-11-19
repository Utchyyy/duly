-- Enterprise foundation: an Enterprise governs its Vendors' delivery on Duly; a Vendor runs the operations that deliver it;
-- the buyer marketplace and the open labour exchange are switched off, not removed.
--
-- The Enterprise is the buyer on the contract: it is a buyer organisation in the existing 'enterprise' segment, so every rule
-- that already works for a buyer (brief, quote, contract, visits, judging, rework, measures) works for it unchanged, and it sees
-- everything its vendors do on its sites. What this adds:
--   1. Payments off: a new 'external' payment model (invoicing stays outside Duly). The enterprise segment uses it: no price is
--      needed on a quote, and no escrow, charge or release lines are written.
--   2. A vendor roster (enterprise_vendors). An enterprise invites and accepts only vendors on its roster that are active, so work
--      starts by appointing a named vendor, not by ranking a marketplace. Duly staff add a vendor to the roster; the Enterprise
--      activates and suspends it.
--   3. Client access to a site (site_access): a Client site manager can judge the work (the same verdicts and approval as the
--      Enterprise's staff); a Client viewer can only see the record. Neither sees money, quotes or contracts.
--   4. Feature switches (app_features) that Duly staff set: closing buyer self-sign-up is enforced in the database; the rest hide
--      marketplace and shift screens in the app. Defaults are all on, so nothing changes until Duly turns them off.
--   5. Duly staff can create an Enterprise (with its owner) and a vendor organisation.

-- ---------------------------------------------------------------------------
-- 1. Payments off
-- ---------------------------------------------------------------------------
do $$
declare c text;
begin
  select conname into c from pg_constraint
   where conrelid = 'public.policies'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%payment_model%';
  if c is not null then execute format('alter table public.policies drop constraint %I', c); end if;
end $$;
alter table public.policies add constraint policies_payment_model_check
  check (payment_model in ('escrow_one_off', 'monthly_in_advance', 'invoice_terms', 'external'));

-- The enterprise segment: invoicing is outside Duly, and the Enterprise (not Duly's tier) decides which vendors it uses.
update public.policies set payment_model = 'external', min_verification_tier = 0 where segment = 'enterprise';

-- No client charges are written for a payment model that is external.
create or replace function private.refresh_client_charges(p_contract uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  c public.contracts;
  v_pol public.policies;
  v_tz text;
  v_kind public.payment_kind;
  m record;
  v_paid numeric;
  v_due timestamptz;
  v_note text;
  v_pending uuid;
begin
  select * into c from public.contracts where id = p_contract;
  if not found then return; end if;
  v_pol := private.policy_for_org(c.buyer_org_id);
  if v_pol.payment_model in ('escrow_one_off', 'external') then return; end if;
  v_kind := case when v_pol.payment_model = 'monthly_in_advance' then 'direct_debit'::public.payment_kind else 'invoice'::public.payment_kind end;
  select mk.timezone into v_tz from public.organisations o join public.markets mk on mk.code = o.market where o.id = c.buyer_org_id;

  for m in
    select date_trunc('month', j.scheduled_start at time zone v_tz)::date as period,
           count(*) filter (where j.status <> 'cancelled') as visits,
           coalesce(sum(j.value) filter (where j.status <> 'cancelled'), 0) as total
    from public.jobs j where j.contract_id = p_contract
    group by 1
  loop
    select coalesce(sum(amount), 0) into v_paid from public.payments
     where contract_id = p_contract and kind = v_kind and period = m.period and status = 'succeeded';
    select id into v_pending from public.payments
     where contract_id = p_contract and kind = v_kind and period = m.period and status = 'pending' limit 1;
    v_due := case when v_kind = 'direct_debit'
                  then greatest(now(), m.period::timestamp at time zone v_tz)
                  else ((m.period + interval '1 month')::timestamp at time zone v_tz) + make_interval(days => c.payment_terms_days) end;
    v_note := format('%s %s · %s visit%s', case when v_kind = 'direct_debit' then 'Monthly plan,' else 'Invoice,' end,
                     to_char(m.period, 'FMMonth YYYY'), m.visits, case when m.visits = 1 then '' else 's' end);
    if m.total - v_paid > 0 then
      if v_pending is null then
        insert into public.payments (contract_id, kind, amount, currency, provider, status, due_at, note, period)
        values (p_contract, v_kind, m.total - v_paid, c.currency, 'manual', 'pending', v_due, v_note, m.period);
      else
        update public.payments set amount = m.total - v_paid, note = v_note, due_at = v_due where id = v_pending;
      end if;
    elsif v_pending is not null then
      delete from public.payments where id = v_pending;
    end if;
  end loop;
end;
$$;

-- A quote under an external payment model carries no price: the vendor sends its work schedule and the Enterprise accepts it.
create or replace function public.submit_quote(p_quote uuid, p_valid_days integer default 14)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_q public.quotes;
  v_price jsonb;
  v_currency text;
  v_buyer uuid;
begin
  select * into v_q from public.quotes where id = p_quote for update;
  if not found then raise exception 'Quote not found'; end if;
  if not (private.is_vendor_staff(v_q.vendor_org_id) or private.is_platform_admin()) then
    raise exception 'Not allowed to submit this quote';
  end if;
  if v_q.status not in ('invited', 'submitted') then
    raise exception 'This quote is % and can no longer be submitted', v_q.status;
  end if;
  if not exists (select 1 from public.brief_versions where brief_id = v_q.brief_id and version = v_q.brief_version and locked_at is not null) then
    raise exception 'The brief is not locked yet';
  end if;
  select b.buyer_org_id into v_buyer from public.briefs b where b.id = v_q.brief_id;
  select m.currency into v_currency from public.organisations o join public.markets m on m.code = o.market where o.id = v_q.vendor_org_id;
  if (private.policy_for_org(v_buyer)).payment_model = 'external' then
    update public.quotes
       set lines = '[]'::jsonb, total = null, currency = v_currency,
           status = 'submitted', submitted_at = now(), valid_until = current_date + greatest(p_valid_days, 1)
     where id = p_quote;
    return '{}'::jsonb;
  end if;
  v_price := public.price_quote(v_q.brief_id, v_q.brief_version, v_q.vendor_org_id, v_q.urgency);
  update public.quotes
     set lines = v_price, total = (v_price ->> 'total')::numeric, currency = v_currency,
         status = 'submitted', submitted_at = now(), valid_until = current_date + greatest(p_valid_days, 1)
   where id = p_quote;
  return v_price;
end;
$$;

-- Approving a visit under an external payment model moves it to verified and writes no releases: money is outside Duly.
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
  update public.jobs set status = 'quality_verified', updated_at = now() where id = p_job;
  insert into public.job_events (job_id, kind, data) values (p_job, 'status_change', jsonb_build_object('to', 'quality_verified'));

  if v_pol.payment_model <> 'external' then
    v_first := round(coalesce(v_job.value, 0) * v_pol.first_release_pct / 100, 2);
    v_fee := round(coalesce(v_job.value, 0) * coalesce(v_pol.platform_fee_pct, 0) / 100, 2);
    v_balance := coalesce(v_job.value, 0) - v_first - v_fee;
    v_first_due := case v_pol.first_release_on
      when 'month_end' then date_trunc('month', now()) + interval '1 month' - interval '1 minute'
      else now() end;
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
  end if;

  perform private.recompute_vendor_score(v_job.vendor_org_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. The vendor roster
-- ---------------------------------------------------------------------------
create table public.enterprise_vendors (
  id uuid not null default gen_random_uuid() unique,
  enterprise_org_id uuid not null references public.organisations(id) on delete cascade,
  vendor_org_id uuid not null references public.organisations(id) on delete cascade,
  status text not null default 'invited' check (status in ('invited', 'active', 'suspended')),
  note text check (length(note) <= 500),
  added_by uuid default auth.uid() references auth.users(id) on delete set null,
  status_changed_by uuid references auth.users(id) on delete set null,
  status_changed_at timestamptz,
  created_at timestamptz not null default now(),
  primary key (enterprise_org_id, vendor_org_id)
);
create index enterprise_vendors_vendor_idx on public.enterprise_vendors (vendor_org_id);
create index enterprise_vendors_added_by_idx on public.enterprise_vendors (added_by);
create index enterprise_vendors_status_by_idx on public.enterprise_vendors (status_changed_by);
alter table public.enterprise_vendors enable row level security;

-- The Enterprise and the vendor see the relationship; nobody writes it directly (the functions below do).
create policy "roster visible" on public.enterprise_vendors for select to authenticated
  using (private.is_platform_admin() or private.is_member(enterprise_org_id) or private.is_vendor_staff(vendor_org_id));

create function private.is_enterprise(p_org uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.organisations o where o.id = p_org and o.kind = 'buyer' and o.segment = 'enterprise');
$$;

-- Whether a vendor may be used by a buyer: an Enterprise uses only vendors on its roster that are active; any other buyer is unaffected.
create function private.vendor_on_roster(p_buyer uuid, p_vendor uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select not private.is_enterprise(p_buyer)
      or exists (select 1 from public.enterprise_vendors ev where ev.enterprise_org_id = p_buyer and ev.vendor_org_id = p_vendor and ev.status = 'active');
$$;

create function private.vendor_allowed_for(p_buyer uuid, p_vendor uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select private.vendor_meets_tier(p_buyer, p_vendor) and private.vendor_on_roster(p_buyer, p_vendor);
$$;

-- Duly staff add a vendor to an Enterprise's roster (invited); the Enterprise then activates it.
create function public.enterprise_add_vendor(p_enterprise uuid, p_vendor uuid, p_note text default null)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not private.is_platform_admin() then raise exception 'Only Duly staff add a vendor to an Enterprise'; end if;
  if not private.is_enterprise(p_enterprise) then raise exception 'That is not an Enterprise'; end if;
  if not exists (select 1 from public.organisations o where o.id = p_vendor and o.kind = 'vendor') then raise exception 'That is not a vendor'; end if;
  insert into public.enterprise_vendors (enterprise_org_id, vendor_org_id, note) values (p_enterprise, p_vendor, nullif(trim(coalesce(p_note, '')), ''))
    on conflict (enterprise_org_id, vendor_org_id) do nothing;
end;
$$;

-- The Enterprise accepts a vendor onto its roster (active), or stops using it (suspended). A suspended vendor cannot be invited
-- or have a quote accepted; visits already booked carry on.
create function public.enterprise_set_vendor_status(p_enterprise uuid, p_vendor uuid, p_status text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not (private.has_org_role(p_enterprise, array['owner', 'approver']::public.member_role[]) or private.is_platform_admin()) then
    raise exception 'Only the Enterprise''s owner or approvers can change a vendor''s status';
  end if;
  if p_status not in ('active', 'suspended') then raise exception 'A vendor is made active or suspended'; end if;
  update public.enterprise_vendors set status = p_status, status_changed_by = (select auth.uid()), status_changed_at = now()
   where enterprise_org_id = p_enterprise and vendor_org_id = p_vendor;
  if not found then raise exception 'That vendor is not on this Enterprise''s roster'; end if;
end;
$$;

create trigger audit_enterprise_vendors after insert or update or delete on public.enterprise_vendors for each row execute function private.audit_row();

-- An Enterprise invites only roster vendors that are active (and meet its tier, which for an Enterprise is none).
drop policy "quotes invited by buyer" on public.quotes;
create policy "quotes invited by buyer" on public.quotes for insert to authenticated
  with check (
    status = 'invited'
    and exists (
      select 1 from public.briefs b
      where b.id = brief_id
        and private.has_org_role(b.buyer_org_id, array['owner', 'approver']::public.member_role[])
        and private.vendor_allowed_for(b.buyer_org_id, vendor_org_id)
    )
  );

create or replace function public.accept_quote(p_quote uuid, p_start timestamptz)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  v_q public.quotes;
  v_buyer uuid;
  v_site uuid;
  v_pol public.policies;
  v_minutes numeric;
  v_contract uuid;
  v_job uuid;
begin
  select q.* into v_q from public.quotes q where q.id = p_quote for update;
  if not found then raise exception 'Quote not found'; end if;
  select b.buyer_org_id, b.site_id into v_buyer, v_site from public.briefs b where b.id = v_q.brief_id;
  if not (private.has_org_role(v_buyer, array['owner', 'approver']::public.member_role[]) or private.is_platform_admin()) then
    raise exception 'Only an owner or approver can accept a quote';
  end if;
  if v_q.status <> 'submitted' then raise exception 'Only a submitted quote can be accepted'; end if;
  if not private.is_platform_admin() then
    if not private.vendor_meets_tier(v_buyer, v_q.vendor_org_id) then
      raise exception 'This vendor is not verified to the level your segment requires';
    end if;
    if not private.vendor_on_roster(v_buyer, v_q.vendor_org_id) then
      raise exception 'This vendor is not an active vendor on your roster';
    end if;
  end if;
  if v_q.valid_until is not null and v_q.valid_until < current_date then raise exception 'This quote has expired'; end if;
  if p_start < now() then raise exception 'Choose a start time in the future'; end if;

  v_pol := private.policy_for_org(v_buyer);
  v_minutes := greatest(private.schedule_minutes(v_q.brief_id, v_q.brief_version), 30);

  update public.quotes set status = 'accepted' where id = p_quote;
  update public.quotes set status = 'declined'
   where brief_id = v_q.brief_id and id <> p_quote and status in ('invited', 'submitted');

  insert into public.contracts (buyer_org_id, vendor_org_id, site_id, brief_id, brief_version, quote_id, status,
                                starts_on, billing, currency)
  values (v_buyer, v_q.vendor_org_id, v_site, v_q.brief_id, v_q.brief_version, p_quote, 'active',
          p_start::date, case when v_pol.payment_model = 'escrow_one_off' then 'per_job' else 'monthly' end, v_q.currency)
  returning id into v_contract;

  insert into public.jobs (buyer_org_id, vendor_org_id, site_id, brief_id, brief_version, contract_id, quote_id,
                           status, scheduled_start, scheduled_end, value, currency)
  values (v_buyer, v_q.vendor_org_id, v_site, v_q.brief_id, v_q.brief_version, v_contract, p_quote,
          'matched', p_start, p_start + make_interval(mins => v_minutes::integer), v_q.total, v_q.currency)
  returning id into v_job;

  insert into public.job_events (job_id, kind, data) values (v_job, 'status_change', jsonb_build_object('to', 'matched'));

  if v_pol.payment_model = 'escrow_one_off' then
    insert into public.payments (job_id, contract_id, kind, amount, currency, provider, status, due_at, note)
    values (v_job, v_contract, 'escrow_hold', v_q.total, v_q.currency, 'manual', 'pending', p_start,
            'Client pays into escrow before the clean');
  end if;
  return v_job;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Client access to a site
-- ---------------------------------------------------------------------------
create table public.site_access (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references public.sites(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('manager', 'viewer')),
  granted_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (site_id, user_id)
);
create index site_access_user_idx on public.site_access (user_id);
create index site_access_granted_by_idx on public.site_access (granted_by);
alter table public.site_access enable row level security;

-- You see your own access; the Enterprise that owns the site sees who has it.
create policy "site access visible" on public.site_access for select to authenticated
  using (user_id = (select auth.uid()) or private.is_platform_admin()
         or exists (select 1 from public.sites s where s.id = site_access.site_id and private.is_member(s.org_id)));

create function private.has_site_access(p_site uuid, p_roles text[])
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.site_access sa where sa.site_id = p_site and sa.user_id = (select auth.uid()) and sa.role = any (p_roles));
$$;

-- The Enterprise (its owner or approvers, or Duly) gives a person access to a site by email. They must have an account already:
-- anyone can create one by signing in, and it shows nothing until access is granted here.
create function public.grant_site_access(p_site uuid, p_email text, p_role text)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_org uuid; v_user uuid; v_id uuid;
begin
  select s.org_id into v_org from public.sites s where s.id = p_site;
  if v_org is null then raise exception 'Site not found'; end if;
  if not (private.has_org_role(v_org, array['owner', 'approver']::public.member_role[]) or private.is_platform_admin()) then
    raise exception 'Only the owner or approvers can give access to this site';
  end if;
  if p_role not in ('manager', 'viewer') then raise exception 'Access is as a manager (who can judge the work) or a viewer'; end if;
  select id into v_user from auth.users where lower(email) = lower(trim(p_email));
  if v_user is null then raise exception 'No account for %. Ask them to sign in once on Duly first.', p_email; end if;
  insert into public.site_access (site_id, user_id, role) values (p_site, v_user, p_role)
    on conflict (site_id, user_id) do update set role = excluded.role
    returning id into v_id;
  return v_id;
end;
$$;

create function public.revoke_site_access(p_site uuid, p_user uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_org uuid;
begin
  select s.org_id into v_org from public.sites s where s.id = p_site;
  if v_org is null then raise exception 'Site not found'; end if;
  if not (private.has_org_role(v_org, array['owner', 'approver']::public.member_role[]) or private.is_platform_admin()) then
    raise exception 'Only the owner or approvers can change access to this site';
  end if;
  delete from public.site_access where site_id = p_site and user_id = p_user;
end;
$$;

create trigger audit_site_access after insert or update or delete on public.site_access for each row execute function private.audit_row();

-- A Client with access to a site sees what happens there; a manager also judges the work like the Enterprise's own staff.
-- These keep the rules as they stand (vendor-side visibility needs a staff role; an operative sees only what they are rostered on)
-- and add the Client's site access.
create or replace function private.can_see_site(p_site uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select private.is_platform_admin()
    or exists (select 1 from public.sites s where s.id = p_site and private.is_member(s.org_id))
    or exists (
      select 1 from public.briefs b join public.quotes q on q.brief_id = b.id
      where b.site_id = p_site and private.is_vendor_staff(q.vendor_org_id)
    )
    or exists (select 1 from public.contracts c where c.site_id = p_site and private.is_vendor_staff(c.vendor_org_id))
    or exists (
      select 1 from public.jobs j join public.job_assignments a on a.job_id = j.id
      where j.site_id = p_site and a.user_id = (select auth.uid())
    )
    or private.has_site_access(p_site, array['manager', 'viewer']);
$$;

create or replace function private.can_see_job(p_job uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select private.is_platform_admin()
    or exists (
      select 1 from public.jobs j
      where j.id = p_job and (private.is_member(j.buyer_org_id) or private.is_vendor_staff(j.vendor_org_id)
                              or private.has_site_access(j.site_id, array['manager', 'viewer']))
    )
    or exists (select 1 from public.job_assignments a where a.job_id = p_job and a.user_id = (select auth.uid()));
$$;

create or replace function private.is_job_buyer(p_job uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.jobs j
    where j.id = p_job and (private.has_org_role(j.buyer_org_id, array['owner', 'approver']::public.member_role[])
                            or private.has_site_access(j.site_id, array['manager']))
  );
$$;

create or replace function private.can_see_brief(p_brief uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select private.is_platform_admin()
    or exists (select 1 from public.briefs b where b.id = p_brief and private.is_member(b.buyer_org_id))
    or exists (select 1 from public.quotes q where q.brief_id = p_brief and private.is_vendor_staff(q.vendor_org_id))
    or exists (select 1 from public.contracts c where c.brief_id = p_brief and private.is_vendor_staff(c.vendor_org_id))
    or exists (
      select 1 from public.jobs j join public.job_assignments a on a.job_id = j.id
      where j.brief_id = p_brief and a.user_id = (select auth.uid())
    )
    or exists (select 1 from public.briefs b where b.id = p_brief and private.has_site_access(b.site_id, array['manager', 'viewer']));
$$;

-- A Client sees the locked schedule of the work done at its site.
drop policy "work schedules visible" on public.work_schedules;
create policy "work schedules visible" on public.work_schedules for select to authenticated
  using (
    private.is_platform_admin()
    or private.is_vendor_staff(vendor_org_id)
    or (status in ('submitted', 'locked') and exists (select 1 from public.briefs b where b.id = work_schedules.brief_id and private.is_member(b.buyer_org_id)))
    or (status = 'locked' and exists (select 1 from public.jobs j join public.job_assignments a on a.job_id = j.id
          where j.quote_id = work_schedules.quote_id and a.user_id = (select auth.uid())))
    or (status = 'locked' and exists (select 1 from public.jobs j
          where j.quote_id = work_schedules.quote_id and private.has_site_access(j.site_id, array['manager', 'viewer']))));

-- For the app: whether the signed-in person may judge a visit's work (the Enterprise's staff, a Client site manager, or Duly).
create function public.can_judge_job(p_job uuid)
returns boolean language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.can_see_job(p_job) then raise exception 'Job not found'; end if;
  return private.is_job_buyer(p_job) or private.is_platform_admin();
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Feature switches
-- ---------------------------------------------------------------------------
create table public.app_features (
  key text primary key,
  enabled boolean not null default true,
  note text,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);
create index app_features_updated_by_idx on public.app_features (updated_by);
alter table public.app_features enable row level security;
create policy "features readable" on public.app_features for select to authenticated using (true);

insert into public.app_features (key, enabled, note) values
  ('buyer_signup',  true, 'Anyone can create a buyer organisation. Off: organisations are created by Duly.'),
  ('marketplace',   true, 'Buyer marketplace screens: ranked vendor directory, open invitations, town demand. Off: hidden in the app.'),
  ('shifts',        true, 'WFX shift exchange and worker pool screens. Off: hidden in the app.');

create function private.feature_on(p_key text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select coalesce((select f.enabled from public.app_features f where f.key = p_key), true);
$$;

-- Duly staff turn a switch on or off. The database enforces buyer_signup; the app hides the screens for the others.
create function public.admin_set_feature(p_key text, p_enabled boolean)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not private.is_platform_admin() then raise exception 'Only Duly staff change feature switches'; end if;
  update public.app_features set enabled = p_enabled, updated_by = (select auth.uid()), updated_at = now() where key = p_key;
  if not found then raise exception 'No feature called %', p_key; end if;
end;
$$;
create trigger audit_app_features after update on public.app_features for each row execute function private.audit_row();

create or replace function public.create_buyer_org(p_name text, p_segment text)
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
  if not private.feature_on('buyer_signup') and not private.is_platform_admin() then
    raise exception 'New accounts for buyers are by invitation';
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
-- 5. Duly staff set an organisation up
-- ---------------------------------------------------------------------------
create function public.admin_create_enterprise(p_name text, p_owner_email text)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_org uuid; v_user uuid;
begin
  if not private.is_platform_admin() then raise exception 'Only Duly staff create an Enterprise'; end if;
  if coalesce(length(trim(p_name)), 0) = 0 then raise exception 'Give the Enterprise a name'; end if;
  select id into v_user from auth.users where lower(email) = lower(trim(p_owner_email));
  if v_user is null then raise exception 'No account for %. Ask them to sign in once on Duly first.', p_owner_email; end if;
  insert into public.organisations (kind, name, segment) values ('buyer', trim(p_name), 'enterprise') returning id into v_org;
  insert into public.memberships (org_id, user_id, role) values (v_org, v_user, 'owner');
  return v_org;
end;
$$;

create function public.admin_create_vendor(p_name text, p_admin_email text)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_org uuid; v_user uuid;
begin
  if not private.is_platform_admin() then raise exception 'Only Duly staff create a vendor'; end if;
  if coalesce(length(trim(p_name)), 0) = 0 then raise exception 'Give the vendor a name'; end if;
  select id into v_user from auth.users where lower(email) = lower(trim(p_admin_email));
  if v_user is null then raise exception 'No account for %. Ask them to sign in once on Duly first.', p_admin_email; end if;
  insert into public.organisations (kind, name) values ('vendor', trim(p_name)) returning id into v_org;
  insert into public.memberships (org_id, user_id, role) values (v_org, v_user, 'vendor_admin');
  return v_org;
end;
$$;

revoke execute on function private.is_enterprise(uuid), private.vendor_on_roster(uuid, uuid), private.vendor_allowed_for(uuid, uuid),
  private.has_site_access(uuid, text[]), private.feature_on(text) from public, anon;
grant execute on function private.is_enterprise(uuid), private.vendor_on_roster(uuid, uuid), private.vendor_allowed_for(uuid, uuid),
  private.has_site_access(uuid, text[]), private.feature_on(text) to authenticated, service_role;
revoke execute on function public.enterprise_add_vendor(uuid, uuid, text), public.enterprise_set_vendor_status(uuid, uuid, text),
  public.grant_site_access(uuid, text, text), public.revoke_site_access(uuid, uuid), public.can_judge_job(uuid),
  public.admin_set_feature(text, boolean), public.admin_create_enterprise(text, text), public.admin_create_vendor(text, text) from public, anon;
grant execute on function public.enterprise_add_vendor(uuid, uuid, text), public.enterprise_set_vendor_status(uuid, uuid, text),
  public.grant_site_access(uuid, text, text), public.revoke_site_access(uuid, uuid), public.can_judge_job(uuid),
  public.admin_set_feature(text, boolean), public.admin_create_enterprise(text, text), public.admin_create_vendor(text, text) to authenticated;
