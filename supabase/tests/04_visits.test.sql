-- Recurring visits for a monthly plan.
do $$
declare f jsonb; v_contract uuid; n integer; before_sum numeric;
begin
  -- No visit days on the brief -> clear error.
  f := tests.book_job('sme');
  perform tests.as_user((f ->> 'buyer')::uuid);
  perform tests.throws(format('select public.schedule_visits(%L, 4)', f ->> 'contract'), '%no visit days%', 'schedule_visits needs days and a start time on the brief');

  -- One preferred weekday over four weeks books four visits, and is idempotent.
  f := tests.book_job('sme', array[lower(to_char(current_date + 2, 'dy'))], time '09:00');
  v_contract := (f ->> 'contract')::uuid;
  perform tests.as_user((f ->> 'buyer')::uuid);
  n := public.schedule_visits(v_contract, 4);
  perform tests.eq(n, 4, 'four weeks of a weekly brief books four visits');
  perform tests.eq(public.schedule_visits(v_contract, 4), 0, 'scheduling again books nothing new');
  perform tests.as_su();
  perform tests.eq((select count(*) from public.jobs where contract_id = v_contract and status = 'matched'), 5::bigint, 'first job plus four recurring visits');

  -- Monthly plans are charged by direct debit, kept in step with booked visits.
  perform tests.ok((select count(*) from public.payments where contract_id = v_contract and kind = 'direct_debit') >= 1, 'a direct debit charge exists for the contract');
  select coalesce(sum(amount), 0) into before_sum from public.payments where contract_id = v_contract and kind = 'direct_debit' and status = 'pending';
  perform tests.as_user((f ->> 'buyer')::uuid);
  perform public.schedule_visits(v_contract, 4);
  perform tests.as_su();
  perform tests.eq((select coalesce(sum(amount), 0) from public.payments where contract_id = v_contract and kind = 'direct_debit' and status = 'pending'),
                   before_sum, 'rescheduling leaves the charges unchanged');
  perform tests.ok(before_sum >= 30.00 * 5, 'direct debit covers every booked visit');
  perform tests.eq((select count(*) from public.payments where contract_id = v_contract and kind = 'escrow_hold'), 0::bigint, 'monthly plans take no escrow holds');
end $$;
