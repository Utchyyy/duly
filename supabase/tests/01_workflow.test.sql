-- Happy path on a monthly (sme) plan: rank -> quote -> accept -> check in -> complete -> approve -> ledger -> score.
do $$
declare
  f jsonb; v_job uuid; v_total numeric; v_pol public.policies; r jsonb; n integer;
  v_first numeric; v_value numeric;
begin
  f := tests.book_job('sme');
  v_job := (f ->> 'job')::uuid;

  -- Ranking is computed in SQL: ranks are 1..n in order, with no gaps.
  perform tests.as_user((f ->> 'buyer')::uuid);
  perform tests.ok((select count(*) from public.rank_vendors((f ->> 'site')::uuid)) >= 2, 'rank_vendors returns candidates');
  perform tests.ok((select bool_and(rank = rn) from (select rank, row_number() over () as rn from public.rank_vendors((f ->> 'site')::uuid)) x),
                   'ranks are 1..n in the order the function returns them');

  -- Price comes from price_quote: 90 minutes at 20/h.
  perform tests.as_su();
  perform tests.eq((select total from public.quotes where id = (f ->> 'quote')::uuid), 30.00::numeric, 'quote priced by price_quote (90 min @ 20/h)');
  perform tests.eq((select value from public.jobs where id = v_job), 30.00::numeric, 'job value equals the accepted quote');
  perform tests.eq((select billing from public.contracts where id = (f ->> 'contract')::uuid), 'monthly', 'sme contract bills monthly');

  -- The quote price cannot be tampered with by the buyer; the vendor cannot accept its own quote.
  perform tests.as_user((f ->> 'buyer')::uuid);
  update public.quotes set total = 1 where id = (f ->> 'quote')::uuid;
  perform tests.as_su();
  perform tests.eq((select total from public.quotes where id = (f ->> 'quote')::uuid), 30.00::numeric, 'buyer cannot change a quote total');

  -- Crew: not on the job -> cannot check in; on the job -> geofence recorded in SQL.
  perform tests.as_user(tests.mk_user('outsider'));
  perform tests.throws(format('select public.check_in(%L, 51.8893, 0.9043)', v_job), '%not on this job%', 'non-assigned user cannot check in');
  perform tests.as_user((f ->> 'crew')::uuid);
  r := public.check_in(v_job, 51.8893, 0.9043);
  perform tests.eq((r ->> 'within_geofence')::boolean, true, 'check-in at the site is inside the geofence');
  perform tests.eq((select status::text from public.jobs where id = v_job), 'in_progress', 'check-in starts the job');

  -- Cannot complete without photos, then without ticks.
  perform tests.throws(format('select public.complete_job(%L)', v_job), '%still need an after photo%', 'complete needs an after photo per area');
  insert into public.evidence (job_id, area_id, kind, storage_path, lat, lng) values
    (v_job, 'a1', 'photo_after', v_job || '/a1/1.jpg', 51.8893, 0.9043),
    (v_job, 'a2', 'photo_after', v_job || '/a2/1.jpg', 51.5, -0.1);
  perform tests.eq((select within_geofence from public.evidence where job_id = v_job and area_id = 'a1'), true, 'evidence on site is inside the geofence');
  perform tests.eq((select within_geofence from public.evidence where job_id = v_job and area_id = 'a2'), false, 'evidence far away is flagged outside the geofence');
  perform tests.throws(format('select public.complete_job(%L)', v_job), '%still need ticking%', 'complete needs every standard ticked');
  insert into public.area_results (job_id, area_id, standard_id, done_by_operative) values
    (v_job, 'a1', 's1', true), (v_job, 'a1', 's2', true), (v_job, 'a2', 's3', true);
  perform public.complete_job(v_job, 51.8893, 0.9043);
  perform tests.eq((select status::text from public.jobs where id = v_job), 'completed', 'job is completed');
  perform tests.throws(format('update public.area_results set verdict = %L where job_id = %L', 'met', v_job),
                       '%Only the client%', 'crew cannot give the verdict');

  -- Client review: no approval until every standard has a verdict.
  perform tests.as_user((f ->> 'buyer')::uuid);
  perform tests.throws(format('select public.approve_job(%L)', v_job), '%Mark every standard%', 'approve needs a verdict on every standard');
  update public.area_results set verdict = 'met' where job_id = v_job;
  perform public.approve_job(v_job);
  perform tests.as_su();
  perform tests.eq((select status::text from public.jobs where id = v_job), 'quality_verified', 'approved job is quality_verified');

  -- Release schedule comes from policies: first release % on month end for monthly plans; balance after the hold.
  v_pol := private.policy_for_org((f ->> 'buyer_org')::uuid);
  v_value := 30.00;
  v_first := round(v_value * v_pol.first_release_pct / 100, 2);
  perform tests.eq((select min(amount) filter (where note like 'First release%') from public.payments where job_id = v_job and kind = 'release'),
                   v_first, 'first release amount follows policy percentage');
  perform tests.eq((select coalesce(sum(amount), 0) from public.payments where job_id = v_job and kind in ('release', 'platform_fee')),
                   v_value, 'releases plus platform fee add up to the job value');
  perform tests.ok((select due_at > now() from public.payments where job_id = v_job and note like 'First release%'),
                   'monthly plan: first release is due at month end, not now');

  -- Only Duly records payments, and not before they are due.
  perform tests.as_user((f ->> 'buyer')::uuid);
  perform tests.throws(format('select public.mark_payment_paid(id, %L) from public.payments where job_id = %L limit 1', 'x', v_job),
                       '%Only Duly staff%', 'buyer cannot record a payment');
  perform tests.as_user((f ->> 'admin')::uuid);
  perform tests.throws(format('select public.mark_payment_paid(id, %L) from public.payments where job_id = %L and kind = %L limit 1', 'x', v_job, 'release'),
                       '%Not due until%', 'release cannot be paid before it is due');

  -- Score is recomputed from the real job.
  perform tests.as_su();
  perform tests.eq((select jobs_completed from public.vendor_scores where org_id = (f ->> 'vendor_org')::uuid), 1, 'vendor score counts the verified job');
  perform tests.eq((select standards_met_rate from public.vendor_scores where org_id = (f ->> 'vendor_org')::uuid), 100.00::numeric, 'standards met rate is 100%');
end $$;
