-- Data retention: how long Duly keeps personal data, and the machinery to enforce it.
--
-- Principles
--   * Retention periods are policy decisions for Duly's data protection lead, so they live in a table (data_retention_rules) that Duly staff can
--     read and change in Admin → Data retention, not in code. Every rule is seeded SWITCHED OFF: nothing is cleared or deleted until a person has
--     reviewed the period and turned the rule on. A report shows what each rule would act on right now.
--   * Most rules clear the sensitive part of a record and keep the record (a visit keeps its time and whether it was on site; it loses the
--     coordinates). A few delete whole records that have no continuing purpose.
--   * A daily scan (private.apply_retention) applies the enabled rules in batches and logs what it did (data_retention_runs).
--   * Files in storage (photos, claim documents, brief source documents) cannot be removed from SQL: Supabase refuses direct deletes from its
--     storage tables. Their rule is report-only for now; removing the files needs a server job with the service role, which is not built yet.
--
-- The audit trail
--   audit_log is append-only and copied whole rows, so clearing a column in its source table would not have cleared the copy. This migration
--   (1) stops new copies of the most sensitive columns: photo coordinates, the reference and notes of a personal (DBS, right to work) claim, and
--   the text of a safeguarding report; and (2) lets rows older than SIX YEARS (the limitation period for contract disputes in England and Wales,
--   the reason the log exists) be purged by the retention scan and by nothing else. The six-year floor is in the trigger itself, so no rule can
--   shorten it and nothing else can delete a row.

-- ---------------------------------------------------------------------------
-- 1. The audit trail stops copying the most sensitive columns
-- ---------------------------------------------------------------------------
drop trigger audit_evidence on public.evidence;
create trigger audit_evidence after insert or update or delete on public.evidence
  for each row execute function private.audit_row('lat', 'lng');

-- A personal claim (about one person: DBS, right to work) is audited without its reference, notes and document path. A company claim is audited
-- in full, as before: its reference is the evidence in a dispute about what a vendor claimed.
create function private.audit_claim()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare v_personal boolean := coalesce(case when tg_op = 'DELETE' then old.subject_user_id else new.subject_user_id end) is not null;
begin
  perform private.audit_write(
    tg_table_name, tg_op,
    case when tg_op <> 'DELETE' then to_jsonb(new) end,
    case when tg_op <> 'INSERT' then to_jsonb(old) end,
    (select auth.uid()), clock_timestamp(), 'trigger',
    case when v_personal then array['reference', 'notes', 'evidence_path'] else '{}'::text[] end);
  return null;
end;
$$;
drop trigger audit_verification_claims on public.verification_claims;
create trigger audit_verification_claims after insert or update or delete on public.verification_claims
  for each row execute function private.audit_claim();

-- A safeguarding report is audited without its text: only the person who raised it and Duly may read it, and the audit log is wider than that.
create function private.audit_issue()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare v_safeguarding boolean := coalesce(case when tg_op = 'DELETE' then old.kind else new.kind end) = 'safeguarding';
begin
  perform private.audit_write(
    tg_table_name, tg_op,
    case when tg_op <> 'DELETE' then to_jsonb(new) end,
    case when tg_op <> 'INSERT' then to_jsonb(old) end,
    (select auth.uid()), clock_timestamp(), 'trigger',
    case when v_safeguarding then array['description', 'resolution'] else '{}'::text[] end);
  return null;
end;
$$;
drop trigger audit_issues on public.issues;
create trigger audit_issues after insert or update or delete on public.issues
  for each row execute function private.audit_issue();

-- The audit log stays append-only. The one exception: the retention scan may delete a row that is more than six years old.
create or replace function private.audit_log_immutable()
returns trigger language plpgsql set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    if current_setting('duly.audit_purge', true) = 'on' and old.at < now() - interval '6 years' then return old; end if;
  end if;
  raise exception 'The audit log is append-only';
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. The rules and the record of what was done
-- ---------------------------------------------------------------------------
create table public.data_retention_rules (
  id uuid not null default gen_random_uuid() unique,
  key text primary key,
  title text not null,
  description text not null,
  action text not null check (action in ('delete', 'clear', 'report')),
  months integer not null check (months between 1 and 240),
  enabled boolean not null default false,
  basis text not null default '',
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);
create index data_retention_rules_updated_by_idx on public.data_retention_rules (updated_by);
alter table public.data_retention_rules enable row level security;
create policy "retention rules for Duly staff" on public.data_retention_rules for select to authenticated using (private.is_platform_admin());
create trigger audit_data_retention_rules after update on public.data_retention_rules for each row execute function private.audit_row();

create table public.data_retention_runs (
  id bigint generated always as identity primary key,
  ran_at timestamptz not null default now(),
  rule_key text not null,
  action text not null,
  rows_affected integer not null,
  note text
);
alter table public.data_retention_runs enable row level security;
create policy "retention runs for Duly staff" on public.data_retention_runs for select to authenticated using (private.is_platform_admin());

insert into public.data_retention_rules (key, title, description, action, months, basis) values
  ('notifications_old', 'Old notifications', 'Delete in-app and email notifications older than this, read or not.', 'delete', 12,
   'Notifications carry no pay, amounts, addresses or safeguarding detail by design, and an inbox older than a year has no use. Read notifications are already tidied after 90 days.'),
  ('job_event_locations', 'Visit check-in locations', 'Remove the coordinates from check-in and check-out events older than this. The time, the kind of event and whether it was on site stay.', 'clear', 13,
   'A worker''s location is needed to show a visit was attended, and that question is settled within the dispute window; a year and a month covers an annual contract review. After that only the fact is kept, not the place.'),
  ('evidence_locations', 'Photo locations', 'Remove the coordinates from photos older than this. The photo, its time and whether it was taken on site stay.', 'clear', 13,
   'The same reasoning as visit locations: the on-site result is kept, the coordinates are not.'),
  ('ai_draft_sources', 'AI drafting sources', 'Remove the pasted text or document reference a brief draft was made from, once the draft has been approved or rejected and is older than this.', 'clear', 6,
   'The source is only needed while a person reviews the draft. It can contain anything the person pasted, including personal data about third parties.'),
  ('dbs_application_forms', 'DBS application forms', 'Remove the form data, notes, certificate reference and update-service id from a finished DBS application (cleared, not cleared or withdrawn) older than this. The outcome stays.', 'clear', 12,
   'Criminal-record-check material is kept no longer than needed to act on the result. The worker''s cleared flag and the application''s outcome and dates are enough afterwards.'),
  ('personal_claims', 'Expired personal claims', 'Delete a claim about one person (DBS, right to work) that was rejected or expired, or whose validity ended, more than this long ago.', 'delete', 12,
   'A lapsed personal claim has no continuing purpose. Company claims are never touched by this rule.'),
  ('evidence_photos', 'Old photos', 'Report how many photos are older than this. Removing the files themselves needs the storage job, which is not built yet, so this rule only counts.', 'report', 24,
   'Photos are the record of the work and are kept as long as an Enterprise may need them for a review or dispute; this period is a proposal to agree with Enterprises.'),
  ('audit_log', 'Audit log', 'Delete audit entries older than this. The database will not delete one younger than six years whatever this says.', 'delete', 72,
   'The audit log exists to evidence disputes; six years is the limitation period for contract claims in England and Wales.');

-- ---------------------------------------------------------------------------
-- 3. What is due, and doing it
-- ---------------------------------------------------------------------------
create function private.retention_due(p_key text, p_months integer)
returns bigint language plpgsql stable security definer set search_path = ''
as $$
declare v_cut timestamptz := now() - make_interval(months => p_months); n bigint;
begin
  case p_key
    when 'notifications_old' then
      select count(*) into n from public.notifications where created_at < v_cut;
    when 'job_event_locations' then
      select count(*) into n from public.job_events where at < v_cut and (lat is not null or lng is not null);
    when 'evidence_locations' then
      select count(*) into n from public.evidence where taken_at < v_cut and (lat is not null or lng is not null);
    when 'ai_draft_sources' then
      select count(*) into n from public.approval_queue where status <> 'pending' and created_at < v_cut and source <> '{}'::jsonb;
    when 'dbs_application_forms' then
      select count(*) into n from public.dbs_applications
       where status in ('cleared', 'not_cleared', 'withdrawn') and created_at < v_cut
         and (form_data <> '{}'::jsonb or admin_notes is not null or certificate_reference is not null or update_service_id is not null);
    when 'personal_claims' then
      select count(*) into n from public.verification_claims
       where subject_user_id is not null and created_at < v_cut
         and (status in ('rejected', 'expired') or (valid_until is not null and valid_until < v_cut::date));
    when 'evidence_photos' then
      select count(*) into n from public.evidence where taken_at < v_cut;
    when 'audit_log' then
      select count(*) into n from public.audit_log where at < v_cut and at < now() - interval '6 years';
    else
      n := 0;
  end case;
  return n;
end;
$$;

-- Acts on one rule, in batches of 5000 so a first run on a lot of old data cannot hold a lock for long. Returns the rows it changed.
create function private.retention_apply(p_key text, p_months integer)
returns bigint language plpgsql security definer set search_path = ''
as $$
declare v_cut timestamptz := now() - make_interval(months => p_months); n bigint := 0;
begin
  case p_key
    when 'notifications_old' then
      delete from public.notifications where id in (select id from public.notifications where created_at < v_cut order by created_at limit 5000);
    when 'job_event_locations' then
      update public.job_events set lat = null, lng = null
       where id in (select id from public.job_events where at < v_cut and (lat is not null or lng is not null) order by at limit 5000);
    when 'evidence_locations' then
      update public.evidence set lat = null, lng = null
       where id in (select id from public.evidence where taken_at < v_cut and (lat is not null or lng is not null) order by taken_at limit 5000);
    when 'ai_draft_sources' then
      update public.approval_queue set source = '{}'::jsonb
       where id in (select id from public.approval_queue where status <> 'pending' and created_at < v_cut and source <> '{}'::jsonb order by created_at limit 5000);
    when 'dbs_application_forms' then
      update public.dbs_applications set form_data = '{}'::jsonb, admin_notes = null, certificate_reference = null, update_service_id = null
       where id in (select id from public.dbs_applications
                     where status in ('cleared', 'not_cleared', 'withdrawn') and created_at < v_cut
                       and (form_data <> '{}'::jsonb or admin_notes is not null or certificate_reference is not null or update_service_id is not null)
                     order by created_at limit 5000);
    when 'personal_claims' then
      delete from public.verification_claims
       where id in (select id from public.verification_claims
                     where subject_user_id is not null and created_at < v_cut
                       and (status in ('rejected', 'expired') or (valid_until is not null and valid_until < v_cut::date))
                     order by created_at limit 5000);
    when 'audit_log' then
      perform set_config('duly.audit_purge', 'on', true);
      delete from public.audit_log where id in (select id from public.audit_log where at < v_cut and at < now() - interval '6 years' order by at limit 5000);
      perform set_config('duly.audit_purge', 'off', true);
    else
      return 0;   -- report-only rules, and anything unknown, change nothing
  end case;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- The daily scan: every enabled rule that acts (not report-only). Each is separate, so one failing does not stop the rest. Returns rows changed.
create function private.apply_retention()
returns bigint language plpgsql security definer set search_path = ''
as $$
declare r record; v_rows bigint; v_total bigint := 0;
begin
  for r in select * from public.data_retention_rules where enabled and action <> 'report' order by key loop
    begin
      v_rows := private.retention_apply(r.key, r.months);
      v_total := v_total + v_rows;
      if v_rows > 0 then
        insert into public.data_retention_runs (rule_key, action, rows_affected) values (r.key, r.action, v_rows);
      end if;
    exception when others then
      insert into public.data_retention_runs (rule_key, action, rows_affected, note) values (r.key, r.action, 0, left('failed: ' || sqlerrm, 300));
      raise warning 'retention rule % failed: %', r.key, sqlerrm;
    end;
  end loop;
  return v_total;
end;
$$;

-- For Duly staff: each rule, what it would act on right now, and when it last did anything.
create function public.admin_retention_report()
returns table (key text, title text, description text, action text, months integer, enabled boolean, basis text,
               due_now bigint, last_run_at timestamptz, last_rows integer)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.is_platform_admin() then raise exception 'Only Duly staff see the data retention rules'; end if;
  return query
  select r.key, r.title, r.description, r.action, r.months, r.enabled, r.basis,
         private.retention_due(r.key, r.months),
         (select max(u.ran_at) from public.data_retention_runs u where u.rule_key = r.key and u.note is null),
         (select u.rows_affected from public.data_retention_runs u where u.rule_key = r.key and u.note is null order by u.ran_at desc, u.id desc limit 1)
    from public.data_retention_rules r
   order by r.title;
end;
$$;

-- For Duly staff: change a rule's period and switch it on or off.
create function public.admin_set_retention_rule(p_key text, p_months integer, p_enabled boolean)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not private.is_platform_admin() then raise exception 'Only Duly staff change the data retention rules'; end if;
  if p_months is null or p_months < 1 or p_months > 240 then raise exception 'A retention period is between 1 and 240 months'; end if;
  if p_key = 'audit_log' and p_months < 72 then raise exception 'The audit log is kept for at least six years (72 months)'; end if;
  update public.data_retention_rules set months = p_months, enabled = coalesce(p_enabled, false), updated_by = (select auth.uid()), updated_at = now() where key = p_key;
  if not found then raise exception 'No retention rule called %', p_key; end if;
end;
$$;

revoke execute on function private.retention_due(text, integer), private.retention_apply(text, integer), private.apply_retention(),
  private.audit_claim(), private.audit_issue() from public, anon, authenticated;
revoke execute on function public.admin_retention_report(), public.admin_set_retention_rule(text, integer, boolean) from public, anon;
grant execute on function public.admin_retention_report(), public.admin_set_retention_rule(text, integer, boolean) to authenticated;

-- Run the scan once a day where pg_cron is available (it is on Supabase). Elsewhere (a plain Postgres, the test database) it is skipped and
-- the scan is called directly.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    if exists (select 1 from cron.job where jobname = 'duly-apply-retention') then
      perform cron.unschedule('duly-apply-retention');
    end if;
    perform cron.schedule('duly-apply-retention', '45 3 * * *', 'select private.apply_retention()');
  end if;
end $$;
