-- The vendor score reads the operational measures.
--
-- Until now the score looked only at the brief's standards verdicts, so a visit judged against a work schedule (plan_results)
-- did not count towards "standards met", and lateness used its own tolerance rule. The score now reads the same per-visit
-- measures the vendor and Duly see (private.visit_metrics), so what is measured is what is ranked:
--   on time           arrival against the start time and the policy tolerance
--   right first time  no complaint and nothing marked not met
--   areas ticked      planned areas the crew ticked (the plan's areas, or the brief's standards on a visit with no plan)
--   standards met     client verdicts, from the brief's standards and from the plan's cleaning areas
--   complaint-free    visits with no complaint (safeguarding is never counted)
-- The weights stay in policies.ranking_weights (nothing hard-coded). The score divides by the weights that apply, so a policy
-- that lacks the new keys still scores out of 100, and "areas ticked" is left out until the vendor has planned areas to measure.
-- rank_vendors is unchanged: it still orders by the stored quality score.

alter table public.vendor_scores
  add column right_first_time_rate numeric(5,2),
  add column plan_followed_rate numeric(5,2);

alter table public.policies alter column ranking_weights set default
  '{"standards_met":0.25,"right_first_time":0.15,"on_time":0.2,"plan_followed":0.05,"dispute_free":0.1,"repeat_clients":0.1,"verification":0.15}'::jsonb;

-- Move policies that still carry the old default to the new one. Any policy someone has tuned by hand is left as it is.
update public.policies
   set ranking_weights = '{"standards_met":0.25,"right_first_time":0.15,"on_time":0.2,"plan_followed":0.05,"dispute_free":0.1,"repeat_clients":0.1,"verification":0.15}'::jsonb
 where ranking_weights = '{"standards_met":0.4,"on_time":0.2,"dispute_free":0.15,"repeat_clients":0.1,"verification":0.15}'::jsonb;

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

  -- Client verdicts: the brief's standards and the plan's cleaning areas.
  select count(*) filter (where verdict = 'met'), count(*) filter (where verdict is not null)
    into v_met, v_judged
  from (
    select ar.verdict::text as verdict from public.area_results ar join public.jobs j on j.id = ar.job_id where j.vendor_org_id = p_vendor
    union all
    select pr.verdict::text from public.plan_results pr join public.jobs j on j.id = pr.job_id where j.vendor_org_id = p_vendor
  ) x;

  -- Per-visit measures, from the same function the vendor and Duly read.
  select count(*), count(*) filter (where m.on_time), count(*) filter (where m.first_time_right),
         count(*) filter (where m.complaints > 0),
         coalesce(sum(m.planned_areas), 0), coalesce(sum(least(m.ticked_areas, m.planned_areas)), 0)
    into v_visits, v_ontime, v_ftr, v_complained, v_planned, v_ticked
  from public.jobs j, lateral private.visit_metrics(j.id) m
  where j.vendor_org_id = p_vendor;

  select count(*), count(*) filter (where n >= 2) into v_buyers, v_repeat
  from (select buyer_org_id, count(*) n from public.jobs
        where vendor_org_id = p_vendor and status in ('quality_verified', 'paid') group by buyer_org_id) b;

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
    (select count(*) from public.jobs where vendor_org_id = p_vendor and status in ('quality_verified', 'paid')),
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

-- Bring the stored scores of vendors that have real visits in line with the new rule (vendors with no visits keep what they have).
select private.recompute_vendor_score(v.vendor_org_id)
  from (select distinct j.vendor_org_id from public.jobs j
         where exists (select 1 from public.job_events e where e.job_id = j.id and e.kind = 'check_in')) v;

revoke execute on function private.recompute_vendor_score(uuid) from public, anon, authenticated;
