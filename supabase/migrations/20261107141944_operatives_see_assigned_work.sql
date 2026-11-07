-- Operatives (cleaners using Duly Crew) are members of their employer's organisation. Several policies
-- used plain membership on the vendor side, so every operative could read every job their company runs:
-- client sites, prices and evidence photos, the company's quotes and contracts, colleagues' DBS and
-- right-to-work claims, and the pay on every shift.
-- Vendor-side visibility now needs a staff role (vendor_admin or dispatcher). Operatives still see
-- exactly what they are rostered on (job_assignments), plus open shifts and the shifts they are offered.

create or replace function private.can_see_job(p_job uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select private.is_platform_admin()
    or exists (
      select 1 from public.jobs j
      where j.id = p_job and (private.is_member(j.buyer_org_id) or private.is_vendor_staff(j.vendor_org_id))
    )
    or exists (select 1 from public.job_assignments a where a.job_id = p_job and a.user_id = (select auth.uid()));
$$;

create or replace function private.can_see_site(p_site uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select private.is_platform_admin()
    or exists (select 1 from public.sites s where s.id = p_site and private.is_member(s.org_id))
    or exists (
      select 1 from public.briefs b join public.quotes q on q.brief_id = b.id
      where b.site_id = p_site and private.is_vendor_staff(q.vendor_org_id)
    )
    or exists (select 1 from public.contracts c where c.site_id = p_site and private.is_vendor_staff(c.vendor_org_id))
    or exists (
      select 1 from public.jobs j join public.job_assignments a on a.job_id = j.id
      where j.site_id = p_site and a.user_id = (select auth.uid())
    );
$$;

create or replace function private.can_see_brief(p_brief uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select private.is_platform_admin()
    or exists (select 1 from public.briefs b where b.id = p_brief and private.is_member(b.buyer_org_id))
    or exists (select 1 from public.quotes q where q.brief_id = p_brief and private.is_vendor_staff(q.vendor_org_id))
    or exists (select 1 from public.contracts c where c.brief_id = p_brief and private.is_vendor_staff(c.vendor_org_id))
    or exists (
      select 1 from public.jobs j join public.job_assignments a on a.job_id = j.id
      where j.brief_id = p_brief and a.user_id = (select auth.uid())
    );
$$;

drop policy "quotes visible" on public.quotes;
create policy "quotes visible" on public.quotes for select to authenticated
  using (
    private.is_vendor_staff(vendor_org_id)
    or private.is_platform_admin()
    or exists (select 1 from public.briefs b where b.id = brief_id and private.is_member(b.buyer_org_id))
  );

drop policy "contracts visible" on public.contracts;
create policy "contracts visible" on public.contracts for select to authenticated
  using (private.is_member(buyer_org_id) or private.is_vendor_staff(vendor_org_id) or private.is_platform_admin());

-- Operative-level claims (DBS, right to work) are personal: the person, their company's staff and Duly.
drop policy "claims visible" on public.verification_claims;
create policy "claims visible" on public.verification_claims for select to authenticated
  using (subject_user_id is null or subject_user_id = (select auth.uid()) or private.is_vendor_staff(org_id) or private.is_platform_admin());

-- Shift pay is visible to the company's staff, Duly, and the workers involved; an operative who is a member
-- of the company does not see other people's shifts.
drop policy "shifts visible" on public.shifts;
create policy "shifts visible" on public.shifts for select to authenticated
  using (private.is_vendor_staff(vendor_org_id) or private.is_platform_admin()
         or private.is_worker_self(filled_by)
         or (status = 'open' and private.has_worker_record())
         or private.was_offered_shift(id));
