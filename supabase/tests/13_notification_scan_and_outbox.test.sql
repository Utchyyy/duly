-- The scan for things that happen because time passed, and the email outbox the worker drains.
create function pg_temp.n(p_user uuid, p_event text) returns bigint language sql as $$
  select count(*) from public.notifications where user_id = p_user and event = p_event $$;
create function pg_temp.k(p_user uuid, p_key text) returns bigint language sql as $$
  select count(*) from public.notifications where user_id = p_user and dedupe_key = p_key $$;
create function pg_temp.key_any(p_key text) returns bigint language sql as $$
  select count(*) from public.notifications where dedupe_key = p_key $$;
create function pg_temp.as_worker() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', '', false);
  perform set_config('request.jwt.claim.role', 'service_role', false);
  execute 'reset role'; execute 'set role service_role';
end $$;
create function pg_temp.start_at(p_job uuid, p_when timestamptz) returns void language sql as $$
  update public.jobs set scheduled_start = p_when, scheduled_end = p_when + interval '2 hours' where id = p_job $$;

-- 1. Reminders, unassigned cleans and lateness. (Every fixture shares one vendor organisation, so these
--    assertions are keyed on the job's own dedupe keys.)
do $$
declare f jsonb; g jsonb; h jsonb; vendor uuid; crew uuid; job uuid;
begin
  f := tests.book_job('sme'); vendor := (f ->> 'vendor')::uuid; crew := (f ->> 'crew')::uuid; job := (f ->> 'job')::uuid;

  perform pg_temp.start_at(job, now() + interval '30 hours');
  perform private.notify_due_items();
  perform tests.eq(pg_temp.key_any('remind:' || job || ':' || crew) + pg_temp.key_any('unassigned:' || job) + pg_temp.key_any('late:' || job), 0::bigint,
                   'a clean more than 24 hours away prompts nothing');

  perform pg_temp.start_at(job, now() + interval '2 hours');
  perform private.notify_due_items();
  perform tests.eq(pg_temp.k(crew, 'remind:' || job || ':' || crew), 1::bigint, 'the cleaner is reminded of a clean in the next 24 hours');
  perform tests.eq(pg_temp.key_any('unassigned:' || job), 0::bigint, 'an assigned clean is not flagged as unassigned');
  perform private.notify_due_items();
  perform tests.eq(pg_temp.k(crew, 'remind:' || job || ':' || crew), 1::bigint, 'running the scan again does not repeat the reminder');

  delete from public.job_assignments where job_id = job;
  perform private.notify_due_items();
  perform tests.eq(pg_temp.k(vendor, 'unassigned:' || job), 1::bigint, 'vendor staff are told when a clean within 24 hours has nobody assigned');
  perform tests.eq(pg_temp.k(crew, 'unassigned:' || job), 0::bigint, 'a cleaner is not told about it');

  -- Late: past the tolerance, never checked in.
  g := tests.book_job('sme');
  perform pg_temp.start_at((g ->> 'job')::uuid, now() - interval '5 minutes');
  perform private.notify_due_items();
  perform tests.eq(pg_temp.key_any('late:' || (g ->> 'job')), 0::bigint, 'a few minutes late is within the tolerance');
  perform pg_temp.start_at((g ->> 'job')::uuid, now() - interval '2 hours');
  perform private.notify_due_items();
  perform tests.eq(pg_temp.k((g ->> 'vendor')::uuid, 'late:' || (g ->> 'job')), 1::bigint, 'vendor staff are told nobody has checked in');
  perform tests.eq(pg_temp.k((g ->> 'crew')::uuid, 'late:' || (g ->> 'job') || ':' || (g ->> 'crew')), 1::bigint, 'the assigned cleaner is asked to check in');
  perform tests.eq(pg_temp.k((g ->> 'buyer')::uuid, 'late:' || (g ->> 'job')), 0::bigint, 'the client is not alarmed by a lateness alert');
  perform tests.eq((select count(*) from public.job_events where job_id = (g ->> 'job')::uuid and kind = 'late_alert'), 1::bigint, 'a late_alert is recorded on the job');
  perform private.notify_due_items();
  perform tests.eq(pg_temp.k((g ->> 'vendor')::uuid, 'late:' || (g ->> 'job')), 1::bigint, 'the lateness alert is not repeated');
  perform tests.eq((select count(*) from public.job_events where job_id = (g ->> 'job')::uuid and kind = 'late_alert'), 1::bigint, 'nor is the job event');

  h := tests.book_job('sme');
  perform pg_temp.start_at((h ->> 'job')::uuid, now() - interval '20 hours');
  perform private.notify_due_items();
  perform tests.eq(pg_temp.key_any('late:' || (h ->> 'job')), 0::bigint, 'an old missed clean does not raise a fresh alarm');
  perform tests.eq((select count(*) from public.job_events where job_id = (h ->> 'job')::uuid and kind = 'late_alert'), 0::bigint, 'and records no late_alert');
end $$;

-- 2. Problems that are close to, or past, their response deadline.
do $$
declare f jsonb; vendor uuid; admin_u uuid; i1 uuid; i2 uuid; sg uuid;
begin
  f := tests.book_job('sme'); vendor := (f ->> 'vendor')::uuid; admin_u := (f ->> 'admin')::uuid;
  perform tests.as_user((f ->> 'buyer')::uuid);
  insert into public.issues (job_id, kind, description) values ((f ->> 'job')::uuid, 'quality', 'one') returning id into i1;
  insert into public.issues (job_id, kind, description) values ((f ->> 'job')::uuid, 'damage', 'two') returning id into i2;
  perform tests.as_user((f ->> 'crew')::uuid);
  insert into public.issues (job_id, kind, description) values ((f ->> 'job')::uuid, 'safeguarding', 'three') returning id into sg;
  perform tests.as_su();
  update public.issues set status = 'resolved' where id = i2;

  update public.issues set sla_due_at = now() + interval '1 hour' where id = i1;
  perform private.notify_due_items();
  perform tests.eq(pg_temp.k(admin_u, 'issue-soon:' || i1), 1::bigint, 'Duly is warned when an issue is close to its deadline');
  perform tests.eq(pg_temp.k(vendor, 'issue-soon:' || i1), 1::bigint, 'vendor staff are warned too');

  update public.issues set sla_due_at = now() - interval '1 hour' where id in (i1, i2, sg);
  perform private.notify_due_items();
  perform tests.eq(pg_temp.k(admin_u, 'issue-late:' || i1), 1::bigint, 'Duly is told an open issue is overdue');
  perform tests.eq(pg_temp.k(admin_u, 'issue-late:' || sg), 1::bigint, 'Duly is told a safeguarding concern is overdue');
  perform tests.eq(pg_temp.k(vendor, 'issue-late:' || i1), 1::bigint, 'vendor staff are told their open problem is overdue');
  perform tests.eq(pg_temp.k(vendor, 'issue-late:' || sg), 0::bigint, 'vendor staff are never told about the safeguarding one');
  perform tests.eq(pg_temp.key_any('issue-late:' || i2), 0::bigint, 'a resolved issue is never reported as overdue');
  perform private.notify_due_items();
  perform tests.eq(pg_temp.key_any('issue-late:' || i1) + pg_temp.key_any('issue-late:' || sg), (select count(*) from public.notifications where dedupe_key in ('issue-late:' || i1, 'issue-late:' || sg)),
                   'overdue notices are not repeated');
end $$;

-- 3. Money: what the client owes, and what Duly has to record.
do $$
declare f jsonb; buyer uuid; admin_u uuid; job uuid; expected bigint; note text; k int; iss uuid;
begin
  f := tests.book_job('sme'); buyer := (f ->> 'buyer')::uuid; admin_u := (f ->> 'admin')::uuid; job := (f ->> 'job')::uuid;
  update public.payments set due_at = now() - interval '1 hour' where contract_id = (f ->> 'contract')::uuid and kind = 'direct_debit';
  perform private.notify_due_items();
  perform tests.ok(pg_temp.n(buyer, 'payment_due') >= 1, 'the client is told a monthly payment is due');
  perform tests.ok(not exists (select 1 from public.notifications where user_id = buyer and event = 'payment_due' and (body ~ '[£$€0-9]')), 'the payment notice states no amount');
  k := pg_temp.n(buyer, 'payment_due');
  perform private.notify_due_items();
  perform tests.eq(pg_temp.n(buyer, 'payment_due')::int, k, 'a payment notice is not repeated');
  perform tests.eq(pg_temp.n(admin_u, 'payment_due'), 0::bigint, 'Duly is not told about money the client owes');

  perform tests.crew_completes(f);
  perform tests.buyer_approves(f);
  update public.payments set due_at = now() - interval '1 hour' where job_id = job and kind in ('release', 'platform_fee');
  delete from public.notifications where dedupe_key like 'admin-due:%';
  select count(*) into expected from public.payments p left join public.jobs j on j.id = p.job_id
   where p.status = 'pending' and p.kind in ('release', 'platform_fee') and p.due_at <= now() and coalesce(j.status::text, '') <> 'disputed';
  perform private.notify_due_items();
  select n.body into note from public.notifications n where n.user_id = admin_u and n.event = 'payments_to_record';
  perform tests.ok(note is not null, 'Duly gets one note about payments due to be recorded');
  perform tests.eq((regexp_match(note, '^(\d+) payment'))[1]::bigint, expected, 'the note counts exactly the releases that are due and not on hold');
  perform private.notify_due_items();
  perform tests.eq(pg_temp.n(admin_u, 'payments_to_record'), 1::bigint, 'it is one note a day, however often the scan runs');

  -- A disputed job's money is on hold, so it is not counted.
  perform tests.as_user(buyer);
  insert into public.issues (job_id, kind, description) values (job, 'quality', 'hold') returning id into iss;
  perform tests.as_su();
  perform tests.eq((select status::text from public.jobs where id = job), 'disputed', 'the job is on hold');
  perform tests.eq((select count(*) from public.payments p join public.jobs j on j.id = p.job_id where j.id = job and p.kind = 'release' and p.status = 'pending' and coalesce(j.status::text, '') <> 'disputed'), 0::bigint, 'none of its releases count as due');
end $$;

-- 4. Housekeeping.
do $$
declare u uuid := tests.mk_user('tidy');
begin
  insert into public.notifications (user_id, category, event, title, created_at, read_at, email_status) values
    (u, 'jobs', 'old_read', 'x', now() - interval '100 days', now() - interval '99 days', 'sent'),
    (u, 'jobs', 'old_unread', 'x', now() - interval '100 days', null, 'sent'),
    (u, 'jobs', 'new_read', 'x', now() - interval '1 day', now(), 'sent');
  perform private.notify_due_items();
  perform tests.eq(pg_temp.n(u, 'old_read'), 0::bigint, 'read notifications older than 90 days are tidied away');
  perform tests.eq(pg_temp.n(u, 'old_unread') + pg_temp.n(u, 'new_read'), 2::bigint, 'unread and recent ones are kept');
end $$;

-- 5. The email outbox: only the worker can use it, and it retries sensibly.
do $$
declare
  u1 uuid := tests.mk_user('mail1'); u2 uuid := tests.mk_user('mail2'); u3 uuid := tests.mk_user('mail-muted'); u4 uuid := tests.mk_user('mail-stale');
  u5 uuid; id1 uuid; r record; rows integer; att smallint; nxt timestamptz; i int;
begin
  insert into auth.users (email) values (null) returning id into u5;
  update public.notifications set email_status = 'skipped' where email_status in ('pending', 'sending');   -- clear the backlog from earlier tests
  insert into public.notification_settings (user_id, email_enabled) values (u3, false);
  perform private.notify(u1, null, 'jobs', 'mail', 'First', 'Body one', '/jobs/1', 'm1');
  perform private.notify(u2, null, 'quotes', 'mail', 'Second', 'Body two', '/pro/quotes', 'm2');
  perform private.notify(u3, null, 'jobs', 'mail', 'Muted', '', '/', 'm3');
  perform private.notify(u4, null, 'jobs', 'mail', 'Stale', '', '/', 'm4');
  update public.notifications set created_at = now() - interval '3 days' where user_id = u4;
  perform private.notify(u5, null, 'jobs', 'mail', 'Nowhere to send', '', '/', 'm5');

  -- Nobody but the worker may touch it.
  perform tests.as_user(u1);
  perform tests.throws('select * from public.worker_claim_notification_emails(10)', '%permission denied%', 'a signed-in person cannot claim emails');
  perform tests.throws(format('select public.worker_finish_notification_email(%L, true)', gen_random_uuid()), '%permission denied%', 'a signed-in person cannot finish emails');
  perform tests.as_anon();
  perform tests.throws('select * from public.worker_claim_notification_emails(10)', '%permission denied%', 'signed-out visitors cannot claim emails');
  perform tests.as_su();
  perform tests.throws('select * from public.worker_claim_notification_emails(10)', '%Only the notification worker%', 'even a database superuser without the service role is refused');

  -- The worker claims what is due, with the address, and nothing it should not.
  perform pg_temp.as_worker();
  select count(*) into rows from public.worker_claim_notification_emails(10);
  perform tests.eq(rows, 2, 'the worker claims the two emails that are due');
  perform tests.as_su();
  perform tests.eq((select email_status from public.notifications where user_id = u3), 'skipped', 'an opted-out person''s email is not claimed');
  perform tests.eq((select email_status || '/' || email_error from public.notifications where user_id = u4), 'skipped/too old to send', 'an email more than two days old is dropped');
  perform tests.eq((select email_status || '/' || email_error from public.notifications where user_id = u5), 'skipped/no email address', 'a person with no address is skipped');
  perform tests.eq((select email_status || '/' || email_attempts from public.notifications where user_id = u1), 'sending/1', 'a claimed email is marked sending with one attempt');
  perform tests.ok((select email_next_at > now() + interval '5 minutes' from public.notifications where user_id = u1), 'and leased for a while');

  perform pg_temp.as_worker();
  perform tests.eq((select count(*) from public.worker_claim_notification_emails(10)), 0::bigint, 'a claimed email is not handed out twice');
  select * into r from public.notifications where user_id = u1 and event = 'mail' limit 1;
  id1 := r.id;
  perform tests.as_su();
  perform tests.eq((select u.email from auth.users u where u.id = u1) is not null, true, 'the person has an address on their account');

  perform pg_temp.as_worker();
  perform public.worker_finish_notification_email(id1, true);
  perform tests.as_su();
  perform tests.eq((select email_status from public.notifications where id = id1), 'sent', 'a sent email is marked sent');
  perform tests.ok((select email_sent_at is not null and email_next_at is null and email_error is null from public.notifications where id = id1), 'with its time recorded and no retry pending');
  perform pg_temp.as_worker();
  perform public.worker_finish_notification_email(id1, false, 'late failure');
  perform tests.as_su();
  perform tests.eq((select email_status from public.notifications where id = id1), 'sent', 'a sent email cannot be un-sent by a late report');

  -- A failing provider: back off, retry, then give up.
  select id into id1 from public.notifications where user_id = u2 and event = 'mail';
  for i in 1..5 loop
    perform pg_temp.as_worker();
    -- Attempt 1 is the claim made above; later attempts are claimed again once the retry delay has passed.
    if i > 1 then
      perform tests.ok(exists (select 1 from public.worker_claim_notification_emails(10) c where c.id = id1), 'attempt ' || i || ' is handed to the worker');
    end if;
    perform public.worker_finish_notification_email(id1, false, 'provider said no');
    perform tests.as_su();
    select email_attempts, email_next_at into att, nxt from public.notifications where id = id1;
    perform tests.eq(att::int, i, 'attempt ' || i || ' is counted');
    if i < 5 then
      perform tests.eq((select email_status from public.notifications where id = id1), 'pending', 'after failure ' || i || ' it waits to be retried');
      perform tests.ok(nxt > now() + make_interval(mins => i * i * 5 - 1), 'with a longer delay each time');
      update public.notifications set email_next_at = now() - interval '1 second' where id = id1;
    end if;
  end loop;
  perform tests.eq((select email_status || '/' || email_error from public.notifications where id = id1), 'failed/provider said no', 'after five failures it gives up and keeps the reason');
  perform tests.ok((select email_next_at is null from public.notifications where id = id1), 'and is never retried');

  -- A worker that died mid-send: the lease runs out and the email is picked up again.
  perform private.notify(u1, null, 'jobs', 'lease', 'Lease', '', '/', 'm6');
  perform pg_temp.as_worker();
  perform public.worker_claim_notification_emails(10);
  perform tests.as_su();
  update public.notifications set email_next_at = now() - interval '1 second' where user_id = u1 and event = 'lease';
  perform pg_temp.as_worker();
  perform tests.eq((select count(*) from public.worker_claim_notification_emails(10) c where c.title = 'Lease'), 1::bigint, 'an email whose worker died is claimed again');
  perform tests.as_su();
  perform tests.eq((select email_attempts::int from public.notifications where user_id = u1 and event = 'lease'), 2, 'and the retry is counted');

  -- Batch size is respected.
  for i in 1..5 loop perform private.notify(u1, null, 'jobs', 'batch', 'Batch ' || i, '', '/', 'b' || i); end loop;
  perform pg_temp.as_worker();
  perform tests.eq((select count(*) from public.worker_claim_notification_emails(2)), 2::bigint, 'the worker can ask for a small batch');
  perform tests.as_su();
end $$;
