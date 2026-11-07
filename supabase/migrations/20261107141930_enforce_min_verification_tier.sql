-- A segment's minimum vendor verification tier (policies.min_verification_tier) used to be applied only
-- when ranking vendors. A client could still invite a lower-tier vendor straight through the API and
-- accept its quote. It is now enforced where the invitation is created and again when the quote is accepted.
-- Platform admins can still override.

create function private.vendor_meets_tier(p_buyer uuid, p_vendor uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select coalesce((select o.verification_tier from public.organisations o where o.id = p_vendor and o.kind = 'vendor'), -1)
         >= coalesce((select p.min_verification_tier from private.policy_for_org(p_buyer) p), 1);
$$;
revoke execute on function private.vendor_meets_tier(uuid, uuid) from public, anon;
grant execute on function private.vendor_meets_tier(uuid, uuid) to authenticated, service_role;

drop policy "quotes invited by buyer" on public.quotes;
create policy "quotes invited by buyer" on public.quotes for insert to authenticated
  with check (
    status = 'invited'
    and exists (
      select 1 from public.briefs b
      where b.id = brief_id
        and private.has_org_role(b.buyer_org_id, array['owner', 'approver']::public.member_role[])
        and private.vendor_meets_tier(b.buyer_org_id, vendor_org_id)
    )
  );

create or replace function public.accept_quote(p_quote uuid, p_start timestamptz)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  v_q public.quotes;
  v_buyer uuid;
  v_site uuid;
  v_pol public.policies;
  v_minutes numeric;
  v_contract uuid;
  v_job uuid;
begin
  select q.* into v_q from public.quotes q where q.id = p_quote for update;
  if not found then raise exception 'Quote not found'; end if;
  select b.buyer_org_id, b.site_id into v_buyer, v_site from public.briefs b where b.id = v_q.brief_id;
  if not (private.has_org_role(v_buyer, array['owner', 'approver']::public.member_role[]) or private.is_platform_admin()) then
    raise exception 'Only an owner or approver can accept a quote';
  end if;
  if v_q.status <> 'submitted' then raise exception 'Only a submitted quote can be accepted'; end if;
  if not (private.vendor_meets_tier(v_buyer, v_q.vendor_org_id) or private.is_platform_admin()) then
    raise exception 'This vendor is not verified to the level your segment requires';
  end if;
  if v_q.valid_until is not null and v_q.valid_until < current_date then raise exception 'This quote has expired'; end if;
  if p_start < now() then raise exception 'Choose a start time in the future'; end if;

  v_pol := private.policy_for_org(v_buyer);
  v_minutes := greatest(private.schedule_minutes(v_q.brief_id, v_q.brief_version), 30);

  update public.quotes set status = 'accepted' where id = p_quote;
  update public.quotes set status = 'declined'
   where brief_id = v_q.brief_id and id <> p_quote and status in ('invited', 'submitted');

  insert into public.contracts (buyer_org_id, vendor_org_id, site_id, brief_id, brief_version, quote_id, status,
                                starts_on, billing, currency)
  values (v_buyer, v_q.vendor_org_id, v_site, v_q.brief_id, v_q.brief_version, p_quote, 'active',
          p_start::date, case when v_pol.payment_model = 'escrow_one_off' then 'per_job' else 'monthly' end, v_q.currency)
  returning id into v_contract;

  insert into public.jobs (buyer_org_id, vendor_org_id, site_id, brief_id, brief_version, contract_id, quote_id,
                           status, scheduled_start, scheduled_end, value, currency)
  values (v_buyer, v_q.vendor_org_id, v_site, v_q.brief_id, v_q.brief_version, v_contract, p_quote,
          'matched', p_start, p_start + make_interval(mins => v_minutes::integer), v_q.total, v_q.currency)
  returning id into v_job;

  insert into public.job_events (job_id, kind, data) values (v_job, 'status_change', jsonb_build_object('to', 'matched'));

  if v_pol.payment_model = 'escrow_one_off' then
    insert into public.payments (job_id, contract_id, kind, amount, currency, provider, status, due_at, note)
    values (v_job, v_contract, 'escrow_hold', v_q.total, v_q.currency, 'manual', 'pending', p_start,
            'Client pays into escrow before the clean');
  end if;
  return v_job;
end;
$$;
