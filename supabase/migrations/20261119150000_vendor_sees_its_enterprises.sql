-- A vendor can read the name of an Enterprise that has it on its roster, so it can tell which Enterprise decided what about its claims
-- (Pro > Verification). Only Enterprises that list the vendor, only for the vendor's own staff. Nothing else about the Enterprise opens up.
create policy "enterprises visible to their vendors" on public.organisations for select to authenticated
  using (exists (select 1 from public.enterprise_vendors ev where ev.enterprise_org_id = organisations.id and private.is_vendor_staff(ev.vendor_org_id)));
