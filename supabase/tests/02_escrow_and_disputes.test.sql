-- One-off escrow plan (homeowner): hold on booking, first release on approval, issues freeze money, job ends 'paid'.
do $$
declare f jsonb; v_job uuid; v_issue uuid;
begin
  f := tests.book_job('homeowner');
  v_job := (f ->> 'job')::uuid;

  perform tests.eq((select billing from public.contracts where id = (f ->> 'contract')::uuid), 'per_job', 'homeowner contract bills per job');
  perform tests.eq((select amount from public.payments where job_id = v_job and kind = 'escrow_hold'), 30.00::numeric, 'escrow hold created for the job value');

  perform tests.crew_completes(f);
  perform tests.buyer_approves(f);
  perform tests.ok((select due_at <= now() from public.payments where job_id = v_job and note like 'First release%'),
                   'first release is due on approval');

  -- The client reports a problem: the job is disputed and money is frozen.
  perform tests.as_user((f ->> 'buyer')::uuid);
  insert into public.issues (job_id, kind, description) values (v_job, 'quality', 'Bins missed') returning id into v_issue;
  perform tests.as_su();
  perform tests.eq((select status::text from public.jobs where id = v_job), 'disputed', 'an open issue puts the job in dispute');
  perform tests.as_user((f ->> 'admin')::uuid);
  perform tests.throws(format('select public.mark_payment_paid(id, %L) from public.payments where job_id = %L and note like %L',
                              'x', v_job, 'First release%'), '%open issue%', 'no release while the job is disputed');

  -- The vendor cannot close a complaint against itself; the client can.
  perform tests.as_user((f ->> 'vendor')::uuid);
  perform tests.throws(format('update public.issues set status = %L where id = %L', 'resolved', v_issue),
                       '%Only the person who reported%', 'vendor cannot resolve the issue');
  perform tests.as_user((f ->> 'buyer')::uuid);
  update public.issues set status = 'resolved' where id = v_issue;
  perform tests.as_su();
  perform tests.eq((select status::text from public.jobs where id = v_job), 'quality_verified', 'resolving the issue restores the approved status');

  -- Duly records the transfers; the balance waits for its own due time.
  perform tests.as_user((f ->> 'admin')::uuid);
  perform public.mark_payment_paid(id, 'BACS-HOLD') from public.payments where job_id = v_job and kind = 'escrow_hold';
  perform public.mark_payment_paid(id, 'BACS-1') from public.payments where job_id = v_job and note like 'First release%';
  perform tests.throws(format('select public.mark_payment_paid(id, %L) from public.payments where job_id = %L and note like %L',
                              'x', v_job, 'Balance%'), '%Not due until%', 'balance waits for the complaint window');
  perform tests.eq((select status::text from public.jobs where id = v_job), 'quality_verified', 'job is not paid until every release is paid');

  perform tests.as_su();
  update public.payments set due_at = now() - interval '1 hour' where job_id = v_job and status = 'pending' and kind in ('release', 'platform_fee');
  perform tests.as_user((f ->> 'admin')::uuid);
  perform public.mark_payment_paid(id, 'BACS-2') from public.payments where job_id = v_job and status = 'pending' and kind in ('release', 'platform_fee');
  perform tests.as_su();
  perform tests.eq((select status::text from public.jobs where id = v_job), 'paid', 'job is paid once all releases are recorded');
end $$;
