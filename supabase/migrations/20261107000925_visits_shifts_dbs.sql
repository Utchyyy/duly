-- Recurring visits, the WFX shift exchange, and worker screening.

-- Each market has its own clock, so visit times are local.
alter table public.markets add column timezone text not null default 'Europe/London';

-- ---------------------------------------------------------------------------
-- Recurring visits: generate the next weeks of jobs from the brief's visit days.
-- ---------------------------------------------------------------------------
create function public.schedule_visits(p_contract uuid, p_weeks integer default 4)
returns integer language plpgsql security definer set search_path = ''
as $$
declare
  c public.contracts;
  v public.brief_versions;
  v_total numeric;
  v_tz text;
  v_pol public.policies;
  v_minutes numeric;
  v_day date;
  v_start timestamptz;
  v_job uuid;
  n integer := 0;
begin
  select * into c from public.contracts where id = p_contract;
  if not found then raise exception 'Contract not found'; end if;
  if not (private.has_org_role(c.buyer_org_id, array['owner', 'approver']::public.member_role[])
          or private.is_vendor_staff(c.vendor_org_id) or private.is_platform_admin()) then
    raise exception 'Not allowed to schedule visits for this contract';
  end if;
  if c.status <> 'active' then raise exception 'This contract is %', c.status; end if;
  select * into v from public.brief_versions where brief_id = c.brief_id and version = c.brief_version;
  if v.preferred_days is null or cardinality(v.preferred_days) = 0 or v.preferred_start is null then
    raise exception 'This brief has no visit days and start time set';
  end if;
  select q.total into v_total from public.quotes q where q.id = c.quote_id;
  select m.timezone into v_tz from public.organisations o join public.markets m on m.code = o.market where o.id = c.buyer_org_id;
  v_pol := private.policy_for_org(c.buyer_org_id);
  v_minutes := greatest(private.schedule_minutes(c.brief_id, c.brief_version), 30);

  for v_day in
    select d::date from generate_series(greatest(current_date + 1, coalesce(c.starts_on, current_date + 1)),
                                        current_date + least(greatest(p_weeks, 1), 12) * 7, interval '1 day') d
  loop
    if lower(to_char(v_day, 'dy')) = any (v.preferred_days) then
      v_start := (v_day + v.preferred_start) at time zone v_tz;
      if not exists (
        select 1 from public.jobs j
        where j.contract_id = c.id and (j.scheduled_start at time zone v_tz)::date = v_day and j.status <> 'cancelled'
      ) then
        insert into public.jobs (buyer_org_id, vendor_org_id, site_id, brief_id, brief_version, contract_id, quote_id,
                                 status, scheduled_start, scheduled_end, value, currency)
        values (c.buyer_org_id, c.vendor_org_id, c.site_id, c.brief_id, c.brief_version, c.id, c.quote_id,
                'matched', v_start, v_start + make_interval(mins => v_minutes::integer), v_total, c.currency)
        returning id into v_job;
        insert into public.job_events (job_id, kind, data) values (v_job, 'status_change', jsonb_build_object('to', 'matched', 'recurring', true));
        if v_pol.payment_model = 'escrow_one_off' then
          insert into public.payments (job_id, contract_id, kind, amount, currency, provider, status, due_at, note)
          values (v_job, c.id, 'escrow_hold', v_total, c.currency, 'manual', 'pending', v_start, 'Client pays into escrow before the clean');
        end if;
        n := n + 1;
      end if;
    end if;
  end loop;
  return n;
end;
$$;

-- ---------------------------------------------------------------------------
-- Shift exchange: vendors offer shifts to ranked workers; workers accept.
-- ---------------------------------------------------------------------------
-- Definer helper so the shifts policy doesn't recurse through shift_events' own policy.
create function private.was_offered_shift(p_shift uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.shift_events e join public.workers w on w.id = e.worker_id
    where e.shift_id = p_shift and w.user_id = (select auth.uid())
  );
$$;
revoke execute on function private.was_offered_shift(uuid) from public, anon;
grant execute on function private.was_offered_shift(uuid) to authenticated, service_role;

drop policy "shifts visible" on public.shifts;
create policy "shifts visible" on public.shifts for select to authenticated
  using (private.is_member(vendor_org_id) or private.is_platform_admin()
         or private.is_worker_self(filled_by)
         or (status = 'open' and private.has_worker_record())
         or private.was_offered_shift(id));

create function public.offer_shift(p_shift uuid, p_worker uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare s public.shifts;
begin
  select * into s from public.shifts where id = p_shift for update;
  if not found then raise exception 'Shift not found'; end if;
  if not (private.is_vendor_staff(s.vendor_org_id) or private.is_platform_admin()) then raise exception 'Not allowed'; end if;
  if s.status not in ('open', 'offered') then raise exception 'This shift is %', s.status; end if;
  if not exists (select 1 from public.workers where id = p_worker) then raise exception 'Worker not found'; end if;
  if exists (select 1 from public.shift_events where shift_id = p_shift and worker_id = p_worker and event_type = 'offered') then
    raise exception 'Already offered to this worker';
  end if;
  insert into public.shift_events (shift_id, worker_id, event_type) values (p_shift, p_worker, 'offered');
  update public.shifts set status = 'offered' where id = p_shift and status = 'open';
end;
$$;

create function public.respond_to_shift(p_shift uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  s public.shifts;
  v_worker uuid;
  v_user uuid;
begin
  select id, user_id into v_worker, v_user from public.workers where user_id = (select auth.uid());
  if v_worker is null then raise exception 'Join Duly Crew first'; end if;
  select * into s from public.shifts where id = p_shift for update;
  if not found then raise exception 'Shift not found'; end if;
  if not exists (select 1 from public.shift_events where shift_id = p_shift and worker_id = v_worker and event_type = 'offered') then
    raise exception 'This shift was not offered to you';
  end if;
  if not p_accept then
    insert into public.shift_events (shift_id, worker_id, event_type) values (p_shift, v_worker, 'declined');
    return;
  end if;
  if s.status not in ('open', 'offered') or s.filled_by is not null then
    raise exception 'Sorry, this shift has already been filled';
  end if;
  update public.shifts set status = 'filled', filled_by = v_worker where id = p_shift;
  insert into public.shift_events (shift_id, worker_id, event_type) values (p_shift, v_worker, 'accepted');
  if s.job_id is not null then
    insert into public.job_assignments (job_id, user_id, role)
    values (s.job_id, v_user, case when exists (select 1 from public.job_assignments where job_id = s.job_id) then 'crew' else 'lead' end)
    on conflict do nothing;
  end if;
end;
$$;

-- A worker can leave an employer; only the employer's staff (or Duly) can attach a worker to a company.
create or replace function private.protect_worker_fields()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.dbs_cleared is distinct from old.dbs_cleared and not private.is_platform_admin()
     and current_setting('duly.dbs_sync', true) is distinct from 'on' then
    raise exception 'Only the DBS workflow can change clearance';
  end if;
  if new.vendor_org_id is distinct from old.vendor_org_id and new.vendor_org_id is not null
     and not (private.is_platform_admin() or private.is_vendor_staff(new.vendor_org_id)) then
    raise exception 'Only the company can add you to its team';
  end if;
  return new;
end;
$$;

-- WIIx screening score is computed, never typed in.
create function private.compute_wiix_score()
returns trigger language plpgsql set search_path = ''
as $$
begin
  new.wiix_score := round((coalesce(new.reliability, 0) + coalesce(new.shift_fit, 0) + coalesce(new.capability, 0)
                           + coalesce(new.commute_tolerance, 0))::numeric / 4 * 20, 2);
  new.screened_at := now();
  return new;
end;
$$;
create trigger wiix_screens_score before insert or update on public.wiix_screens
  for each row execute function private.compute_wiix_score();

revoke execute on function public.schedule_visits(uuid, integer), public.offer_shift(uuid, uuid), public.respond_to_shift(uuid, boolean) from public, anon;
grant execute on function public.schedule_visits(uuid, integer), public.offer_shift(uuid, uuid), public.respond_to_shift(uuid, boolean) to authenticated;
revoke execute on function private.compute_wiix_score() from public, anon, authenticated;
