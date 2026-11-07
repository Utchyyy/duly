-- A vendor can see the name of a worker it has offered a shift to, or who filled one of its shifts.
create function private.worker_serves_my_company(p_worker uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.shifts s
    where private.is_vendor_staff(s.vendor_org_id)
      and (s.filled_by = p_worker or exists (select 1 from public.shift_events e where e.shift_id = s.id and e.worker_id = p_worker))
  );
$$;
revoke execute on function private.worker_serves_my_company(uuid) from public, anon;
grant execute on function private.worker_serves_my_company(uuid) to authenticated, service_role;

drop policy "workers visible" on public.workers;
create policy "workers visible" on public.workers for select to authenticated
  using (user_id = (select auth.uid()) or private.employs_worker(id) or private.worker_serves_my_company(id) or private.is_platform_admin());
