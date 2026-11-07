-- Client-side charges for monthly plans and invoice-terms clients (escrow clients pay per clean already).
-- One line per contract per month, kept in step with the visits booked that month.
alter table public.payments add column period date;
create index payments_contract_period_idx on public.payments (contract_id, kind, period);

create function private.refresh_client_charges(p_contract uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  c public.contracts;
  v_pol public.policies;
  v_tz text;
  v_kind public.payment_kind;
  m record;
  v_paid numeric;
  v_due timestamptz;
  v_note text;
  v_pending uuid;
begin
  select * into c from public.contracts where id = p_contract;
  if not found then return; end if;
  v_pol := private.policy_for_org(c.buyer_org_id);
  if v_pol.payment_model = 'escrow_one_off' then return; end if;
  v_kind := case when v_pol.payment_model = 'monthly_in_advance' then 'direct_debit'::public.payment_kind else 'invoice'::public.payment_kind end;
  select mk.timezone into v_tz from public.organisations o join public.markets mk on mk.code = o.market where o.id = c.buyer_org_id;

  for m in
    select date_trunc('month', j.scheduled_start at time zone v_tz)::date as period,
           count(*) filter (where j.status <> 'cancelled') as visits,
           coalesce(sum(j.value) filter (where j.status <> 'cancelled'), 0) as total
    from public.jobs j where j.contract_id = p_contract
    group by 1
  loop
    select coalesce(sum(amount), 0) into v_paid from public.payments
     where contract_id = p_contract and kind = v_kind and period = m.period and status = 'succeeded';
    select id into v_pending from public.payments
     where contract_id = p_contract and kind = v_kind and period = m.period and status = 'pending' limit 1;
    v_due := case when v_kind = 'direct_debit'
                  then greatest(now(), m.period::timestamp at time zone v_tz)
                  else ((m.period + interval '1 month')::timestamp at time zone v_tz) + make_interval(days => c.payment_terms_days) end;
    v_note := format('%s %s · %s visit%s', case when v_kind = 'direct_debit' then 'Monthly plan,' else 'Invoice,' end,
                     to_char(m.period, 'FMMonth YYYY'), m.visits, case when m.visits = 1 then '' else 's' end);
    if m.total - v_paid > 0 then
      if v_pending is null then
        insert into public.payments (contract_id, kind, amount, currency, provider, status, due_at, note, period)
        values (p_contract, v_kind, m.total - v_paid, c.currency, 'manual', 'pending', v_due, v_note, m.period);
      else
        update public.payments set amount = m.total - v_paid, note = v_note, due_at = v_due where id = v_pending;
      end if;
    elsif v_pending is not null then
      delete from public.payments where id = v_pending;
    end if;
  end loop;
end;
$$;

create function private.jobs_refresh_charges()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.contract_id is not null and (
       tg_op = 'INSERT'
       or new.value is distinct from old.value
       or (new.status = 'cancelled') <> (old.status = 'cancelled')
       or new.scheduled_start is distinct from old.scheduled_start) then
    perform private.refresh_client_charges(new.contract_id);
  end if;
  return null;
end;
$$;
create trigger jobs_refresh_charges after insert or update on public.jobs
  for each row execute function private.jobs_refresh_charges();

revoke execute on function private.refresh_client_charges(uuid), private.jobs_refresh_charges() from public, anon, authenticated;
