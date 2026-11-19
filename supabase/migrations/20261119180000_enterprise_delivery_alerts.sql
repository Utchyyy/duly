-- Tell an Enterprise when a vendor's clean is late or missed.
--
-- The scheduled scan (private.notify_due_items, every five minutes) now also notifies the Enterprise's owner and approvers, once for each
-- visit, when a booked visit has gone past its lateness tolerance with nobody checked in ("late") and again if the planned end passes with
-- nobody ever checking in ("missed"). It uses the same rules as the Enterprise delivery view and the vendor dispatch board, so what the
-- notification says is what Delivery shows. Notifications are in the "jobs" category, so the email mute people already have applies.
-- This replaces the whole function, built on its latest definition; everything else in the scan is unchanged.

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

  -- An Enterprise's own view of a visit that is not happening: late (past the tolerance, before the planned end) and missed (the planned
  -- end has passed and nobody ever checked in). The same rules as the Enterprise delivery view; the Enterprise's owner and approvers are told
  -- once for each. Visits more than a day past their end are left alone so switching this on does not announce old history. These notes
  -- name the vendor and the site and say what happened; they carry no pay, price, address or crew name, and a failure here never stops the scan.
  begin
    for r in select j.id, j.scheduled_start, j.scheduled_end, j.buyer_org_id, j.vendor_org_id, s.name as site_name, vo.name as vendor_name,
                    coalesce(bv.lateness_tolerance_min, (private.policy_for_org(j.buyer_org_id)).lateness_tolerance_min, 15) as tol
             from public.jobs j
             join public.sites s on s.id = j.site_id
             join public.organisations vo on vo.id = j.vendor_org_id
             left join public.brief_versions bv on bv.brief_id = j.brief_id and bv.version = j.brief_version
             where j.status in ('matched', 'en_route', 'requested') and private.is_enterprise(j.buyer_org_id)
               and j.scheduled_end > now() - interval '24 hours' and j.scheduled_start < now()
               and not exists (select 1 from public.job_events e where e.job_id = j.id and e.kind = 'check_in') loop
      if now() >= r.scheduled_end then
        perform private.notify_org(r.buyer_org_id, array['owner', 'approver']::public.member_role[], 'jobs', 'delivery_missed',
          'A clean was missed',
          format('%s did not check in for the clean at %s %s.', r.vendor_name, r.site_name, private.local_when(r.scheduled_start, r.buyer_org_id)),
          '/enterprise/delivery', 'ent-missed:' || r.id);
      elsif now() >= r.scheduled_start + make_interval(mins => r.tol) then
        perform private.notify_org(r.buyer_org_id, array['owner', 'approver']::public.member_role[], 'jobs', 'delivery_late',
          'A clean is late',
          format('%s has not checked in for the clean at %s %s.', r.vendor_name, r.site_name, private.local_when(r.scheduled_start, r.buyer_org_id)),
          '/enterprise/delivery', 'ent-late:' || r.id);
      end if;
    end loop;
  exception when others then
    raise warning 'notification (enterprise delivery) failed: %', sqlerrm;
  end;

  -- Tidy: read notifications older than 90 days.
  delete from public.notifications where read_at is not null and created_at < now() - interval '90 days';
end;
$$;

revoke execute on function private.notify_due_items() from public, anon, authenticated;
