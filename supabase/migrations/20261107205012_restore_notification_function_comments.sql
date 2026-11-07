-- Restores the explanatory comments inside four notification functions. The code is unchanged: the live
-- copies were created without their inline comments, so this re-creates them from the original definitions.

create or replace function private.notify_issue()
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

create or replace function private.notify_shift_event()
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

create or replace function private.notify_due_items()
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

create or replace function public.worker_claim_notification_emails(p_limit integer default 20)
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
