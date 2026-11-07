-- Workflow: quotes -> booking -> check-in -> completion -> review -> payment ledger -> scores.
-- Every state change that matters goes through a function here, so the app cannot skip a step
-- or set a price, a verdict or a verification tier it isn't entitled to.

-- ---------------------------------------------------------------------------
-- Security fixes found while building the workflow
-- ---------------------------------------------------------------------------

-- An owner or vendor admin must not be able to grant platform_admin.
drop policy "memberships managed" on public.memberships;
create policy "memberships managed" on public.memberships for all to authenticated
  using (private.has_org_role(org_id, array['owner', 'vendor_admin']::public.member_role[]) or private.is_platform_admin())
  with check (
    private.is_platform_admin()
    or (private.has_org_role(org_id, array['owner', 'vendor_admin']::public.member_role[]) and role <> 'platform_admin')
  );

-- Only platform admins change an organisation's kind, market or verification tier.
create function private.protect_org_fields()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if (new.verification_tier is distinct from old.verification_tier
      or new.kind is distinct from old.kind
      or new.market is distinct from old.market)
     and not private.is_platform_admin() then
    raise exception 'Only Duly can change verification tier, kind or market';
  end if;
  return new;
end;
$$;
create trigger organisations_protect_fields before update on public.organisations
  for each row execute function private.protect_org_fields();

-- Crew tick standards; only the buyer (or an admin) gives the verdict.
create function private.protect_area_result_fields()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if (tg_op = 'INSERT' and new.verdict is not null)
     or (tg_op = 'UPDATE' and (new.verdict is distinct from old.verdict)) then
    if not (private.is_job_buyer(new.job_id) or private.is_platform_admin()) then
      raise exception 'Only the client can mark a standard met or not met';
    end if;
    new.verdict_at := now();
    new.verdict_by := (select auth.uid());
  end if;
  if tg_op = 'UPDATE' and (new.done_by_operative is distinct from old.done_by_operative) then
    if not private.can_work_job(new.job_id) then
      raise exception 'Only the crew can tick a standard';
    end if;
  end if;
  if new.done_by_operative and (tg_op = 'INSERT' or not old.done_by_operative) then
    new.done_at := now();
    new.done_by := (select auth.uid());
  end if;
  return new;
end;
$$;
create trigger area_results_protect before insert or update on public.area_results
  for each row execute function private.protect_area_result_fields();

-- Geofence on evidence is worked out by the database, not trusted from the phone.
create function private.evidence_geofence()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  v_lat numeric; v_lng numeric; v_fence integer;
begin
  select s.lat, s.lng, s.geofence_m into v_lat, v_lng, v_fence
  from public.jobs j join public.sites s on s.id = j.site_id where j.id = new.job_id;
  new.within_geofence := case
    when v_lat is null or new.lat is null then null
    else public.haversine_km(v_lat, v_lng, new.lat, new.lng) * 1000 <= v_fence
  end;
  new.uploaded_by := (select auth.uid());
  return new;
end;
$$;
create trigger evidence_set_geofence before insert on public.evidence
  for each row execute function private.evidence_geofence();

-- Status, value and parties of a job change only through the workflow functions (which run as the
-- function owner), never by a direct update from the app.
create function private.protect_job_fields()
returns trigger language plpgsql set search_path = ''   -- invoker on purpose: current_user tells us who called
as $$
begin
  if current_user = 'authenticated'
     and (new.status is distinct from old.status or new.value is distinct from old.value
          or new.buyer_org_id is distinct from old.buyer_org_id or new.vendor_org_id is distinct from old.vendor_org_id
          or new.brief_id is distinct from old.brief_id or new.brief_version is distinct from old.brief_version)
     and not private.is_platform_admin() then
    raise exception 'Job status and value change through the workflow only';
  end if;
  return new;
end;
$$;
create trigger jobs_protect_fields before update on public.jobs
  for each row execute function private.protect_job_fields();

-- Check-ins, check-outs and status changes are written by the workflow functions only.
drop policy "events added by people on the job" on public.job_events;
create policy "events added by people on the job" on public.job_events for insert to authenticated
  with check (actor = (select auth.uid()) and private.can_see_job(job_id)
              and kind in ('note', 'late_alert', 'skipped_area', 'robot_handoff'));

-- Vendors change quotes only through submit_quote / decline_quote, so the price is always computed.
drop policy "quotes priced by vendor" on public.quotes;

-- ---------------------------------------------------------------------------
-- Ledger: when each movement is due, and a note
-- ---------------------------------------------------------------------------
alter table public.payments add column due_at timestamptz, add column note text, add column paid_at timestamptz;
create index payments_due_idx on public.payments (status, due_at);

-- Vendors without a rate can't be priced, so they don't appear in ranked results.
create or replace function public.rank_vendors(p_site uuid)
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
      and vp.hourly_rate is not null
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

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
create function private.policy_for_org(p_org uuid)
returns public.policies language sql stable security definer set search_path = ''
as $$
  select p.* from public.organisations o
  join public.policies p on p.market = o.market and p.segment = coalesce(o.segment, 'homeowner')
  where o.id = p_org;
$$;

create function private.schedule_minutes(p_brief uuid, p_version integer)
returns numeric language sql stable security definer set search_path = ''
as $$
  select coalesce(sum(coalesce((a ->> 'minutes')::numeric, 0)), 0)
  from public.brief_versions bv, jsonb_array_elements(bv.schedule) sec, jsonb_array_elements(sec -> 'areas') a
  where bv.brief_id = p_brief and bv.version = p_version;
$$;

-- ---------------------------------------------------------------------------
-- Quotes
-- ---------------------------------------------------------------------------
create function public.submit_quote(p_quote uuid, p_valid_days integer default 14)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_q public.quotes;
  v_price jsonb;
  v_currency text;
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
  v_price := public.price_quote(v_q.brief_id, v_q.brief_version, v_q.vendor_org_id, v_q.urgency);
  select m.currency into v_currency from public.organisations o join public.markets m on m.code = o.market where o.id = v_q.vendor_org_id;
  update public.quotes
     set lines = v_price, total = (v_price ->> 'total')::numeric, currency = v_currency,
         status = 'submitted', submitted_at = now(), valid_until = current_date + greatest(p_valid_days, 1)
   where id = p_quote;
  return v_price;
end;
$$;

create function public.decline_quote(p_quote uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_q public.quotes;
begin
  select * into v_q from public.quotes where id = p_quote for update;
  if not found then raise exception 'Quote not found'; end if;
  if not (private.is_vendor_staff(v_q.vendor_org_id) or private.is_platform_admin()) then
    raise exception 'Not allowed';
  end if;
  if v_q.status not in ('invited', 'submitted') then raise exception 'This quote is already %', v_q.status; end if;
  update public.quotes set status = case when v_q.status = 'invited' then 'declined'::public.quote_status else 'withdrawn'::public.quote_status end
   where id = p_quote;
end;
$$;

-- The client accepts one quote and picks a start time: this creates the contract, the first job
-- and (for escrow segments) the payment that must be held before work starts.
create function public.accept_quote(p_quote uuid, p_start timestamptz)
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
-- On the job
-- ---------------------------------------------------------------------------
create function public.check_in(p_job uuid, p_lat numeric, p_lng numeric)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_status public.job_status;
  v_start timestamptz;
  v_lat numeric; v_lng numeric; v_fence integer;
  v_within boolean;
  v_late integer;
begin
  if not private.can_work_job(p_job) then raise exception 'You are not on this job'; end if;
  select j.status, j.scheduled_start, s.lat, s.lng, s.geofence_m
    into v_status, v_start, v_lat, v_lng, v_fence
  from public.jobs j join public.sites s on s.id = j.site_id where j.id = p_job for update of j;
  if v_status not in ('matched', 'en_route', 'on_site') then
    raise exception 'This job is % and cannot be checked into', v_status;
  end if;
  v_within := case when v_lat is null or p_lat is null then null
                   else public.haversine_km(v_lat, v_lng, p_lat, p_lng) * 1000 <= v_fence end;
  v_late := greatest(0, floor(extract(epoch from (now() - v_start)) / 60))::integer;
  insert into public.job_events (job_id, kind, lat, lng, within_geofence, data)
  values (p_job, 'check_in', p_lat, p_lng, v_within, jsonb_build_object('late_minutes', v_late));
  update public.jobs set status = 'in_progress', updated_at = now() where id = p_job;
  return jsonb_build_object('within_geofence', v_within, 'late_minutes', v_late);
end;
$$;

create function public.complete_job(p_job uuid, p_lat numeric default null, p_lng numeric default null)
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

  select s.lat, s.lng, s.geofence_m into v_lat, v_lng, v_fence from public.sites s where s.id = v_job.site_id;
  insert into public.job_events (job_id, kind, lat, lng, within_geofence)
  values (p_job, 'check_out', p_lat, p_lng,
          case when v_lat is null or p_lat is null then null
               else public.haversine_km(v_lat, v_lng, p_lat, p_lng) * 1000 <= v_fence end);
  update public.jobs set status = 'completed', updated_at = now() where id = p_job;
end;
$$;

-- ---------------------------------------------------------------------------
-- Scores: deterministic, from real jobs only
-- ---------------------------------------------------------------------------
create function private.recompute_vendor_score(p_vendor uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_w jsonb;
  v_tier smallint;
  v_met numeric; v_judged numeric;
  v_ontime numeric; v_checked numeric;
  v_done numeric; v_disputed numeric;
  v_buyers numeric; v_repeat numeric;
  r_met numeric; r_on numeric; r_disp numeric; r_rep numeric;
begin
  select coalesce(p.ranking_weights, '{"standards_met":0.4,"on_time":0.2,"dispute_free":0.15,"repeat_clients":0.1,"verification":0.15}'::jsonb),
         o.verification_tier
    into v_w, v_tier
  from public.organisations o
  left join public.policies p on p.market = o.market and p.segment = coalesce(o.segment, 'sme')
  where o.id = p_vendor;

  select count(*) filter (where ar.verdict = 'met'), count(*) filter (where ar.verdict is not null)
    into v_met, v_judged
  from public.area_results ar join public.jobs j on j.id = ar.job_id where j.vendor_org_id = p_vendor;

  select count(*) filter (where ci.at <= j.scheduled_start + make_interval(mins => coalesce(bv.lateness_tolerance_min, 15))),
         count(ci.at)
    into v_ontime, v_checked
  from public.jobs j
  join public.brief_versions bv on bv.brief_id = j.brief_id and bv.version = j.brief_version
  left join lateral (select min(e.at) as at from public.job_events e where e.job_id = j.id and e.kind = 'check_in') ci on true
  where j.vendor_org_id = p_vendor and ci.at is not null;

  select count(*) filter (where j.status in ('completed', 'quality_verified', 'paid', 'disputed')),
         count(*) filter (where exists (select 1 from public.issues i where i.job_id = j.id and i.kind <> 'safeguarding'))
    into v_done, v_disputed
  from public.jobs j where j.vendor_org_id = p_vendor;

  select count(*), count(*) filter (where n >= 2) into v_buyers, v_repeat
  from (select buyer_org_id, count(*) n from public.jobs
        where vendor_org_id = p_vendor and status in ('quality_verified', 'paid') group by buyer_org_id) b;

  r_met := case when v_judged > 0 then v_met / v_judged end;
  r_on := case when v_checked > 0 then v_ontime / v_checked end;
  r_disp := case when v_done > 0 then v_disputed / v_done end;
  r_rep := case when v_buyers > 0 then v_repeat / v_buyers end;

  insert into public.vendor_scores (org_id, quality_score, standards_met_rate, on_time_rate, dispute_rate,
                                    repeat_client_rate, jobs_completed, computed_at)
  values (
    p_vendor,
    round(100 * (
      coalesce((v_w ->> 'standards_met')::numeric, 0) * coalesce(r_met, 0)
      + coalesce((v_w ->> 'on_time')::numeric, 0) * coalesce(r_on, 0)
      + coalesce((v_w ->> 'dispute_free')::numeric, 0) * (1 - coalesce(r_disp, 0))
      + coalesce((v_w ->> 'repeat_clients')::numeric, 0) * coalesce(r_rep, 0)
      + coalesce((v_w ->> 'verification')::numeric, 0) * (v_tier::numeric / 3)
    ), 2),
    round(100 * r_met, 2), round(100 * r_on, 2), round(100 * r_disp, 2), round(100 * r_rep, 2),
    (select count(*) from public.jobs where vendor_org_id = p_vendor and status in ('quality_verified', 'paid')),
    now()
  )
  on conflict (org_id) do update set
    quality_score = excluded.quality_score, standards_met_rate = excluded.standards_met_rate,
    on_time_rate = excluded.on_time_rate, dispute_rate = excluded.dispute_rate,
    repeat_client_rate = excluded.repeat_client_rate, jobs_completed = excluded.jobs_completed,
    computed_at = excluded.computed_at;
end;
$$;

-- ---------------------------------------------------------------------------
-- Approval and the payment schedule (from policies)
-- ---------------------------------------------------------------------------
create function public.approve_job(p_job uuid)
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
  if exists (select 1 from public.area_results where job_id = p_job and verdict is null) then
    raise exception 'Mark every standard met or not met first';
  end if;
  if exists (select 1 from public.area_results where job_id = p_job and verdict = 'not_met') then
    raise exception 'Some standards were not met: report an issue so the vendor can put it right';
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

-- Pilot payments are made by bank transfer and recorded here by Duly staff.
create function public.mark_payment_paid(p_payment uuid, p_reference text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_p public.payments;
  v_status public.job_status;
begin
  if not private.is_platform_admin() then raise exception 'Only Duly staff can record payments'; end if;
  select * into v_p from public.payments where id = p_payment for update;
  if not found then raise exception 'Payment not found'; end if;
  if v_p.status <> 'pending' then raise exception 'This payment is already %', v_p.status; end if;
  if v_p.job_id is not null then
    select status into v_status from public.jobs where id = v_p.job_id;
    if v_p.kind in ('release', 'platform_fee') and v_status = 'disputed' then
      raise exception 'This job has an open issue: resolve it before releasing money';
    end if;
    if v_p.kind in ('release', 'platform_fee') and v_p.due_at > now() then
      raise exception 'Not due until %', to_char(v_p.due_at at time zone 'Europe/London', 'DD Mon HH24:MI');
    end if;
  end if;
  update public.payments set status = 'succeeded', paid_at = now(), provider_ref = nullif(trim(p_reference), '')
   where id = p_payment;
  if v_p.job_id is not null and not exists (
    select 1 from public.payments where job_id = v_p.job_id and kind in ('release', 'platform_fee') and status = 'pending'
  ) and exists (select 1 from public.payments where job_id = v_p.job_id and kind = 'release') then
    update public.jobs set status = 'paid', updated_at = now() where id = v_p.job_id and status = 'quality_verified';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Issues hold the money: a report puts the job into dispute until it's resolved.
-- ---------------------------------------------------------------------------
create function private.issue_opened()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare v_hours smallint;
begin
  select coalesce(c.sla_response_hours, 24) into v_hours
  from public.jobs j left join public.contracts c on c.id = j.contract_id where j.id = new.job_id;
  new.sla_due_at := now() + make_interval(hours => coalesce(v_hours, 24));
  new.raised_by := (select auth.uid());
  new.status := 'open';
  return new;
end;
$$;
create trigger issues_before_insert before insert on public.issues
  for each row execute function private.issue_opened();

create function private.issue_after_change()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.job_id is null then
    return null;
  end if;
  if new.status <> 'resolved' then
    update public.jobs set status = 'disputed', updated_at = now()
     where id = new.job_id and status in ('completed', 'quality_verified');
  elsif not exists (select 1 from public.issues where job_id = new.job_id and status <> 'resolved') then
    -- Back to where it was: review if not yet approved, otherwise approved (money can then be released).
    update public.jobs set status = case when exists (select 1 from public.payments p where p.job_id = new.job_id and p.kind = 'release')
                                         then 'quality_verified'::public.job_status else 'completed'::public.job_status end,
                           updated_at = now()
     where id = new.job_id and status = 'disputed';
  end if;
  perform private.recompute_vendor_score(j.vendor_org_id) from public.jobs j where j.id = new.job_id;
  return null;
end;
$$;
create trigger issues_after_change after insert or update on public.issues
  for each row execute function private.issue_after_change();

create function private.issue_stamp_resolved()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.status = 'resolved' and old.status <> 'resolved' then
    -- Only the person who raised it, or Duly, can close it: the vendor can't close a complaint against itself.
    if not (old.raised_by = (select auth.uid()) or private.is_platform_admin()) then
      raise exception 'Only the person who reported this, or Duly, can mark it resolved';
    end if;
    new.resolved_at := now();
  end if;
  return new;
end;
$$;
-- (security definer so it can check admin status)
create trigger issues_stamp_resolved before update on public.issues
  for each row execute function private.issue_stamp_resolved();

-- ---------------------------------------------------------------------------
-- Admin: add an existing account to an organisation by email
-- ---------------------------------------------------------------------------
create function public.admin_add_member(p_email text, p_org uuid, p_role public.member_role)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_user uuid;
begin
  if not private.is_platform_admin() then raise exception 'Only Duly staff can add members'; end if;
  select id into v_user from auth.users where lower(email) = lower(trim(p_email));
  if v_user is null then
    raise exception 'No account for %. Ask them to sign in once on Duly first.', p_email;
  end if;
  insert into public.memberships (org_id, user_id, role) values (p_org, v_user, p_role) on conflict do nothing;
  return v_user;
end;
$$;

-- Members' emails, for the people screens (profiles hold names only).
create function public.org_member_emails(p_org uuid)
returns table (user_id uuid, email text, full_name text, role public.member_role)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
begin
  if not (private.is_member(p_org) or private.is_platform_admin()) then raise exception 'Not allowed'; end if;
  return query
  select m.user_id, u.email::text, p.full_name, m.role
  from public.memberships m
  join auth.users u on u.id = m.user_id
  left join public.profiles p on p.id = m.user_id
  where m.org_id = p_org
  order by m.role, u.email;
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on all functions in schema private from public, anon;
grant execute on function private.policy_for_org(uuid), private.schedule_minutes(uuid, integer) to authenticated, service_role;
grant execute on function private.protect_job_fields() to authenticated;
revoke execute on function private.recompute_vendor_score(uuid), private.protect_org_fields(), private.protect_area_result_fields(),
  private.evidence_geofence(), private.issue_opened(), private.issue_after_change(), private.issue_stamp_resolved() from authenticated;

revoke execute on function public.submit_quote(uuid, integer), public.decline_quote(uuid), public.accept_quote(uuid, timestamptz),
  public.check_in(uuid, numeric, numeric), public.complete_job(uuid, numeric, numeric), public.approve_job(uuid),
  public.mark_payment_paid(uuid, text), public.admin_add_member(text, uuid, public.member_role),
  public.org_member_emails(uuid) from public, anon;
grant execute on function public.submit_quote(uuid, integer), public.decline_quote(uuid), public.accept_quote(uuid, timestamptz),
  public.check_in(uuid, numeric, numeric), public.complete_job(uuid, numeric, numeric), public.approve_job(uuid),
  public.mark_payment_paid(uuid, text), public.admin_add_member(text, uuid, public.member_role),
  public.org_member_emails(uuid) to authenticated;
