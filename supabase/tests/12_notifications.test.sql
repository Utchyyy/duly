-- Notifications: who is told what, what is never said, and that telling can never block the action.
create function pg_temp.n(p_user uuid, p_event text) returns bigint language sql as $$
  select count(*) from public.notifications where user_id = p_user and event = p_event $$;
create function pg_temp.k(p_user uuid, p_key text) returns bigint language sql as $$
  select count(*) from public.notifications where user_id = p_user and dedupe_key = p_key $$;
create function pg_temp.latest(p_user uuid, p_event text) returns public.notifications language sql as $$
  select n from public.notifications n where n.user_id = p_user and n.event = p_event order by n.created_at desc limit 1 $$;

-- 1. The workflow produces the right notifications for the right people.
do $$
declare
  f jsonb; buyer uuid; vendor uuid; crew uuid; admin_u uuid; job uuid; n public.notifications; extra uuid := tests.mk_user('bystander');
  colleague uuid := tests.mk_user('colleague'); mine uuid;
begin
  f := tests.book_job('sme');
  buyer := (f ->> 'buyer')::uuid; vendor := (f ->> 'vendor')::uuid; crew := (f ->> 'crew')::uuid; admin_u := (f ->> 'admin')::uuid; job := (f ->> 'job')::uuid;

  perform tests.eq(pg_temp.n(vendor, 'quote_requested'), 1::bigint, 'vendor staff are told a quote was requested');
  perform tests.eq(pg_temp.n(buyer, 'quote_submitted'), 1::bigint, 'the client is told a quote arrived');
  perform tests.eq(pg_temp.n(vendor, 'quote_accepted'), 1::bigint, 'vendor staff are told their quote was accepted');
  perform tests.eq(pg_temp.n(crew, 'job_assigned'), 1::bigint, 'the cleaner is told they were assigned');
  perform tests.eq(pg_temp.n(crew, 'quote_requested') + pg_temp.n(crew, 'quote_accepted'), 0::bigint, 'a cleaner is not told about quotes (not vendor staff)');
  perform tests.eq(pg_temp.n(buyer, 'quote_requested'), 0::bigint, 'the person who made the request is not told about it');
  perform tests.eq(pg_temp.n(extra, 'quote_requested') + pg_temp.n(admin_u, 'quote_requested'), 0::bigint, 'people not involved are told nothing');

  n := pg_temp.latest(vendor, 'quote_requested');
  perform tests.eq(n.category, 'quotes', 'a quote request is in the quotes category');
  perform tests.eq(n.link, '/pro/quotes', 'a quote request links to the quotes screen');
  perform tests.eq((pg_temp.latest(buyer, 'quote_submitted')).link, '/briefs/' || (f ->> 'brief'), 'a quote arriving links to the brief');
  perform tests.eq((pg_temp.latest(crew, 'job_assigned')).link, '/crew/' || job, 'an assignment links to the job sheet');
  perform tests.ok((pg_temp.latest(crew, 'job_assigned')).body like '%at%', 'the assignment says when (in the market''s own timezone)');

  perform tests.crew_completes(f);
  perform tests.eq(pg_temp.n(buyer, 'job_completed'), 1::bigint, 'the client is told the clean is ready to check');
  perform tests.eq((pg_temp.latest(buyer, 'job_completed')).link, '/jobs/' || job, 'ready-to-check links to the job');
  perform tests.buyer_approves(f);
  perform tests.eq(pg_temp.n(vendor, 'job_approved'), 1::bigint, 'vendor staff are told the clean was approved');

  -- A problem: the vendor, Duly and (later) the person who raised it hear about it, not the person raising it.
  perform tests.as_user(buyer);
  insert into public.issues (job_id, kind, description) values (job, 'quality', 'A private description of the problem') returning id into extra;
  perform tests.as_su();
  perform tests.eq(pg_temp.n(vendor, 'issue_raised'), 1::bigint, 'vendor staff are told a problem was reported');
  perform tests.eq(pg_temp.n(admin_u, 'issue_raised'), 1::bigint, 'Duly is told about a new issue');
  perform tests.eq(pg_temp.n(buyer, 'issue_raised'), 0::bigint, 'the person who reported it is not told they reported it');
  perform tests.as_user(buyer);
  update public.issues set status = 'resolved' where id = extra;
  perform tests.as_su();
  perform tests.eq(pg_temp.n(buyer, 'issue_resolved'), 1::bigint, 'the person who reported it is told when it is resolved');
  perform tests.eq(pg_temp.n(vendor, 'issue_resolved'), 1::bigint, 'vendor staff are told it was resolved');
  -- The person who does something is not told about it, but their colleagues are.
  insert into public.memberships values ((f ->> 'vendor_org')::uuid, colleague, 'dispatcher');
  perform tests.as_user(vendor);
  insert into public.issues (job_id, kind, description) values (job, 'other', 'Raised by the vendor') returning id into mine;
  perform tests.as_su();
  perform tests.eq(pg_temp.k(vendor, 'issue-new:' || mine), 0::bigint, 'vendor staff who raise an issue are not told about their own report');
  perform tests.eq(pg_temp.k(colleague, 'issue-new:' || mine), 1::bigint, 'but a colleague at the same vendor is');
  perform tests.eq(pg_temp.k(admin_u, 'issue-new:' || mine), 1::bigint, 'and so is Duly');
  perform tests.ok(not exists (select 1 from public.notifications where body like '%A private description%' or title like '%A private description%'), 'an issue''s description is never put in a notification');
end $$;

-- 2. Nothing sensitive is ever said: pay, addresses, access notes, safeguarding.
do $$
declare
  f jsonb; vendor_org uuid; w uuid; wu uuid := tests.mk_user('shiftworker'); colch int; sh uuid; bad text;
begin
  f := tests.book_job('sme');
  select id into colch from public.towns where name = 'Colchester';
  vendor_org := (f ->> 'vendor_org')::uuid;
  update public.sites set access_notes = 'KEYSAFE-9999 behind the bins', address_line1 = '17 Hidden Lane', postcode = 'CO9 9ZZ' where id = (f ->> 'site')::uuid;
  insert into public.workers (user_id, full_name, home_town_id) values (wu, 'Sam Worker', colch) returning id into w;
  insert into public.wiix_screens (worker_id, reliability, shift_fit, capability, commute_tolerance) values (w, 4, 4, 4, 4);
  insert into public.shifts (vendor_org_id, town_id, shift_date, start_time, end_time, hourly_pay) values (vendor_org, colch, current_date + 2, '09:00', '12:00', 13.37) returning id into sh;
  perform tests.as_user((f ->> 'vendor')::uuid);
  perform public.offer_shift(sh, w);
  perform tests.as_user(wu);
  perform public.respond_to_shift(sh, true);
  perform tests.as_su();
  perform tests.eq(pg_temp.n(wu, 'shift_offered'), 1::bigint, 'a worker is told a shift was offered');
  perform tests.eq(pg_temp.n((f ->> 'vendor')::uuid, 'shift_accepted'), 1::bigint, 'vendor staff are told a worker accepted');
  perform tests.eq((pg_temp.latest(wu, 'shift_offered')).link, '/crew', 'a shift offer links to Duly Crew');

  -- A safeguarding report: Duly only, and nothing about what it says.
  perform tests.as_user((f ->> 'crew')::uuid);
  insert into public.issues (job_id, kind, description) values ((f ->> 'job')::uuid, 'safeguarding', 'SECRET-SAFEGUARDING-DETAIL');
  perform tests.as_su();
  perform tests.eq(pg_temp.n((f ->> 'admin')::uuid, 'safeguarding_raised'), 1::bigint, 'Duly is told about a safeguarding concern');
  perform tests.eq((select count(*) from public.notifications where user_id = (f ->> 'vendor')::uuid and category = 'issues'), 0::bigint,
                   'the vendor is told nothing about a safeguarding report');
  perform tests.eq((select count(*) from public.notifications where user_id = (f ->> 'buyer')::uuid and category = 'issues'), 0::bigint,
                   'the client is told nothing about a safeguarding report');

  select string_agg(title || ' | ' || body, E'\n') into bad from public.notifications
   where title || ' ' || body ~* '(13\.37|KEYSAFE|Hidden Lane|CO9 9ZZ|SECRET-SAFEGUARDING|[£$€]|hourly|pay rate)';
  perform tests.eq(coalesce(bad, ''), '', 'no notification mentions staff pay, access notes, addresses, safeguarding detail or an amount');
  perform tests.eq((select count(*) from public.notifications where title ~ '@' or body ~ '@'), 0::bigint, 'no email addresses are written into notifications');
  perform tests.eq((select count(*) from public.notifications where link is not null and link !~ '^/($|[^/])'), 0::bigint, 'every link is an in-app path');
end $$;

-- 3. People see and change only their own.
do $$
declare f jsonb; buyer uuid; vendor uuid; mine bigint; others bigint; nid uuid; m bigint;
begin
  f := tests.book_job('sme');
  buyer := (f ->> 'buyer')::uuid; vendor := (f ->> 'vendor')::uuid;
  perform tests.as_user(buyer);
  select count(*) into mine from public.notifications;
  select count(*) into others from public.notifications where user_id <> buyer;
  perform tests.ok(mine > 0, 'a person sees their own notifications');
  perform tests.eq(others, 0::bigint, 'a person sees nobody else''s notifications');
  perform tests.as_anon();
  perform tests.eq((select count(*) from public.notifications), 0::bigint, 'signed-out visitors see no notifications');

  perform tests.as_user(buyer);
  perform tests.throws(format('insert into public.notifications (user_id, category, event, title) values (%L, %L, %L, %L)', buyer, 'jobs', 'fake', 'Fake'),
                       '%row-level security%', 'a person cannot create a notification');
  update public.notifications set title = 'Edited', read_at = now() where user_id = buyer;
  get diagnostics m = row_count;
  perform tests.eq(m, 0::bigint, 'a person cannot edit a notification directly');
  delete from public.notifications where user_id = buyer;
  get diagnostics m = row_count;
  perform tests.eq(m, 0::bigint, 'a person cannot delete a notification');

  select id into nid from public.notifications where user_id = buyer order by created_at limit 1;
  perform tests.eq(public.mark_notifications_read(array[nid]), 1, 'a person can mark one notification read');
  perform tests.eq(public.mark_notifications_read(array[nid]), 0, 'marking it again changes nothing');
  perform tests.ok((select read_at is not null from public.notifications where id = nid), 'it is marked read');
  perform tests.as_su();
  perform private.notify(buyer, null, 'jobs', 'extra', 'Another one', '', '/', 'extra-key');
  perform tests.as_user(vendor);
  perform tests.eq(public.mark_notifications_read(array[nid]), 0, 'a person cannot mark someone else''s notification read');
  perform tests.ok((select count(*) from public.notifications where read_at is null) > 0, 'the vendor''s own are still unread');
  perform public.mark_notifications_read();
  perform tests.eq((select count(*) from public.notifications where read_at is null), 0::bigint, 'marking all read clears the person''s own');
  perform tests.as_user(buyer);
  perform tests.ok((select count(*) from public.notifications where read_at is null) > 0, 'and does not touch anyone else''s');
  perform tests.as_anon();
  perform tests.throws('select public.mark_notifications_read()', '%permission denied%', 'signed-out visitors cannot call mark_notifications_read');
end $$;

-- 4. Email settings: opt-out, per-category, never for problems.
do $$
declare
  u uuid := tests.mk_user('picky'); u2 uuid := tests.mk_user('quiet'); u3 uuid := tests.mk_user('unmuted'); other uuid := tests.mk_user('someone');
  st text;
begin
  perform tests.as_user(u);
  insert into public.notification_settings (user_id, email_muted) values (u, array['quotes']);
  perform tests.as_user(u2);
  insert into public.notification_settings (user_id, email_enabled) values (u2, false);
  perform tests.as_su();
  perform private.notify(u, null, 'quotes', 't1', 'A quote thing', '', '/', 'k1');
  perform private.notify(u, null, 'jobs', 't2', 'A job thing', '', '/', 'k2');
  perform private.notify(u2, null, 'jobs', 't3', 'A job thing', '', '/', 'k3');
  perform private.notify(u3, null, 'jobs', 't4', 'A job thing', '', '/', 'k4');
  select email_status into st from public.notifications where user_id = u and event = 't1';
  perform tests.eq(st, 'skipped', 'a muted category is not emailed');
  perform tests.eq((select count(*) from public.notifications where user_id = u and event = 't1'), 1::bigint, 'but it is still in the inbox');
  perform tests.eq((select email_status from public.notifications where user_id = u and event = 't2'), 'pending', 'other categories are still emailed');
  perform tests.eq((select email_status from public.notifications where user_id = u2), 'skipped', 'someone who turned email off is not emailed');
  perform tests.eq((select count(*) from public.notifications where user_id = u2), 1::bigint, 'but still gets the in-app notification');
  perform tests.eq((select email_status from public.notifications where user_id = u3), 'pending', 'the default is to email');

  perform tests.as_user(u);
  perform tests.throws(format('update public.notification_settings set email_muted = %L where user_id = %L', array['issues'], u), '%check constraint%', 'problems and disputes cannot be muted');
  perform tests.throws(format('update public.notification_settings set email_muted = %L where user_id = %L', array['nonsense'], u), '%check constraint%', 'only real categories can be muted');
  update public.notification_settings set email_muted = array['quotes', 'jobs'] where user_id = u;
  perform tests.eq((select email_muted from public.notification_settings where user_id = u), array['quotes', 'jobs'], 'a person can change their own settings');
  perform tests.eq((select count(*) from public.notification_settings), 1::bigint, 'a person sees only their own settings');
  perform tests.throws(format('insert into public.notification_settings (user_id) values (%L)', other), '%row-level security%', 'a person cannot create settings for someone else');
  perform tests.as_su();
  perform private.notify(u, null, 'issues', 't5', 'A problem', '', '/', 'k5');
  perform tests.eq((select email_status from public.notifications where user_id = u and event = 't5'), 'pending', 'problems are still emailed');
end $$;

-- 5. Dedupe, and telling can never block the action.
do $$
declare f jsonb; u uuid := tests.mk_user('dupe'); issues_before bigint; ok_id uuid;
begin
  perform private.notify(u, null, 'jobs', 'x', 'Once', '', '/', 'same-key');
  perform private.notify(u, null, 'jobs', 'x', 'Once', '', '/', 'same-key');
  perform private.notify(u, null, 'jobs', 'x', 'Twice', '', '/', 'other-key');
  perform tests.eq((select count(*) from public.notifications where user_id = u), 2::bigint, 'the same dedupe key is notified once');

  f := tests.book_job('sme');
  -- Break the notifications table so every insert fails, then do real work.
  alter table public.notifications add constraint zz_always_fails check (false) not valid;
  perform tests.as_user((f ->> 'buyer')::uuid);
  insert into public.issues (job_id, kind, description) values ((f ->> 'job')::uuid, 'quality', 'Still gets raised') returning id into ok_id;
  perform tests.ok(ok_id is not null, 'an issue is still raised when notifying fails');
  perform tests.as_su();
  perform tests.ok((select sla_due_at is not null and raised_by = (f ->> 'buyer')::uuid from public.issues where id = ok_id), 'and the issue''s own triggers (deadline, reporter) still ran');
  alter table public.notifications drop constraint zz_always_fails;
end $$;
