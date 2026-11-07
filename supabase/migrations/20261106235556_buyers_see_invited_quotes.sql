-- Clients see every quote request on their own briefs, including ones the vendor hasn't answered yet.
drop policy "quotes visible" on public.quotes;
create policy "quotes visible" on public.quotes for select to authenticated
  using (
    private.is_member(vendor_org_id)
    or private.is_platform_admin()
    or exists (select 1 from public.briefs b where b.id = brief_id and private.is_member(b.buyer_org_id))
  );
