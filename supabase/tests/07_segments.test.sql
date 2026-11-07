-- Segments: money and matching come from `policies`, not from code.
do $$
declare
  seg record; f jsonb; v_job uuid; pol public.policies; r record; n integer; due_expected date; names text[];
  site uuid; buyer uuid; org uuid;
begin
  perform tests.throws($q$select public.create_buyer_org('Nope', 'not-a-segment')$q$, '%', 'create_buyer_org refuses an unknown segment')
    ;
end $$;

-- Ranking respects each segment's minimum verification tier.
do $$
declare seg record; f jsonb; bad integer; got integer;
begin
  for seg in select segment, min_verification_tier from public.policies where market = 'UK' order by segment loop
    f := tests.book_job(seg.segment);
    perform tests.as_user((f ->> 'buyer')::uuid);
    select count(*) filter (where verification_tier < seg.min_verification_tier), count(*) into bad, got
      from public.rank_vendors((f ->> 'site')::uuid);
    perform tests.as_su();
    perform tests.eq(bad, 0, format('%s: no ranked vendor is below tier %s', seg.segment, seg.min_verification_tier));
    perform tests.ok(got >= 1, format('%s: at least one vendor is ranked', seg.segment));
  end loop;
end $$;

-- Invoice-terms segments (enterprise, healthcare): invoice per month, due month end plus payment terms; no escrow, no direct debit.
do $$
declare seg text; f jsonb; v_job uuid; p public.payments; tz text := 'Europe/London'; expect date; terms integer;
begin
  foreach seg in array array['enterprise', 'healthcare'] loop
    f := tests.book_job(seg);
    v_job := (f ->> 'job')::uuid;
    perform tests.eq((select billing from public.contracts where id = (f ->> 'contract')::uuid), 'monthly', seg || ': contract bills monthly');
    perform tests.eq((select count(*) from public.payments where contract_id = (f ->> 'contract')::uuid and kind in ('escrow_hold', 'direct_debit')), 0::bigint,
                     seg || ': no escrow hold or direct debit');
    select * into p from public.payments where contract_id = (f ->> 'contract')::uuid and kind = 'invoice';
    perform tests.eq(p.amount, 30.00::numeric, seg || ': one invoice for the booked visit');
    select payment_terms_days into terms from public.contracts where id = (f ->> 'contract')::uuid;
    expect := ((date_trunc('month', (select scheduled_start from public.jobs where id = v_job) at time zone tz) + interval '1 month')::date) + terms;
    perform tests.eq((p.due_at at time zone tz)::date, expect, seg || ': invoice due month end plus payment terms');

    -- A changed payment term flows into the next refresh.
    update public.contracts set payment_terms_days = 30 where id = (f ->> 'contract')::uuid;
    perform private.refresh_client_charges((f ->> 'contract')::uuid);
    perform tests.eq(((select due_at from public.payments where contract_id = (f ->> 'contract')::uuid and kind = 'invoice') at time zone tz)::date, expect - terms + 30,
                     seg || ': payment terms come from the contract, not code');

    -- Invoice clients are not charged up front: first release is due on approval.
    perform tests.crew_completes(f);
    perform tests.buyer_approves(f);
    perform tests.ok((select due_at <= now() from public.payments where job_id = v_job and note like 'First release%'), seg || ': first release due on approval');
  end loop;
end $$;

-- Hospitality: monthly in advance, first release at month end.
do $$
declare f jsonb; v_job uuid;
begin
  f := tests.book_job('hospitality');
  v_job := (f ->> 'job')::uuid;
  perform tests.eq((select count(*) from public.payments where contract_id = (f ->> 'contract')::uuid and kind = 'direct_debit'), 1::bigint, 'hospitality: monthly direct debit');
  perform tests.crew_completes(f);
  perform tests.buyer_approves(f);
  perform tests.ok((select due_at > now() from public.payments where job_id = v_job and note like 'First release%'), 'hospitality: first release waits for month end');
end $$;

-- The schedule follows the policy row: change the numbers and the next approval follows.
do $$
declare f jsonb; v_job uuid; v_fee numeric;
begin
  update public.policies set first_release_pct = 70, platform_fee_pct = 10, balance_release_hours = 72 where market = 'UK' and segment = 'homeowner';
  f := tests.book_job('homeowner');
  v_job := (f ->> 'job')::uuid;
  perform tests.crew_completes(f);
  perform tests.buyer_approves(f);
  perform tests.eq((select amount from public.payments where job_id = v_job and note like 'First release%'), 21.00::numeric, 'first release follows the policy (70% of 30)');
  perform tests.eq((select amount from public.payments where job_id = v_job and kind = 'platform_fee'), 3.00::numeric, 'platform fee follows the policy (10% of 30)');
  perform tests.eq((select amount from public.payments where job_id = v_job and note like 'Balance%'), 6.00::numeric, 'balance is what is left after first release and fee');
  perform tests.eq((select coalesce(sum(amount), 0) from public.payments where job_id = v_job and kind in ('release', 'platform_fee')), 30.00::numeric, 'everything adds up to the job value');
  perform tests.ok((select abs(extract(epoch from (due_at - now())) / 3600 - 72) < 0.1 from public.payments where job_id = v_job and kind = 'platform_fee'),
                   'the balance window follows the policy (72 hours)');
  update public.policies set first_release_pct = 55, platform_fee_pct = null, balance_release_hours = 48 where market = 'UK' and segment = 'homeowner';
end $$;
