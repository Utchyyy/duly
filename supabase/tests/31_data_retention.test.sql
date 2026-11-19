-- Data retention: the rules start off, the report and the switches are for Duly staff, each rule clears or deletes only what it should,
-- and the audit trail stops copying the most sensitive columns and can only ever drop rows older than six years.

create function pg_temp.audit_changes(p_table text, p_row text) returns jsonb language sql security definer as $$
  select changes from public.audit_log where table_name = p_table and row_id = p_row order by id desc limit 1 $$;

do $$
declare
  admin_u uuid := tests.mk_user('admin'); plain uuid := tests.mk_user('plain'); worker_u uuid := tests.mk_user('worker'); raiser uuid := tests.mk_user('raiser');
  f jsonb; job uuid; vend uuid; duly_org uuid; w uuid; app_old uuid; app_new uuid; app_open uuid; ev_old uuid; ev_new uuid; q_old uuid; q_new uuid; q_pend uuid;
  c_pers uuid; c_comp uuid; c_pers_new uuid; i_sg uuid; i_ok uuid; gf boolean; n bigint; r record; k bigint; ev_audit jsonb;
begin
  select id into duly_org from public.organisations where kind = 'platform';
  insert into public.memberships values (duly_org, admin_u, 'platform_admin');
  f := tests.book_job('sme'); job := (f ->> 'job')::uuid; vend := (f ->> 'vendor_org')::uuid;

  -- The rules start switched off.
  select count(*) into n from public.data_retention_rules; perform tests.eq(n, 8::bigint, 'eight rules');
  select count(*) into n from public.data_retention_rules where enabled; perform tests.eq(n, 0::bigint, 'all switched off to begin with');
  perform tests.eq((select months from public.data_retention_rules where key = 'audit_log'), 72, 'the audit log defaults to six years');

  -- Who may see and change them.
  perform tests.as_user(plain);
  perform tests.throws('select * from public.admin_retention_report()', '%Only Duly staff%', 'only Duly staff see the report');
  perform tests.throws($q$select public.admin_set_retention_rule('notifications_old', 6, true)$q$, '%Only Duly staff%', 'or change a rule');
  select count(*) into n from public.data_retention_rules; perform tests.eq(n, 0::bigint, 'the table is not readable by anyone else');
  select count(*) into n from public.data_retention_runs; perform tests.eq(n, 0::bigint, 'nor the log of runs');
  perform tests.as_anon();
  select count(*) into n from public.data_retention_rules; perform tests.eq(n, 0::bigint, 'nor signed-out visitors');

  -- Setting a rule.
  perform tests.as_user(admin_u);
  perform tests.throws($q$select public.admin_set_retention_rule('notifications_old', 0, true)$q$, '%between 1 and 240%', 'a period must be at least a month');
  perform tests.throws($q$select public.admin_set_retention_rule('notifications_old', 241, true)$q$, '%between 1 and 240%', 'and at most twenty years');
  perform tests.throws($q$select public.admin_set_retention_rule('audit_log', 36, true)$q$, '%six years%', 'the audit log cannot be set below six years');
  perform tests.throws($q$select public.admin_set_retention_rule('nonsense', 6, true)$q$, '%No retention rule%', 'the rule must exist');
  perform tests.as_su();

  -- Fixtures: old and recent rows for each rule.
  insert into public.notifications (user_id, category, event, title, created_at) values (plain, 'jobs', 'x', 'old', now() - interval '14 months'), (plain, 'jobs', 'x', 'recent', now() - interval '2 months');
  insert into public.job_events (job_id, kind, at, lat, lng, within_geofence) values (job, 'check_in', now() - interval '14 months', 51.8, 0.9, true), (job, 'check_in', now() - interval '1 month', 51.8, 0.9, true);
  insert into public.evidence (job_id, area_id, kind, storage_path, taken_at, lat, lng) values (job, 'g1', 'photo_after', job || '/old.jpg', now() - interval '14 months', 51.8893, 0.9043) returning id into ev_old;
  insert into public.evidence (job_id, area_id, kind, storage_path, taken_at, lat, lng) values (job, 'g1', 'photo_after', job || '/new.jpg', now() - interval '1 month', 51.8893, 0.9043) returning id into ev_new;
  insert into public.approval_queue (org_id, kind, status, source, created_by, created_at) values
    ((f ->> 'buyer_org')::uuid, 'brief_draft', 'approved', '{"text":"pasted text about a person"}', (f ->> 'buyer')::uuid, now() - interval '8 months') returning id into q_old;
  insert into public.approval_queue (org_id, kind, status, source, created_by, created_at) values
    ((f ->> 'buyer_org')::uuid, 'brief_draft', 'approved', '{"text":"recent"}', (f ->> 'buyer')::uuid, now() - interval '1 month') returning id into q_new;
  insert into public.approval_queue (org_id, kind, status, source, created_by, created_at) values
    ((f ->> 'buyer_org')::uuid, 'brief_draft', 'pending', '{"text":"still being reviewed"}', (f ->> 'buyer')::uuid, now() - interval '9 months') returning id into q_pend;
  insert into public.workers (user_id, full_name) values (worker_u, 'Worker One') returning id into w;
  insert into public.dbs_applications (worker_id, path, status, certificate_type, certificate_reference, form_data, admin_notes, created_at)
    values (w, 'new_check', 'cleared', 'enhanced', 'CERT-OLD', '{"dob":"1990-01-01"}', 'checked by hand', now() - interval '14 months') returning id into app_old;
  insert into public.dbs_applications (worker_id, path, status, certificate_type, certificate_reference, form_data, created_at)
    values (w, 'new_check', 'cleared', 'enhanced', 'CERT-NEW', '{"dob":"1990-01-01"}', now() - interval '2 months') returning id into app_new;
  insert into public.dbs_applications (worker_id, path, status, certificate_type, form_data, created_at)
    values (w, 'new_check', 'sent_to_ucheck', 'enhanced', '{"dob":"1990-01-01"}', now() - interval '20 months') returning id into app_open;
  insert into public.verification_claims (org_id, subject_user_id, kind, reference, status, created_at) values (vend, worker_u, 'dbs', 'CERT-PERS', 'expired', now() - interval '14 months') returning id into c_pers;
  insert into public.verification_claims (org_id, subject_user_id, kind, reference, status, created_at) values (vend, worker_u, 'right_to_work', 'RTW-NEW', 'expired', now() - interval '2 months') returning id into c_pers_new;
  insert into public.verification_claims (org_id, kind, reference, status, created_at) values (vend, 'iso_9001', 'ISO-OLD', 'expired', now() - interval '20 months') returning id into c_comp;

  select within_geofence into gf from public.evidence where id = ev_old;
  perform tests.ok(gf is not null, 'the old photo was judged on or off site when it was taken');

  -- Nothing is touched while the rules are off.
  perform tests.eq(private.apply_retention(), 0::bigint, 'with every rule off the scan does nothing');
  select count(*) into n from public.notifications where user_id = plain; perform tests.eq(n, 2::bigint, 'the old notification is still there');
  select count(*) into n from public.job_events where lat is not null and job_id = job; perform tests.eq(n, 2::bigint, 'and so are the coordinates');

  -- The report says what is due.
  perform tests.as_user(admin_u);
  select * into r from public.admin_retention_report() where key = 'notifications_old'; perform tests.eq(r.due_now, 1::bigint, 'the report counts one old notification');
  select * into r from public.admin_retention_report() where key = 'job_event_locations'; perform tests.eq(r.due_now, 1::bigint, 'one old check-in with coordinates');
  select * into r from public.admin_retention_report() where key = 'evidence_locations'; perform tests.eq(r.due_now, 1::bigint, 'one old photo with coordinates');
  select * into r from public.admin_retention_report() where key = 'ai_draft_sources'; perform tests.eq(r.due_now, 1::bigint, 'one decided draft with its source (not the pending one)');
  select * into r from public.admin_retention_report() where key = 'dbs_application_forms'; perform tests.eq(r.due_now, 1::bigint, 'one finished DBS application (not the recent or unfinished ones)');
  select * into r from public.admin_retention_report() where key = 'personal_claims'; perform tests.eq(r.due_now, 1::bigint, 'one lapsed personal claim (never the company claim)');
  select * into r from public.admin_retention_report() where key = 'evidence_photos'; perform tests.eq(r.due_now, 0::bigint, 'no photo is older than the report-only period');
  select * into r from public.admin_retention_report() where key = 'audit_log'; perform tests.eq(r.enabled, false, 'every rule reads as off'); perform tests.ok(r.last_run_at is null, 'and as never run');

  -- Switch the rules on and run the scan.
  perform public.admin_set_retention_rule('notifications_old', 12, true);
  perform public.admin_set_retention_rule('job_event_locations', 13, true);
  perform public.admin_set_retention_rule('evidence_locations', 13, true);
  perform public.admin_set_retention_rule('ai_draft_sources', 6, true);
  perform public.admin_set_retention_rule('dbs_application_forms', 12, true);
  perform public.admin_set_retention_rule('personal_claims', 12, true);
  perform public.admin_set_retention_rule('evidence_photos', 12, true);
  select updated_by into r from public.data_retention_rules where key = 'personal_claims'; perform tests.eq(r.updated_by, admin_u, 'who changed a rule is recorded');
  perform tests.as_su();
  k := private.apply_retention();
  perform tests.eq(k, 6::bigint, 'the scan changed six rows, one for each acting rule');

  select count(*) into n from public.notifications where user_id = plain; perform tests.eq(n, 1::bigint, 'the old notification is deleted');
  select count(*) into n from public.notifications where user_id = plain and title = 'recent'; perform tests.eq(n, 1::bigint, 'and the recent one kept');
  select count(*) into n from public.job_events where job_id = job and lat is null and lng is null and kind = 'check_in' and within_geofence; perform tests.eq(n, 1::bigint, 'the old check-in loses its coordinates but keeps its time, kind and on-site result');
  select count(*) into n from public.job_events where job_id = job and lat is not null; perform tests.eq(n, 1::bigint, 'the recent check-in keeps them');
  select * into r from public.evidence where id = ev_old; perform tests.ok(r.lat is null and r.lng is null, 'the old photo loses its coordinates'); perform tests.eq(r.storage_path, job || '/old.jpg', 'but is still the same photo'); perform tests.eq(r.within_geofence, gf, 'and keeps its on-site result');
  select * into r from public.evidence where id = ev_new; perform tests.ok(r.lat is not null, 'the recent photo keeps its coordinates');
  select source into r from public.approval_queue where id = q_old; perform tests.eq(r.source, '{}'::jsonb, 'a decided draft loses its source text');
  select source into r from public.approval_queue where id = q_new; perform tests.ok(r.source <> '{}'::jsonb, 'a recent one keeps it');
  select source into r from public.approval_queue where id = q_pend; perform tests.ok(r.source <> '{}'::jsonb, 'and a draft still pending keeps it however old');
  select * into r from public.dbs_applications where id = app_old;
  perform tests.ok(r.form_data = '{}'::jsonb and r.admin_notes is null and r.certificate_reference is null, 'an old finished DBS application loses its form, notes and reference');
  perform tests.eq(r.status::text, 'cleared', 'but keeps its outcome');
  select * into r from public.dbs_applications where id = app_new; perform tests.ok(r.certificate_reference = 'CERT-NEW' and r.form_data <> '{}'::jsonb, 'a recent application is untouched');
  select * into r from public.dbs_applications where id = app_open; perform tests.ok(r.form_data <> '{}'::jsonb, 'and so is one that has not finished, however old');
  select count(*) into n from public.verification_claims where id = c_pers; perform tests.eq(n, 0::bigint, 'a lapsed personal claim is deleted');
  select count(*) into n from public.verification_claims where id in (c_pers_new, c_comp); perform tests.eq(n, 2::bigint, 'a recent personal claim and an old company claim are kept');
  select count(*) into n from public.data_retention_runs where rows_affected = 1; perform tests.eq(n, 6::bigint, 'each action is logged');
  perform tests.eq(private.apply_retention(), 0::bigint, 'running it again changes nothing');

  -- Report-only rules never change anything.
  perform tests.as_user(admin_u);
  select * into r from public.admin_retention_report() where key = 'evidence_photos'; perform tests.eq(r.due_now, 1::bigint, 'the photo rule counts the old photo');
  perform tests.as_su();
  select count(*) into n from public.evidence where id = ev_old; perform tests.eq(n, 1::bigint, 'but does not delete it');
  select * into r from public.data_retention_rules where key = 'evidence_photos'; perform tests.eq(r.action, 'report', 'it is report-only');

  -- The report reads the last run.
  perform tests.as_user(admin_u);
  select * into r from public.admin_retention_report() where key = 'notifications_old'; perform tests.ok(r.last_run_at is not null and r.last_rows = 1, 'the report shows when a rule last acted and how much');
  select * into r from public.admin_retention_report() where key = 'notifications_old'; perform tests.eq(r.due_now, 0::bigint, 'and nothing is due now');
  perform tests.as_su();

  -- The audit trail stops copying the most sensitive columns.
  ev_audit := pg_temp.audit_changes('evidence', ev_new::text);
  perform tests.ok(ev_audit is not null and ev_audit ? 'storage_path' and not (ev_audit ? 'lat') and not (ev_audit ? 'lng'), 'a photo is audited without its coordinates');
  ev_audit := pg_temp.audit_changes('verification_claims', c_pers_new::text);
  perform tests.ok(ev_audit is not null and ev_audit ? 'kind' and not (ev_audit ? 'reference') and not (ev_audit ? 'notes') and not (ev_audit ? 'evidence_path'), 'a personal claim is audited without its reference, notes or document');
  ev_audit := pg_temp.audit_changes('verification_claims', c_comp::text);
  perform tests.ok(ev_audit ->> 'reference' = 'ISO-OLD', 'a company claim is still audited in full');
  perform tests.as_user((f ->> 'buyer')::uuid);
  insert into public.issues (job_id, kind, description) values (job, 'safeguarding', 'a private safeguarding matter') returning id into i_sg;
  insert into public.issues (job_id, kind, description) values (job, 'quality', 'floors not clean') returning id into i_ok;
  perform tests.as_su();
  ev_audit := pg_temp.audit_changes('issues', i_sg::text);
  perform tests.ok(ev_audit is not null and ev_audit ->> 'kind' = 'safeguarding' and not (ev_audit ? 'description'), 'a safeguarding report is audited without its text');
  ev_audit := pg_temp.audit_changes('issues', i_ok::text);
  perform tests.eq(ev_audit ->> 'description', 'floors not clean', 'an ordinary issue is still audited in full');
  update public.issues set resolution = 'handled in confidence' where id = i_sg;
  ev_audit := pg_temp.audit_changes('issues', i_sg::text);
  perform tests.ok(ev_audit is null or not (ev_audit::text like '%handled in confidence%'), 'and so is the resolution of one');

  -- The audit log can only drop rows older than six years, and only through the scan.
  insert into public.audit_log (at, table_name, op, row_id, summary, changes, source) values
    (now() - interval '7 years', 'probe', 'INSERT', 'old', 'seven years old', '{}', 'trigger'),
    (now() - interval '3 years', 'probe', 'INSERT', 'young', 'three years old', '{}', 'trigger');
  perform tests.throws($q$delete from public.audit_log where table_name = 'probe'$q$, '%append-only%', 'nobody can delete an audit row directly');
  perform tests.throws($q$update public.audit_log set summary = 'x' where table_name = 'probe'$q$, '%append-only%', 'or change one');
  perform tests.throws($q$truncate public.audit_log$q$, '%append-only%', 'or truncate the log');
  perform set_config('duly.audit_purge', 'on', true);
  perform tests.throws($q$delete from public.audit_log where table_name = 'probe' and row_id = 'young'$q$, '%append-only%', 'even with the purge flag set, a row younger than six years is refused');
  perform set_config('duly.audit_purge', 'off', true);
  perform tests.as_user(admin_u);
  select * into r from public.admin_retention_report() where key = 'audit_log'; perform tests.eq(r.due_now, 1::bigint, 'only the seven-year-old row is due');
  perform public.admin_set_retention_rule('audit_log', 72, true);
  perform tests.as_su();
  k := private.apply_retention();
  select count(*) into n from public.audit_log where table_name = 'probe' and row_id = 'old'; perform tests.eq(n, 0::bigint, 'the scan deletes the seven-year-old row');
  select count(*) into n from public.audit_log where table_name = 'probe' and row_id = 'young'; perform tests.eq(n, 1::bigint, 'and keeps the three-year-old one');
  perform tests.throws($q$delete from public.audit_log where table_name = 'probe' and row_id = 'young'$q$, '%append-only%', 'which is again protected once the scan has finished');
end $$;
