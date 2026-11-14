-- Rework visits: a complaint on a cleaning area becomes a planned visit to put that area right.
--
-- A rework visit is a job linked to the complaint (jobs.rework_of_issue). It has no contract, no price and no payment: the
-- original visit was already paid for. Its checklist is the one cleaning area the complaint named, whatever weekday the visit
-- falls on, and the crew do it with the same check-in, tick, photo and complete steps as any visit. The vendor books it
-- (book_rework); the client who reported the problem then accepts the area or says it is still not right (review_rework).
-- Accepting resolves the complaint and puts the area right on the original visit, so that visit can be approved and its money
-- released as normal. Not accepting hands the complaint to Duly (mediation). Vendors cannot close a complaint against themselves.
-- Rework visits are left out of a vendor's own rates (on time, right first time, score) so that putting a problem right does
-- not flatter them; vendor_rework reports on them separately.
--
-- Only complaints that name a cleaning area in the vendor's locked work schedule get a rework visit, and only quality,
-- access, no-show and other problems: Duly handles safeguarding, damage and conduct reports directly.

alter table public.jobs add column rework_of_issue uuid references public.issues(id) on delete set null;
create index jobs_rework_idx on public.jobs (rework_of_issue) where rework_of_issue is not null;

-- The cleaning area a rework visit is for (null for an ordinary visit).
create function private.rework_item(p_job uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select i.plan_item_id from public.jobs j join public.issues i on i.id = j.rework_of_issue where j.id = p_job;
$$;

-- The weekday that decides a visit's check. For a rework visit it is the visit's own weekday if the area is planned then,
-- otherwise the first weekday the area is planned, so the area's method and minutes can always be worked out.
create or replace function private.job_weekday(p_job uuid)
returns text language plpgsql stable security definer set search_path = ''
as $$
declare v_day text; v_item text; v_days jsonb;
begin
  select lower(to_char(j.scheduled_start at time zone coalesce(
           (select m.timezone from public.organisations o join public.markets m on m.code = o.market where o.id = j.buyer_org_id), 'UTC'), 'dy'))
    into v_day from public.jobs j where j.id = p_job;
  v_item := private.rework_item(p_job);
  if v_item is null then return v_day; end if;
  select a -> 'days' into v_days
    from jsonb_array_elements(coalesce(private.job_workplan(p_job) -> 'sections', '[]')) s,
         jsonb_array_elements(coalesce(s -> 'subsections', '[]')) ss,
         jsonb_array_elements(coalesce(ss -> 'areas', '[]')) a
   where a ->> 'id' = v_item;
  if v_days is null or jsonb_exists(v_days, v_day) then return v_day; end if;
  return coalesce((select d from unnest(array['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun']) with ordinality t(d, n)
                    where jsonb_exists(v_days, d) order by n limit 1), v_day);
end;
$$;

-- The cleaning areas planned for a visit: the weekday's areas, or for a rework visit only the area it is for.
create or replace function private.job_planned_rows(p_job uuid)
returns table (item_id text, item_name text, group_id text, group_name text, section_name text)
language sql stable security definer set search_path = ''
as $$
  select a ->> 'id', a ->> 'name', ss ->> 'id', ss ->> 'name', s ->> 'name'
    from jsonb_array_elements(coalesce(private.job_workplan(p_job) -> 'sections', '[]')) s,
         jsonb_array_elements(coalesce(s -> 'subsections', '[]')) ss,
         jsonb_array_elements(coalesce(ss -> 'areas', '[]')) a
   where jsonb_exists(coalesce(a -> 'days', '{}'), private.job_weekday(p_job))
     and (private.rework_item(p_job) is null or a ->> 'id' = private.rework_item(p_job));
$$;

-- Minutes planned for a visit: for a rework visit, the vendor's minutes for the one area it is for.
create or replace function private.job_planned_minutes(p_job uuid)
returns integer language sql stable security definer set search_path = ''
as $$
  select case
    when private.job_uses_plan(p_job) then coalesce((
      select sum(coalesce(((ws.legend -> (a -> 'days' ->> private.job_weekday(p_job))) ->> 'minutes')::integer, 0))
        from public.jobs j
        join public.work_schedules ws on ws.quote_id = j.quote_id and ws.status = 'locked',
             jsonb_array_elements(ws.plan -> 'sections') s,
             jsonb_array_elements(coalesce(s -> 'subsections', '[]')) ss,
             jsonb_array_elements(coalesce(ss -> 'areas', '[]')) a
       where j.id = p_job and jsonb_exists(coalesce(a -> 'days', '{}'), private.job_weekday(p_job))
         and (private.rework_item(p_job) is null or a ->> 'id' = private.rework_item(p_job))), 0)::integer
    else (select round(private.schedule_minutes(j.brief_id, j.brief_version))::integer from public.jobs j where j.id = p_job)
  end;
$$;

-- ---------------------------------------------------------------------------
-- Booking a rework visit (vendor staff, or Duly)
-- ---------------------------------------------------------------------------
create function public.book_rework(p_issue uuid, p_start timestamptz)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  i public.issues; j public.jobs; v_minutes integer; v_job uuid; v_when text;
begin
  select * into i from public.issues where id = p_issue for update;
  if not found or i.job_id is null then raise exception 'Issue not found'; end if;
  select * into j from public.jobs where id = i.job_id;
  if not (private.is_platform_admin() or (private.is_vendor_staff(j.vendor_org_id) and i.kind <> 'safeguarding')) then
    raise exception 'Issue not found';
  end if;
  if i.kind in ('safeguarding', 'damage', 'conduct') then
    raise exception 'A rework visit is for quality, access and no-show problems. Duly handles this kind of report directly.';
  end if;
  if i.status not in ('open', 'vendor_fix') then raise exception 'This problem is already %', replace(i.status::text, '_', ' '); end if;
  if j.rework_of_issue is not null then raise exception 'This was already a rework visit: Duly will step in'; end if;
  if i.plan_item_id is null then raise exception 'A rework visit needs the complaint to name a cleaning area'; end if;
  if exists (select 1 from public.jobs r where r.rework_of_issue = p_issue and r.status not in ('cancelled', 'disputed')) then
    raise exception 'A rework visit is already booked for this problem';
  end if;
  if p_start is null or p_start < now() then raise exception 'Choose a start time in the future'; end if;

  -- The visit is as long as the vendor's own minutes for that area (at least 30).
  select coalesce(max(((ws.legend -> dv.value) ->> 'minutes')::integer), 0) into v_minutes
    from public.work_schedules ws,
         jsonb_array_elements(coalesce(ws.plan -> 'sections', '[]')) s,
         jsonb_array_elements(coalesce(s -> 'subsections', '[]')) ss,
         jsonb_array_elements(coalesce(ss -> 'areas', '[]')) a,
         jsonb_each_text(coalesce(a -> 'days', '{}')) dv
   where ws.quote_id = j.quote_id and ws.status = 'locked' and a ->> 'id' = i.plan_item_id;
  if not exists (select 1 from public.work_schedules ws, jsonb_array_elements(coalesce(ws.plan -> 'sections', '[]')) s,
                        jsonb_array_elements(coalesce(s -> 'subsections', '[]')) ss, jsonb_array_elements(coalesce(ss -> 'areas', '[]')) a
                  where ws.quote_id = j.quote_id and ws.status = 'locked' and a ->> 'id' = i.plan_item_id) then
    raise exception 'That cleaning area is not in the locked work schedule';
  end if;
  v_minutes := greatest(30, v_minutes);

  insert into public.jobs (buyer_org_id, vendor_org_id, site_id, brief_id, brief_version, contract_id, quote_id,
                           status, scheduled_start, scheduled_end, value, currency, rework_of_issue)
  values (j.buyer_org_id, j.vendor_org_id, j.site_id, j.brief_id, j.brief_version, null, j.quote_id,
          'matched', p_start, p_start + make_interval(mins => v_minutes), null, j.currency, p_issue)
  returning id into v_job;
  insert into public.job_events (job_id, kind, data)
  values (v_job, 'status_change', jsonb_build_object('to', 'matched', 'rework_of_issue', p_issue, 'area', i.plan_label, 'item', i.plan_item_id));
  if i.status = 'open' then update public.issues set status = 'vendor_fix' where id = p_issue; end if;

  begin
    v_when := private.local_when(p_start, j.buyer_org_id);
    perform private.notify(i.raised_by, null, 'issues', 'rework_booked', 'A visit is booked to put it right',
      format('The cleaner will come back on %s to put right: %s.', v_when, coalesce(i.plan_label, 'the area you reported')),
      '/jobs/' || v_job, 'rework-booked:' || v_job);
  exception when others then
    raise warning 'notification (rework booked) failed: %', sqlerrm;
  end;
  return v_job;
end;
$$;

-- ---------------------------------------------------------------------------
-- The client's verdict on a finished rework visit
-- ---------------------------------------------------------------------------
create function public.review_rework(p_job uuid, p_accepted boolean, p_note text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  j public.jobs; i public.issues; o public.jobs; v_note text := nullif(trim(coalesce(p_note, '')), '');
begin
  select * into j from public.jobs where id = p_job for update;
  if not found or j.rework_of_issue is null or not (private.is_job_buyer(p_job) or private.is_platform_admin()) then
    raise exception 'Rework visit not found';
  end if;
  select * into i from public.issues where id = j.rework_of_issue for update;
  if not (i.raised_by = (select auth.uid()) or private.is_platform_admin()) then
    raise exception 'Only the person who reported this problem, or Duly, can accept or reject the rework';
  end if;
  if j.status <> 'completed' then raise exception 'The cleaner has not finished this visit yet'; end if;
  select * into o from public.jobs where id = i.job_id;

  if v_note is not null then
    insert into public.job_events (job_id, kind, data) values (p_job, 'note', jsonb_build_object('text', v_note, 'rework_review', p_accepted));
  end if;

  if p_accepted then
    -- The area is right now: accept it on the rework visit and on the original visit, then close the complaint.
    insert into public.plan_results (job_id, plan_item_id, done, verdict) values (p_job, i.plan_item_id, false, 'met')
      on conflict (job_id, plan_item_id) do update set verdict = 'met';
    if o.status in ('completed', 'disputed') then
      insert into public.plan_results (job_id, plan_item_id, done, verdict) values (o.id, i.plan_item_id, false, 'met')
        on conflict (job_id, plan_item_id) do update set verdict = 'met';
    end if;
    update public.jobs set status = 'quality_verified', updated_at = now() where id = p_job;
    insert into public.job_events (job_id, kind, data) values (p_job, 'status_change', jsonb_build_object('to', 'quality_verified', 'rework', 'accepted'));
    update public.issues set status = 'resolved', resolution = coalesce(v_note, 'Put right on a rework visit') where id = i.id;
  else
    -- Still not right: the complaint goes to Duly.
    update public.jobs set status = 'disputed', updated_at = now() where id = p_job;
    insert into public.job_events (job_id, kind, data) values (p_job, 'status_change', jsonb_build_object('to', 'disputed', 'rework', 'rejected'));
    update public.issues set status = 'mediation' where id = i.id;
    begin
      perform private.notify_org(j.vendor_org_id, array['vendor_admin', 'dispatcher']::public.member_role[], 'issues', 'rework_rejected',
        'The rework was not accepted', format('The client says %s is still not right. Duly will look at it.', coalesce(i.plan_label, 'the area')),
        '/pro/jobs', 'rework-rejected:' || p_job);
      perform private.notify_admins('issues', 'rework_rejected', 'A rework was not accepted', 'A client says a rework visit did not put it right.',
        '/admin/issues', 'rework-rejected:' || p_job, null);
    exception when others then
      raise warning 'notification (rework rejected) failed: %', sqlerrm;
    end;
  end if;
end;
$$;

-- A rework visit is accepted with review_rework: it has no price, so it is never approved for payment.
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
  else
    if exists (select 1 from public.area_results where job_id = p_job and verdict is null) then
      raise exception 'Mark every standard met or not met first';
    end if;
    if exists (select 1 from public.area_results where job_id = p_job and verdict = 'not_met') then
      raise exception 'Some standards were not met: report an issue so the vendor can put it right';
    end if;
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

-- ---------------------------------------------------------------------------
-- Rework visits are not ordinary visits: leave them out of a vendor's rates and score.
-- ---------------------------------------------------------------------------
create or replace function private.vendor_ops(p_vendor uuid, p_from date, p_to date)
returns table (
  visits integer, on_time_rate numeric, avg_late_minutes numeric, avg_planned_minutes numeric, avg_on_site_minutes numeric,
  time_vs_plan numeric, plan_followed_rate numeric, first_time_right_rate numeric, complaints_per_100 numeric,
  photos_on_site_rate numeric, open_issues integer, sla_breaches integer, avg_hours_to_resolve numeric)
language sql stable security definer set search_path = ''
as $$
  with m as (
    select x.* from public.jobs j, lateral private.visit_metrics(j.id) x
     where j.vendor_org_id = p_vendor and j.scheduled_start::date between p_from and p_to and j.rework_of_issue is null),
  i as (
    select count(*) filter (where i.status <> 'resolved') as open_n,
           count(*) filter (where (i.resolved_at is not null and i.sla_due_at is not null and i.resolved_at > i.sla_due_at)
                              or (i.resolved_at is null and i.status <> 'resolved' and i.sla_due_at is not null and i.sla_due_at < now())) as breached,
           avg(extract(epoch from (i.resolved_at - i.created_at)) / 3600) filter (where i.resolved_at is not null) as hrs
      from public.issues i join public.jobs j on j.id = i.job_id
     where j.vendor_org_id = p_vendor and j.scheduled_start::date between p_from and p_to and i.kind <> 'safeguarding')
  select count(*)::integer,
         round(avg(case when m.on_time then 1 else 0 end), 3),
         round(avg(m.late_minutes), 1),
         round(avg(m.planned_minutes), 1),
         round(avg(m.on_site_minutes), 1),
         round(sum(m.on_site_minutes) filter (where m.on_site_minutes is not null and m.planned_minutes > 0)::numeric
               / nullif(sum(m.planned_minutes) filter (where m.on_site_minutes is not null and m.planned_minutes > 0), 0), 2),
         round(sum(m.ticked_areas)::numeric / nullif(sum(m.planned_areas), 0), 3),
         round(avg(case when m.first_time_right then 1 else 0 end), 3),
         round(sum(m.complaints)::numeric * 100 / nullif(count(*), 0), 1),
         round(sum(m.photos_on_site)::numeric / nullif(sum(m.photos), 0), 3),
         (select open_n from i)::integer, (select breached from i)::integer, round((select hrs from i)::numeric, 1)
    from m;
$$;

create or replace function public.vendor_visits(p_vendor uuid, p_from date, p_to date)
returns table (
  job_id uuid, scheduled_start timestamptz, site_name text, status text, late_minutes integer, on_time boolean,
  planned_minutes integer, on_site_minutes integer, planned_areas integer, ticked_areas integer, complaints integer, first_time_right boolean)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (private.is_platform_admin() or private.is_vendor_staff(p_vendor)) then raise exception 'Not allowed to see these measures'; end if;
  return query
    select m.job_id, m.scheduled_start, s.name, m.status, m.late_minutes, m.on_time, m.planned_minutes, m.on_site_minutes,
           m.planned_areas, m.ticked_areas, m.complaints, m.first_time_right
      from public.jobs j
      cross join lateral private.visit_metrics(j.id) m
      join public.sites s on s.id = m.site_id
     where j.vendor_org_id = p_vendor and j.scheduled_start::date between p_from and p_to and j.rework_of_issue is null
     order by m.scheduled_start desc limit 200;
end;
$$;

create or replace function private.recompute_vendor_score(p_vendor uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_w jsonb;
  v_tier smallint;
  v_met numeric; v_judged numeric;
  v_visits numeric; v_ontime numeric; v_ftr numeric; v_complained numeric;
  v_planned numeric; v_ticked numeric;
  v_buyers numeric; v_repeat numeric;
  r_met numeric; r_on numeric; r_ftr numeric; r_plan numeric; r_disp numeric; r_rep numeric;
  w_met numeric; w_on numeric; w_ftr numeric; w_plan numeric; w_disp numeric; w_rep numeric; w_ver numeric;
  v_total numeric;
begin
  select coalesce(p.ranking_weights, '{"standards_met":0.25,"right_first_time":0.15,"on_time":0.2,"plan_followed":0.05,"dispute_free":0.1,"repeat_clients":0.1,"verification":0.15}'::jsonb),
         o.verification_tier
    into v_w, v_tier
  from public.organisations o
  left join public.policies p on p.market = o.market and p.segment = coalesce(o.segment, 'sme')
  where o.id = p_vendor;

  -- Client verdicts: the brief's standards and the plan's cleaning areas (rework visits are not counted).
  select count(*) filter (where verdict = 'met'), count(*) filter (where verdict is not null)
    into v_met, v_judged
  from (
    select ar.verdict::text as verdict from public.area_results ar join public.jobs j on j.id = ar.job_id
     where j.vendor_org_id = p_vendor and j.rework_of_issue is null
    union all
    select pr.verdict::text from public.plan_results pr join public.jobs j on j.id = pr.job_id
     where j.vendor_org_id = p_vendor and j.rework_of_issue is null
  ) x;

  -- Per-visit measures, from the same function the vendor and Duly read.
  select count(*), count(*) filter (where m.on_time), count(*) filter (where m.first_time_right),
         count(*) filter (where m.complaints > 0),
         coalesce(sum(m.planned_areas), 0), coalesce(sum(least(m.ticked_areas, m.planned_areas)), 0)
    into v_visits, v_ontime, v_ftr, v_complained, v_planned, v_ticked
  from public.jobs j, lateral private.visit_metrics(j.id) m
  where j.vendor_org_id = p_vendor and j.rework_of_issue is null;

  select count(*), count(*) filter (where n >= 2) into v_buyers, v_repeat
  from (select buyer_org_id, count(*) n from public.jobs
        where vendor_org_id = p_vendor and status in ('quality_verified', 'paid') and rework_of_issue is null group by buyer_org_id) b;

  r_met := case when v_judged > 0 then v_met / v_judged end;
  r_on := case when v_visits > 0 then v_ontime / v_visits end;
  r_ftr := case when v_visits > 0 then v_ftr / v_visits end;
  r_plan := case when v_planned > 0 then v_ticked / v_planned end;
  r_disp := case when v_visits > 0 then v_complained / v_visits end;
  r_rep := case when v_buyers > 0 then v_repeat / v_buyers end;

  w_met := coalesce((v_w ->> 'standards_met')::numeric, 0);
  w_on := coalesce((v_w ->> 'on_time')::numeric, 0);
  w_ftr := coalesce((v_w ->> 'right_first_time')::numeric, 0);
  w_plan := case when r_plan is null then 0 else coalesce((v_w ->> 'plan_followed')::numeric, 0) end;
  w_disp := coalesce((v_w ->> 'dispute_free')::numeric, 0);
  w_rep := coalesce((v_w ->> 'repeat_clients')::numeric, 0);
  w_ver := coalesce((v_w ->> 'verification')::numeric, 0);
  v_total := w_met + w_on + w_ftr + w_plan + w_disp + w_rep + w_ver;

  insert into public.vendor_scores (org_id, quality_score, standards_met_rate, on_time_rate, dispute_rate,
                                    repeat_client_rate, right_first_time_rate, plan_followed_rate, jobs_completed, computed_at)
  values (
    p_vendor,
    case when v_total > 0 then round(100 * (
      w_met * coalesce(r_met, 0)
      + w_on * coalesce(r_on, 0)
      + w_ftr * coalesce(r_ftr, 0)
      + w_plan * coalesce(r_plan, 0)
      + w_disp * (1 - coalesce(r_disp, 0))
      + w_rep * coalesce(r_rep, 0)
      + w_ver * (v_tier::numeric / 3)
    ) / v_total, 2) end,
    round(100 * r_met, 2), round(100 * r_on, 2), round(100 * r_disp, 2), round(100 * r_rep, 2),
    round(100 * r_ftr, 2), round(100 * r_plan, 2),
    (select count(*) from public.jobs where vendor_org_id = p_vendor and status in ('quality_verified', 'paid') and rework_of_issue is null),
    now()
  )
  on conflict (org_id) do update set
    quality_score = excluded.quality_score, standards_met_rate = excluded.standards_met_rate,
    on_time_rate = excluded.on_time_rate, dispute_rate = excluded.dispute_rate,
    repeat_client_rate = excluded.repeat_client_rate, right_first_time_rate = excluded.right_first_time_rate,
    plan_followed_rate = excluded.plan_followed_rate, jobs_completed = excluded.jobs_completed,
    computed_at = excluded.computed_at;
end;
$$;

-- ---------------------------------------------------------------------------
-- How a vendor puts problems right (the vendor's staff and Duly)
-- ---------------------------------------------------------------------------
create function public.vendor_rework(p_vendor uuid, p_from date, p_to date)
returns table (
  complaints integer, reworks_booked integer, reworks_accepted integer, reworks_rejected integer, reworks_open integer,
  awaiting_rework integer, avg_hours_to_put_right numeric)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (private.is_platform_admin() or private.is_vendor_staff(p_vendor)) then raise exception 'Not allowed to see these measures'; end if;
  return query
    with oj as (select j.id from public.jobs j
                 where j.vendor_org_id = p_vendor and j.rework_of_issue is null and j.scheduled_start::date between p_from and p_to),
    cmp as (select i.* from public.issues i join oj on oj.id = i.job_id where i.kind <> 'safeguarding'),
    rw as (select r.status, r.rework_of_issue from public.jobs r join cmp on cmp.id = r.rework_of_issue)
    select (select count(*) from cmp)::integer,
           (select count(*) from rw)::integer,
           (select count(*) filter (where status in ('quality_verified', 'paid')) from rw)::integer,
           (select count(*) filter (where status = 'disputed') from rw)::integer,
           (select count(*) filter (where status in ('matched', 'en_route', 'on_site', 'in_progress', 'completed')) from rw)::integer,
           (select count(*) from cmp where cmp.status in ('open', 'vendor_fix') and cmp.plan_item_id is not null
               and cmp.kind in ('quality', 'access', 'no_show', 'other')
               and not exists (select 1 from public.jobs r where r.rework_of_issue = cmp.id and r.status not in ('cancelled', 'disputed')))::integer,
           round((select avg(extract(epoch from (cmp.resolved_at - cmp.created_at)) / 3600) from cmp
                   where cmp.resolved_at is not null
                     and exists (select 1 from public.jobs r where r.rework_of_issue = cmp.id and r.status in ('quality_verified', 'paid')))::numeric, 1);
end;
$$;

revoke execute on function private.rework_item(uuid) from public, anon, authenticated;
revoke execute on function public.book_rework(uuid, timestamptz), public.review_rework(uuid, boolean, text),
  public.vendor_rework(uuid, date, date) from public, anon;
grant execute on function public.book_rework(uuid, timestamptz), public.review_rework(uuid, boolean, text),
  public.vendor_rework(uuid, date, date) to authenticated;
