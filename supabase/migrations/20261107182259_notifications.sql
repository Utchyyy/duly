-- Notifications: an in-app inbox plus email, for the moments people are waiting on each other.
--
-- Rules this follows:
--   * Every notification is created in SQL, by triggers on the real events and by a scheduled scan, so what
--     gets sent is deterministic and testable. Nothing here is written by a model.
--   * A notification can never block the action it reports: the trigger functions swallow their own errors.
--   * Text carries no staff pay, amounts, street addresses, access notes or safeguarding detail. Email goes
--     through a third party, so bodies say what happened and link into the app for the rest.
--   * People can read their own notifications and mark them read. They cannot create, edit or delete them.

create table public.notification_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email_enabled boolean not null default true,
  email_muted text[] not null default '{}',
  updated_at timestamptz not null default now(),
  -- Problems and disputes can't be switched off by email: they carry deadlines.
  check (email_muted <@ array['quotes', 'jobs', 'payments', 'shifts', 'verification', 'reminders'])
);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  org_id uuid references public.organisations(id) on delete set null,
  category text not null check (category in ('quotes', 'jobs', 'payments', 'issues', 'shifts', 'verification', 'reminders')),
  event text not null,
  title text not null check (length(title) <= 120),
  body text not null default '' check (length(body) <= 400),
  link text check (link is null or (link like '/%' and link not like '//%')),
  dedupe_key text,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  -- Email outbox: pending -> sending -> sent, or back to pending with a delay, or failed after 5 tries.
  email_status text not null default 'none' check (email_status in ('none', 'pending', 'sending', 'sent', 'failed', 'skipped')),
  email_attempts smallint not null default 0,
  email_next_at timestamptz,
  email_sent_at timestamptz,
  email_error text
);
create index notifications_user_idx on public.notifications (user_id, created_at desc);
create index notifications_unread_idx on public.notifications (user_id) where read_at is null;
create index notifications_org_idx on public.notifications (org_id);
create index notifications_email_idx on public.notifications (email_next_at) where email_status in ('pending', 'sending');
create unique index notifications_dedupe_idx on public.notifications (user_id, dedupe_key) where dedupe_key is not null;

alter table public.notification_settings enable row level security;
alter table public.notifications enable row level security;

create policy "notification settings own" on public.notification_settings for select to authenticated
  using (user_id = (select auth.uid()));
create policy "notification settings added" on public.notification_settings for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy "notification settings changed" on public.notification_settings for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "notifications own" on public.notifications for select to authenticated
  using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- Making notifications
-- ---------------------------------------------------------------------------
create function private.notify(
  p_user uuid, p_org uuid, p_category text, p_event text, p_title text, p_body text, p_link text, p_dedupe text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare s public.notification_settings; v_email boolean;
begin
  if p_user is null then return; end if;
  select * into s from public.notification_settings where user_id = p_user;
  v_email := coalesce(s.email_enabled, true) and not (p_category = any (coalesce(s.email_muted, '{}')));
  insert into public.notifications (user_id, org_id, category, event, title, body, link, dedupe_key, email_status, email_next_at)
  values (p_user, p_org, p_category, p_event, left(p_title, 120), left(coalesce(p_body, ''), 400), p_link, p_dedupe,
          case when v_email then 'pending' else 'skipped' end, case when v_email then now() end)
  on conflict (user_id, dedupe_key) where dedupe_key is not null do nothing;
end;
$$;

create function private.notify_org(
  p_org uuid, p_roles public.member_role[], p_category text, p_event text, p_title text, p_body text, p_link text,
  p_dedupe text default null, p_except uuid default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare r record;
begin
  for r in select distinct m.user_id from public.memberships m
           where m.org_id = p_org and m.role = any (p_roles) and m.user_id is distinct from p_except loop
    perform private.notify(r.user_id, p_org, p_category, p_event, p_title, p_body, p_link, p_dedupe);
  end loop;
end;
$$;

create function private.notify_admins(
  p_category text, p_event text, p_title text, p_body text, p_link text, p_dedupe text default null, p_except uuid default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare r record;
begin
  for r in select distinct m.user_id from public.memberships m where m.role = 'platform_admin' and m.user_id is distinct from p_except loop
    perform private.notify(r.user_id, null, p_category, p_event, p_title, p_body, p_link, p_dedupe);
  end loop;
end;
$$;

-- "Tue 10 Nov at 18:00" in the market's own timezone (never a hard-coded one).
create function private.local_when(p_at timestamptz, p_org uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select to_char(p_at at time zone coalesce((select m.timezone from public.organisations o join public.markets m on m.code = o.market where o.id = p_org), 'UTC'),
                 'Dy FMDD Mon "at" HH24:MI');
$$;

create function private.org_name(p_org uuid)
returns text language sql stable security definer set search_path = ''
as $$ select coalesce((select name from public.organisations where id = p_org), 'Someone') $$;

-- ---------------------------------------------------------------------------
-- Event triggers. Each one is wrapped so a notification problem is a warning, never a failed business action.
-- ---------------------------------------------------------------------------
create function private.notify_quote_change()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare v_title text; v_buyer uuid;
begin
  begin
    select b.title, b.buyer_org_id into v_title, v_buyer from public.briefs b where b.id = new.brief_id;
    if tg_op = 'INSERT' then
      if new.status = 'invited' then
        perform private.notify_org(new.vendor_org_id, array['vendor_admin', 'dispatcher']::public.member_role[], 'quotes', 'quote_requested',
          'New quote request', format('%s asked you to quote for "%s".', private.org_name(v_buyer), v_title), '/pro/quotes',
          'quote-req:' || new.id, (select auth.uid()));
      end if;
    elsif new.status is distinct from old.status then
      if new.status = 'submitted' then
        perform private.notify_org(v_buyer, array['owner', 'approver']::public.member_role[], 'quotes', 'quote_submitted',
          'A quote has arrived', format('%s quoted for "%s".', private.org_name(new.vendor_org_id), v_title), '/briefs/' || new.brief_id,
          'quote-sub:' || new.id || ':' || extract(epoch from coalesce(new.submitted_at, now()))::bigint, (select auth.uid()));
      elsif new.status = 'accepted' then
        perform private.notify_org(new.vendor_org_id, array['vendor_admin', 'dispatcher']::public.member_role[], 'quotes', 'quote_accepted',
          'Your quote was accepted', format('%s accepted your quote for "%s".', private.org_name(v_buyer), v_title), '/pro/jobs',
          'quote-acc:' || new.id, (select auth.uid()));
      elsif new.status = 'declined' and old.status in ('invited', 'submitted') and not private.is_vendor_staff(new.vendor_org_id) then
        perform private.notify_org(new.vendor_org_id, array['vendor_admin', 'dispatcher']::public.member_role[], 'quotes', 'quote_lost',
          'The client chose another vendor', format('Your quote for "%s" was not chosen this time.', v_title), '/pro/quotes',
          'quote-lost:' || new.id);
      end if;
    end if;
  exception when others then
    raise warning 'notification (quote) failed: %', sqlerrm;
  end;
  return null;
end;
$$;
create trigger quotes_notify after insert or update of status on public.quotes
  for each row execute function private.notify_quote_change();

create function private.notify_job_change()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare v_when text;
begin
  begin
    v_when := private.local_when(new.scheduled_start, new.buyer_org_id);
    if new.status = 'completed' then
      perform private.notify_org(new.buyer_org_id, array['owner', 'approver']::public.member_role[], 'jobs', 'job_completed',
        'Ready for you to check', format('The clean on %s is finished. Look at the photos and mark each standard.', v_when), '/jobs/' || new.id,
        'job-done:' || new.id, (select auth.uid()));
    elsif new.status = 'quality_verified' then
      perform private.notify_org(new.vendor_org_id, array['vendor_admin', 'dispatcher']::public.member_role[], 'jobs', 'job_approved',
        'The client approved the clean', format('The clean on %s was approved. Payments are scheduled.', v_when), '/pro/payouts',
        'job-ok:' || new.id, (select auth.uid()));
    elsif new.status = 'paid' then
      perform private.notify_org(new.vendor_org_id, array['vendor_admin', 'dispatcher']::public.member_role[], 'payments', 'job_paid',
        'Payment recorded', format('Everything for the clean on %s has been paid.', v_when), '/pro/payouts', 'job-paid:' || new.id);
    elsif new.status = 'cancelled' then
      perform private.notify_org(new.vendor_org_id, array['vendor_admin', 'dispatcher']::public.member_role[], 'jobs', 'job_cancelled',
        'A clean was cancelled', format('The clean on %s was cancelled.', v_when), '/pro/jobs', 'job-x:' || new.id, (select auth.uid()));
      perform private.notify(a.user_id, new.vendor_org_id, 'jobs', 'job_cancelled', 'A clean was cancelled',
        format('The clean on %s was cancelled.', v_when), '/crew', 'job-x:' || new.id)
      from public.job_assignments a where a.job_id = new.id;
    end if;
  exception when others then
    raise warning 'notification (job) failed: %', sqlerrm;
  end;
  return null;
end;
$$;
create trigger jobs_notify after update of status on public.jobs
  for each row when (new.status is distinct from old.status) execute function private.notify_job_change();

create function private.notify_assignment()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare j public.jobs;
begin
  begin
    select * into j from public.jobs where id = new.job_id;
    perform private.notify(new.user_id, j.vendor_org_id, 'jobs', 'job_assigned', 'You have a clean to do',
      format('You are on the clean %s.', private.local_when(j.scheduled_start, j.buyer_org_id)), '/crew/' || j.id,
      'assigned:' || new.job_id || ':' || new.user_id);
  exception when others then
    raise warning 'notification (assignment) failed: %', sqlerrm;
  end;
  return null;
end;
$$;
create trigger job_assignments_notify after insert on public.job_assignments
  for each row execute function private.notify_assignment();

create function private.notify_issue()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare j public.jobs; v_when text;
begin
  begin
    if new.job_id is not null then
      select * into j from public.jobs where id = new.job_id;
      v_when := private.local_when(j.scheduled_start, j.buyer_org_id);
    end if;
    if tg_op = 'INSERT' then
      if new.kind = 'safeguarding' then
        -- Safeguarding reports are visible only to the person who raised them and to Duly: say nothing more.
        perform private.notify_admins('issues', 'safeguarding_raised', 'A safeguarding concern was raised', 'Open the issues list to review it.',
          '/admin/issues', 'issue-new:' || new.id, new.raised_by);
      else
        if new.job_id is not null then
          perform private.notify_org(j.vendor_org_id, array['vendor_admin', 'dispatcher']::public.member_role[], 'issues', 'issue_raised',
            'A problem was reported', format('A problem was reported on the clean on %s. Please respond.', v_when), '/pro/jobs',
            'issue-new:' || new.id, new.raised_by);
        end if;
        perform private.notify_admins('issues', 'issue_raised', 'A new issue to track', 'A problem was reported. The money is on hold.',
          '/admin/issues', 'issue-new:' || new.id, new.raised_by);
      end if;
    elsif new.status is distinct from old.status then
      if new.status = 'resolved' then
        perform private.notify(new.raised_by, null, 'issues', 'issue_resolved', 'Your report was resolved',
          'The problem you reported has been marked resolved.', coalesce('/jobs/' || new.job_id, '/'), 'issue-res:' || new.id);
        if new.kind <> 'safeguarding' and new.job_id is not null then
          perform private.notify_org(j.vendor_org_id, array['vendor_admin', 'dispatcher']::public.member_role[], 'issues', 'issue_resolved',
            'A problem was resolved', format('The problem on the clean on %s was resolved.', v_when), '/pro/jobs', 'issue-res:' || new.id);
        end if;
      else
        perform private.notify(new.raised_by, null, 'issues', 'issue_updated', 'Your report is being handled',
          format('Status: %s.', replace(new.status::text, '_', ' ')), coalesce('/jobs/' || new.job_id, '/'),
          'issue-upd:' || new.id || ':' || new.status);
      end if;
    end if;
  exception when others then
    raise warning 'notification (issue) failed: %', sqlerrm;
  end;
  return null;
end;
$$;
create trigger issues_notify after insert or update of status on public.issues
  for each row execute function private.notify_issue();

create function private.notify_shift_event()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare w public.workers; s public.shifts;
begin
  begin
    select * into w from public.workers where id = new.worker_id;
    select * into s from public.shifts where id = new.shift_id;
    if new.event_type = 'offered' then
      -- No pay and no address: those are for the person to see in the app.
      perform private.notify(w.user_id, s.vendor_org_id, 'shifts', 'shift_offered', 'A shift is on offer',
        'Open Duly Crew to see it and reply.', '/crew', 'shift-off:' || new.shift_id || ':' || new.worker_id);
    elsif new.event_type in ('accepted', 'declined') then
      perform private.notify_org(s.vendor_org_id, array['vendor_admin', 'dispatcher']::public.member_role[], 'shifts', 'shift_' || new.event_type,
        'A worker ' || new.event_type || ' a shift', format('%s %s a shift you offered.', w.full_name, new.event_type), '/pro/shifts',
        'shift-' || new.event_type || ':' || new.shift_id || ':' || new.worker_id, (select auth.uid()));
    end if;
  exception when others then
    raise warning 'notification (shift) failed: %', sqlerrm;
  end;
  return null;
end;
$$;
create trigger shift_events_notify after insert on public.shift_events
  for each row execute function private.notify_shift_event();

create function private.notify_dbs()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare w public.workers;
begin
  begin
    select * into w from public.workers where id = new.worker_id;
    if tg_op = 'INSERT' then
      perform private.notify_admins('verification', 'dbs_submitted', 'A DBS application to review', format('%s submitted a DBS application.', w.full_name),
        '/admin/workers', 'dbs-new:' || new.id, (select auth.uid()));
    elsif new.status is distinct from old.status and new.status in ('cleared', 'not_cleared') then
      perform private.notify(w.user_id, w.vendor_org_id, 'verification', 'dbs_decided',
        case new.status when 'cleared' then 'Your DBS check is cleared' else 'Your DBS check could not be cleared' end,
        'Open Duly Crew for the details.', '/crew', 'dbs-dec:' || new.id || ':' || new.status);
    end if;
  exception when others then
    raise warning 'notification (dbs) failed: %', sqlerrm;
  end;
  return null;
end;
$$;
create trigger dbs_applications_notify after insert or update of status on public.dbs_applications
  for each row execute function private.notify_dbs();

create function private.notify_claim()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare v_what text := replace(new.kind::text, '_', ' ');
begin
  begin
    if tg_op = 'INSERT' then
      if new.status in ('self_declared', 'pending') then
        perform private.notify_admins('verification', 'claim_submitted', 'Something to verify',
          format('%s submitted %s for checking.', private.org_name(new.org_id), v_what), '/admin/verification', 'claim-new:' || new.id, (select auth.uid()));
      end if;
    elsif new.status is distinct from old.status and new.status in ('verified', 'rejected', 'expired') then
      if new.subject_user_id is not null then
        perform private.notify(new.subject_user_id, new.org_id, 'verification', 'claim_' || new.status, format('Your %s was %s', v_what, new.status),
          'Open Duly Crew for the details.', '/crew', 'claim-dec:' || new.id || ':' || new.status);
      else
        perform private.notify_org(new.org_id, array['vendor_admin', 'dispatcher']::public.member_role[], 'verification', 'claim_' || new.status,
          format('Your %s was %s', v_what, new.status), 'Open Verification for the details.', '/pro/verification',
          'claim-dec:' || new.id || ':' || new.status, (select auth.uid()));
      end if;
    end if;
  exception when others then
    raise warning 'notification (claim) failed: %', sqlerrm;
  end;
  return null;
end;
$$;
create trigger verification_claims_notify after insert or update of status on public.verification_claims
  for each row execute function private.notify_claim();

revoke execute on all functions in schema private from public, anon;
revoke execute on function
  private.notify(uuid, uuid, text, text, text, text, text, text),
  private.notify_org(uuid, public.member_role[], text, text, text, text, text, text, uuid),
  private.notify_admins(text, text, text, text, text, text, uuid),
  private.notify_quote_change(), private.notify_job_change(), private.notify_assignment(), private.notify_issue(),
  private.notify_shift_event(), private.notify_dbs(), private.notify_claim()
  from authenticated;

-- ---------------------------------------------------------------------------
-- The scan for things that happen because time passed. Safe to run as often as you like: every
-- notification has a dedupe key. Scheduled with pg_cron below where that extension exists.
-- ---------------------------------------------------------------------------
create function private.notify_due_items()
returns void language plpgsql security definer set search_path = ''
as $$
declare r record; v_pol public.policies; v_tol integer; v_count integer;
begin
  -- Crew: a clean in the next 24 hours.
  for r in select j.id, j.scheduled_start, j.buyer_org_id, j.vendor_org_id, a.user_id
           from public.jobs j join public.job_assignments a on a.job_id = j.id
           where j.status = 'matched' and j.scheduled_start > now() and j.scheduled_start <= now() + interval '24 hours' loop
    perform private.notify(r.user_id, r.vendor_org_id, 'reminders', 'clean_soon', 'A clean is coming up',
      format('You are on the clean %s.', private.local_when(r.scheduled_start, r.buyer_org_id)), '/crew/' || r.id, 'remind:' || r.id || ':' || r.user_id);
  end loop;

  -- Vendor: a clean in the next 24 hours with nobody assigned.
  for r in select j.id, j.scheduled_start, j.buyer_org_id, j.vendor_org_id from public.jobs j
           where j.status = 'matched' and j.scheduled_start > now() and j.scheduled_start <= now() + interval '24 hours'
             and not exists (select 1 from public.job_assignments a where a.job_id = j.id) loop
    perform private.notify_org(r.vendor_org_id, array['vendor_admin', 'dispatcher']::public.member_role[], 'jobs', 'unassigned',
      'Nobody is assigned yet', format('The clean %s has no cleaner assigned.', private.local_when(r.scheduled_start, r.buyer_org_id)),
      '/pro/jobs', 'unassigned:' || r.id);
  end loop;

  -- Late: past the lateness tolerance with no check-in. Records a late_alert on the job as well.
  for r in select j.id, j.scheduled_start, j.buyer_org_id, j.vendor_org_id, bv.lateness_tolerance_min
           from public.jobs j join public.brief_versions bv on bv.brief_id = j.brief_id and bv.version = j.brief_version
           where j.status in ('matched', 'en_route') and j.scheduled_start < now() and j.scheduled_start > now() - interval '12 hours'
             and not exists (select 1 from public.job_events e where e.job_id = j.id and e.kind = 'check_in') loop
    v_pol := private.policy_for_org(r.buyer_org_id);
    v_tol := coalesce(r.lateness_tolerance_min, v_pol.lateness_tolerance_min, 15);
    continue when now() < r.scheduled_start + make_interval(mins => v_tol);
    if not exists (select 1 from public.job_events where job_id = r.id and kind = 'late_alert') then
      insert into public.job_events (job_id, kind, data) values (r.id, 'late_alert', jsonb_build_object('tolerance_min', v_tol));
    end if;
    perform private.notify_org(r.vendor_org_id, array['vendor_admin', 'dispatcher']::public.member_role[], 'jobs', 'late',
      'Nobody has checked in yet', format('The clean %s has not been checked into.', private.local_when(r.scheduled_start, r.buyer_org_id)),
      '/pro/jobs', 'late:' || r.id);
    perform private.notify(a.user_id, r.vendor_org_id, 'jobs', 'late', 'Please check in',
      format('The clean %s has not been checked into yet.', private.local_when(r.scheduled_start, r.buyer_org_id)), '/crew/' || r.id, 'late:' || r.id || ':' || a.user_id)
    from public.job_assignments a where a.job_id = r.id;
  end loop;

  -- Issues: the response deadline is close, or has passed. Safeguarding goes to Duly only.
  for r in select i.id, i.kind, i.sla_due_at, i.job_id, j.vendor_org_id, j.buyer_org_id
           from public.issues i left join public.jobs j on j.id = i.job_id
           where i.status <> 'resolved' and i.sla_due_at is not null and i.sla_due_at <= now() + interval '2 hours' loop
    if r.sla_due_at <= now() then
      perform private.notify_admins('issues', 'issue_overdue', 'An issue is overdue', 'An issue has passed its response deadline.', '/admin/issues', 'issue-late:' || r.id);
      if r.kind <> 'safeguarding' and r.vendor_org_id is not null then
        perform private.notify_org(r.vendor_org_id, array['vendor_admin', 'dispatcher']::public.member_role[], 'issues', 'issue_overdue',
          'A problem is overdue', 'A reported problem has passed its response deadline.', '/pro/jobs', 'issue-late:' || r.id);
      end if;
    else
      perform private.notify_admins('issues', 'issue_due_soon', 'An issue is due soon', 'An issue is close to its response deadline.', '/admin/issues', 'issue-soon:' || r.id);
      if r.kind <> 'safeguarding' and r.vendor_org_id is not null then
        perform private.notify_org(r.vendor_org_id, array['vendor_admin', 'dispatcher']::public.member_role[], 'issues', 'issue_due_soon',
          'A problem needs a response soon', 'A reported problem is close to its response deadline.', '/pro/jobs', 'issue-soon:' || r.id);
      end if;
    end if;
  end loop;

  -- Money the client owes: a hold, a monthly debit or an invoice that has come due.
  for r in select p.id, p.kind, coalesce(j.buyer_org_id, c.buyer_org_id) as buyer_org_id, p.job_id
           from public.payments p
           left join public.jobs j on j.id = p.job_id left join public.contracts c on c.id = p.contract_id
           where p.status = 'pending' and p.kind in ('escrow_hold', 'direct_debit', 'invoice') and p.due_at is not null and p.due_at <= now() loop
    continue when r.buyer_org_id is null;
    perform private.notify_org(r.buyer_org_id, array['owner', 'approver']::public.member_role[], 'payments', 'payment_due', 'A payment is due',
      case r.kind when 'escrow_hold' then 'Money for a clean needs to be paid into escrow.' when 'direct_debit' then 'Your monthly plan payment is due.' else 'An invoice has come due.' end,
      coalesce('/jobs/' || r.job_id, '/business'), 'pay-due:' || r.id);
  end loop;

  -- Money for Duly to record: one note a day, not one per payment.
  select count(*) into v_count from public.payments p left join public.jobs j on j.id = p.job_id
   where p.status = 'pending' and p.kind in ('release', 'platform_fee') and p.due_at is not null and p.due_at <= now()
     and coalesce(j.status::text, '') <> 'disputed';
  if v_count > 0 then
    perform private.notify_admins('payments', 'payments_to_record', 'Payments are due to be recorded',
      format('%s payment%s due to be recorded in the ledger.', v_count, case when v_count = 1 then ' is' else 's are' end), '/admin/payments',
      'admin-due:' || to_char(now(), 'YYYY-MM-DD'));
  end if;

  -- Tidy: read notifications older than 90 days.
  delete from public.notifications where read_at is not null and created_at < now() - interval '90 days';
end;
$$;
revoke execute on function private.notify_due_items() from public, anon, authenticated;

-- Run the scan every five minutes where pg_cron is available (it is on Supabase). Elsewhere (a plain Postgres,
-- the test database) this is skipped and the scan is called directly.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    if exists (select 1 from cron.job where jobname = 'duly-notify-due-items') then
      perform cron.unschedule('duly-notify-due-items');
    end if;
    perform cron.schedule('duly-notify-due-items', '*/5 * * * *', 'select private.notify_due_items()');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- For people
-- ---------------------------------------------------------------------------
create function public.mark_notifications_read(p_ids uuid[] default null)
returns integer language plpgsql security definer set search_path = ''
as $$
declare n integer;
begin
  if (select auth.uid()) is null then raise exception 'Sign in first'; end if;
  update public.notifications set read_at = now()
   where user_id = (select auth.uid()) and read_at is null and (p_ids is null or id = any (p_ids));
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke execute on function public.mark_notifications_read(uuid[]) from public, anon;
grant execute on function public.mark_notifications_read(uuid[]) to authenticated;

-- ---------------------------------------------------------------------------
-- For the email worker (the server, using the service role). Nobody else can call these.
-- ---------------------------------------------------------------------------
create function public.worker_claim_notification_emails(p_limit integer default 20)
returns table (id uuid, email text, title text, body text, link text, category text, created_at timestamptz)
language plpgsql security definer set search_path = ''
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'Only the notification worker can do this'; end if;
  -- Too old to be useful after an outage, or nowhere to send: don't.
  update public.notifications n set email_status = 'skipped', email_error = 'too old to send', email_next_at = null
   where n.email_status in ('pending', 'sending') and n.created_at < now() - interval '48 hours';
  update public.notifications n set email_status = 'skipped', email_error = 'no email address', email_next_at = null
   where n.email_status in ('pending', 'sending')
     and not exists (select 1 from auth.users u where u.id = n.user_id and u.email is not null);
  return query
    with due as (
      select n.id from public.notifications n
       where n.email_status in ('pending', 'sending') and n.email_next_at <= now()
       order by n.created_at
       limit greatest(1, least(coalesce(p_limit, 20), 100))
       for update skip locked),
    claimed as (
      update public.notifications n
         set email_status = 'sending', email_attempts = n.email_attempts + 1, email_next_at = now() + interval '10 minutes'
        from due where n.id = due.id
      returning n.id, n.user_id, n.title, n.body, n.link, n.category, n.created_at)
    select c.id, u.email::text, c.title, c.body, c.link, c.category, c.created_at
      from claimed c join auth.users u on u.id = c.user_id;
end;
$$;

create function public.worker_finish_notification_email(p_id uuid, p_sent boolean, p_error text default null)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'Only the notification worker can do this'; end if;
  update public.notifications n set
    email_status = case when p_sent then 'sent' when n.email_attempts >= 5 then 'failed' else 'pending' end,
    email_sent_at = case when p_sent then now() end,
    email_error = case when p_sent then null else left(coalesce(p_error, 'send failed'), 300) end,
    email_next_at = case when p_sent or n.email_attempts >= 5 then null
                         else now() + make_interval(mins => least(n.email_attempts * n.email_attempts * 5, 120)) end
   where n.id = p_id and n.email_status = 'sending';
end;
$$;
revoke execute on function public.worker_claim_notification_emails(integer), public.worker_finish_notification_email(uuid, boolean, text) from public, anon, authenticated;
grant execute on function public.worker_claim_notification_emails(integer), public.worker_finish_notification_email(uuid, boolean, text) to service_role;
