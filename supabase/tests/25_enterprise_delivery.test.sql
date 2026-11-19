-- The Enterprise's delivery view across its vendors: attention flags, vendor scorecards, open problems, handing one to Duly, isolation.

create function pg_temp.email_of(u uuid) returns text language sql security definer as $$ select email::text from auth.users where id = u $$;

do $$
declare
  f jsonb; ent uuid; vend uuid; buyer uuid; crew uuid; admin_u uuid; vendor_u uuid;
  owner2 uuid := tests.mk_user('ent2-owner'); approver uuid := tests.mk_user('ent1-approver'); viewer uuid := tests.mk_user('ent1-viewer'); stranger uuid := tests.mk_user('stranger-x');
  ent2 uuid; jl uuid[]; j1 uuid; j2 uuid; j3 uuid; j4 uuid; j5 uuid; j6 uuid; issue uuid; issue2 uuid; sg uuid; n bigint; r record; fr jsonb;
  d1 date := current_date - 30; d2 date := current_date + 60;
begin
  f := tests.book_job('enterprise', array['mon','tue','wed','thu','fri','sat','sun'], '09:00');
  ent := (f ->> 'buyer_org')::uuid; vend := (f ->> 'vendor_org')::uuid; buyer := (f ->> 'buyer')::uuid; crew := (f ->> 'crew')::uuid;
  admin_u := (f ->> 'admin')::uuid; vendor_u := (f ->> 'vendor')::uuid;
  insert into public.memberships values (ent, approver, 'approver'), (ent, viewer, 'viewer');
  perform tests.as_user(admin_u); ent2 := public.admin_create_enterprise('Other Enterprise', pg_temp.email_of(owner2));
  perform public.enterprise_add_vendor(ent2, vend); perform tests.as_su();

  perform tests.as_user(buyer); perform public.schedule_visits((f ->> 'contract')::uuid, 4); perform tests.as_su();
  select array_agg(id order by scheduled_start, id) into jl from public.jobs where buyer_org_id = ent and status <> 'cancelled';
  perform tests.ok(cardinality(jl) >= 6, 'a daily pattern gives enough visits to work with');
  j1 := jl[1]; j2 := jl[2]; j3 := jl[3]; j4 := jl[4]; j5 := jl[5]; j6 := jl[6];
  -- put six visits where each case needs them; the rest stay in the future
  update public.jobs set scheduled_start = scheduled_start + interval '40 days', scheduled_end = scheduled_end + interval '40 days' where buyer_org_id = ent and id <> all (jl[1:6]);
  delete from public.job_assignments where job_id = any (jl);
  update public.jobs set scheduled_start = now() - interval '4 hours',   scheduled_end = now() - interval '2 hours'  where id = j1;  -- missed
  update public.jobs set scheduled_start = now() - interval '40 minutes', scheduled_end = now() + interval '80 minutes' where id = j2;  -- late
  update public.jobs set scheduled_start = now() + interval '3 hours',   scheduled_end = now() + interval '5 hours'  where id = j3;  -- no crew
  update public.jobs set scheduled_start = now() + interval '3 days',    scheduled_end = now() + interval '3 days 2 hours' where id = j6; -- fine, future, nobody yet but not soon
  insert into public.job_assignments (job_id, user_id, role) values (j1, crew, 'lead'), (j2, crew, 'lead'), (j4, crew, 'lead'), (j5, crew, 'lead');
  update public.jobs set scheduled_start = now() - interval '5 hours', scheduled_end = now() - interval '3 hours' where id = j4;
  update public.jobs set scheduled_start = now() - interval '30 hours', scheduled_end = now() - interval '28 hours' where id = j5;
  -- j4 is done by the crew (awaiting a check); j5 is done and approved
  perform tests.crew_completes(jsonb_build_object('job', j4, 'crew', crew));
  perform tests.crew_completes(jsonb_build_object('job', j5, 'crew', crew));
  -- the check-ins really happen "now"; place them where a crew arriving on time would have
  update public.job_events e set at = (select scheduled_start + interval '5 minutes' from public.jobs where id = e.job_id) where e.kind = 'check_in' and e.job_id in (j4, j5);
  update public.job_events e set at = (select scheduled_end - interval '10 minutes' from public.jobs where id = e.job_id) where e.kind = 'check_out' and e.job_id in (j4, j5);
  perform tests.buyer_approves(jsonb_build_object('job', j5, 'buyer', buyer));

  -- The board.
  perform tests.as_user(buyer);
  select count(*) into n from public.enterprise_delivery_board(ent, d1, d2) where job_id = j1 and attention = 'missed'; perform tests.eq(n, 1::bigint, 'a booked visit past its end with nobody in is missed');
  select count(*) into n from public.enterprise_delivery_board(ent, d1, d2) where job_id = j2 and attention = 'late'; perform tests.eq(n, 1::bigint, 'one past its tolerance but before its end is late');
  select late_minutes into r from public.enterprise_delivery_board(ent, d1, d2) where job_id = j2; perform tests.ok(r.late_minutes between 39 and 42, 'with how late it is');
  select count(*) into n from public.enterprise_delivery_board(ent, d1, d2) where job_id = j3 and attention = 'no_crew'; perform tests.eq(n, 1::bigint, 'a visit starting within a day with nobody assigned is flagged');
  select count(*) into n from public.enterprise_delivery_board(ent, d1, d2) where job_id = j6 and attention is null; perform tests.eq(n, 1::bigint, 'one days away with nobody yet is not');
  select count(*) into n from public.enterprise_delivery_board(ent, d1, d2) where job_id = j4 and attention = 'awaiting_check'; perform tests.eq(n, 1::bigint, 'a finished visit not yet checked awaits the Enterprise');
  select count(*) into n from public.enterprise_delivery_board(ent, d1, d2) where job_id = j5 and attention is null; perform tests.eq(n, 1::bigint, 'and an approved one needs nothing');
  select vendor_name, crew_count, photos into r from public.enterprise_delivery_board(ent, d1, d2) where job_id = j4;
  perform tests.eq(r.vendor_name, 'Clean-Fit', 'each row names the vendor'); perform tests.eq(r.crew_count, 1, 'and counts the crew, without naming them'); perform tests.ok(r.photos > 0, 'and the photos');
  -- order: missed, late, no_crew, awaiting_check come before the rest, in that order
  select string_agg(attention, ',' order by ord) into r from (select attention, row_number() over () as ord from public.enterprise_delivery_board(ent, d1, d2) where attention is not null) s;
  perform tests.eq(r.string_agg, 'missed,late,no_crew,awaiting_check', 'what needs attention comes first, most urgent first');
  select attention into r from public.enterprise_delivery_board(ent, d1, d2) limit 1; perform tests.eq(r.attention, 'missed', 'so the first row is the missed visit');
  -- a narrow range leaves out the future but keeps what is unfinished from before it
  select count(*) into n from public.enterprise_delivery_board(ent, current_date + 2, current_date + 4); perform tests.ok(n >= 2, 'a later range still carries the unfinished visits from before it');
  select count(*) into n from public.enterprise_delivery_board(ent, current_date + 2, current_date + 4) where job_id = j1; perform tests.eq(n, 1::bigint, 'the missed visit is not forgotten');
  select count(*) into n from public.enterprise_delivery_board(ent, current_date + 2, current_date + 4) where job_id = j5; perform tests.eq(n, 0::bigint, 'but a finished, approved one is');

  -- Who may look.
  perform tests.as_user(viewer);
  select count(*) into n from public.enterprise_delivery_board(ent, d1, d2); perform tests.ok(n > 0, 'an Enterprise viewer can see the board');
  perform tests.as_user(owner2);
  perform tests.throws(format('select * from public.enterprise_delivery_board(%L, %L, %L)', ent, d1, d2), '%Not allowed%', 'another Enterprise cannot');
  perform tests.throws(format('select * from public.enterprise_vendor_delivery(%L, %L, %L)', ent, d1, d2), '%Not allowed%', 'nor the scorecards');
  perform tests.throws(format('select * from public.enterprise_open_issues(%L)', ent), '%Not allowed%', 'nor the problems');
  select count(*) into n from public.enterprise_delivery_board(ent2, d1, d2); perform tests.eq(n, 0::bigint, 'and its own board has none of these visits');
  perform tests.as_user(vendor_u);
  perform tests.throws(format('select * from public.enterprise_delivery_board(%L, %L, %L)', ent, d1, d2), '%Not allowed%', 'a vendor uses its own dispatch board, not this');
  perform tests.as_user(stranger);
  perform tests.throws(format('select * from public.enterprise_delivery_board(%L, %L, %L)', ent, d1, d2), '%Not allowed%', 'a stranger cannot');
  perform tests.as_user(buyer);
  perform tests.throws(format('select * from public.enterprise_delivery_board(%L, %L, %L)', (select id from public.organisations where name = 'Clean-Fit'), d1, d2), '%Not allowed%', 'and it is only for an Enterprise');

  -- Scorecards.
  perform tests.as_user(buyer);
  select * into r from public.enterprise_vendor_delivery(ent, d1, d2) where vendor_org_id = vend;
  perform tests.eq(r.vendor_name, 'Clean-Fit', 'a scorecard per roster vendor');
  perform tests.eq(r.due_visits, 4, 'four visits have come due (the one in three hours has not)');
  perform tests.eq(r.checked_in_visits, 2, 'two were checked in');
  perform tests.eq(r.evidenced_visits, 2, 'both fully evidenced (checked in, every area ticked, photos)');
  perform tests.eq(r.evidenced_rate, 0.5, 'two of four due visits evidenced');
  perform tests.eq(r.missed_visits, 1, 'one missed');
  perform tests.eq(r.late_visits, 1, 'one late');
  perform tests.eq(r.awaiting_check, 1, 'one awaiting a check');
  perform tests.eq(r.on_time_rate, 1.0, 'both that arrived were on time');
  perform tests.ok(r.upcoming_visits >= 1, 'and some are still to come');
  perform tests.eq(r.complaints, 0, 'no complaints yet');
  perform tests.as_user(owner2);
  select count(*) into n from public.enterprise_vendor_delivery(ent2, d1, d2) where due_visits > 0; perform tests.eq(n, 0::bigint, 'the other Enterprise''s scorecard for the same vendor counts none of these visits');

  -- Problems.
  perform tests.as_user(buyer);
  insert into public.issues (job_id, kind, description) values (j5, 'quality', 'Showers not clean') returning id into issue;
  insert into public.issues (job_id, kind, description) values (j4, 'no_show', 'Came late') returning id into issue2;
  insert into public.issues (job_id, kind, description) values (j4, 'safeguarding', 'A private matter') returning id into sg;
  select count(*) into n from public.enterprise_open_issues(ent); perform tests.eq(n, 2::bigint, 'two open problems, the safeguarding report left out');
  perform tests.as_su();
  update public.issues set sla_due_at = now() - interval '1 hour' where id = issue2;
  perform tests.as_user(buyer);
  select issue_id, breached into r from public.enterprise_open_issues(ent) limit 1; perform tests.eq(r.issue_id, issue2, 'the one past its response time comes first'); perform tests.ok(r.breached, 'and says so');
  select * into r from public.enterprise_vendor_delivery(ent, d1, d2) where vendor_org_id = vend;
  perform tests.eq(r.complaints, 2, 'scorecard counts the two complaints'); perform tests.eq(r.open_issues, 2, 'both open'); perform tests.eq(r.sla_breaches, 1, 'one past its response time');

  -- Handing a problem to Duly.
  perform tests.as_user(viewer);
  perform tests.throws(format('select public.enterprise_escalate_issue(%L)', issue), '%owner or approvers%', 'a viewer cannot hand a problem to Duly');
  perform tests.as_user(owner2);
  perform tests.throws(format('select public.enterprise_escalate_issue(%L)', issue), '%owner or approvers%', 'nor another Enterprise');
  perform tests.as_user(approver);
  perform public.enterprise_escalate_issue(issue2);
  perform tests.as_su(); perform tests.eq((select status::text from public.issues where id = issue2), 'mediation', 'an approver hands it to Duly (mediation)');
  perform tests.as_user(approver);
  perform tests.throws(format('select public.enterprise_escalate_issue(%L)', issue2), '%already looking%', 'only once');
  perform tests.throws(format('select public.enterprise_escalate_issue(%L)', sg), '%Safeguarding%', 'a safeguarding report is never handed on this way');
  perform tests.as_su(); update public.issues set status = 'resolved', resolved_at = now() where id = issue;
  perform tests.as_user(approver);
  perform tests.throws(format('select public.enterprise_escalate_issue(%L)', issue), '%already resolved%', 'nor a resolved one');
  perform tests.as_user(buyer);
  select count(*) into n from public.enterprise_open_issues(ent); perform tests.eq(n, 1::bigint, 'a resolved problem leaves the list; the escalated one stays, flagged as with Duly');
  select status into r from public.enterprise_open_issues(ent) limit 1; perform tests.eq(r.status, 'mediation', 'its status shows it is with Duly');
  perform tests.as_su();
  select count(*) into n from public.audit_log where table_name = 'issues' and op = 'UPDATE' and row_id = issue2::text; perform tests.ok(n >= 1, 'handing it on is on the record');
end $$;
