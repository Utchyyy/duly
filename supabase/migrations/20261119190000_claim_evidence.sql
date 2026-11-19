-- Documents for verification claims: a vendor attaches the certificate behind a claim (insurance, ISO, CHAS...), and the people who
-- check it can open it.
--
-- A private bucket, files stored as <vendor org id>/<claim id>/<file name>:
--   * the vendor's own staff (admin and dispatcher) and Duly can read a vendor's files;
--   * an Enterprise's members can read the file on a company claim of a vendor on their roster, but only the file the claim currently
--     points at, and never for DBS or right to work (personal data, and not something an Enterprise can require);
--   * the vendor can add a file to a claim, and replace or remove it, only while the claim is still waiting for a check.
-- A claim's evidence_path must sit under its own vendor and claim id, so it can never point at someone else's file. Changing the file
-- clears the Enterprises' decisions on the claim, like changing its reference or expiry, so a decision always belongs to what was reviewed.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('claim-evidence', 'claim-evidence', false, 10485760, array['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic'])
on conflict (id) do nothing;

alter table public.verification_claims
  add constraint verification_claims_evidence_path_check
  check (evidence_path is null or (length(evidence_path) <= 300 and evidence_path like (org_id::text || '/' || id::text || '/%')));

-- The vendor and claim a file belongs to, read from its path (empty rather than an error for a malformed path).
create function private.claim_file_org(p_name text)
returns uuid language plpgsql immutable set search_path = ''
as $$
begin
  return (split_part(p_name, '/', 1))::uuid;
exception when others then
  return null;
end;
$$;

create function private.claim_file_claim(p_name text)
returns uuid language plpgsql immutable set search_path = ''
as $$
begin
  return (split_part(p_name, '/', 2))::uuid;
exception when others then
  return null;
end;
$$;

-- An Enterprise member may open the file a company claim of one of its roster vendors currently points at.
create function private.enterprise_can_read_claim_file(p_name text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.verification_claims c
      join public.enterprise_vendors ev on ev.vendor_org_id = c.org_id
      join public.memberships m on m.org_id = ev.enterprise_org_id and m.user_id = (select auth.uid())
     where c.id = private.claim_file_claim(p_name) and c.org_id = private.claim_file_org(p_name)
       and c.evidence_path = p_name and c.subject_user_id is null and c.kind not in ('dbs', 'right_to_work'));
$$;

-- The vendor's staff may put a file under a company claim of their own that is still waiting for a check.
create function private.can_attach_claim_file(p_name text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select cardinality(string_to_array(p_name, '/')) = 3
     and exists (
       select 1 from public.verification_claims c
        where c.id = private.claim_file_claim(p_name) and c.org_id = private.claim_file_org(p_name)
          and c.subject_user_id is null and c.status in ('self_declared', 'pending')
          and (private.is_vendor_staff(c.org_id) or private.is_platform_admin()));
$$;

create policy "claim files readable" on storage.objects for select to authenticated
  using (bucket_id = 'claim-evidence'
         and (private.is_platform_admin() or private.is_vendor_staff(private.claim_file_org(name)) or private.enterprise_can_read_claim_file(name)));
create policy "claim files added by the vendor" on storage.objects for insert to authenticated
  with check (bucket_id = 'claim-evidence' and private.can_attach_claim_file(name));
create policy "claim files removed by the vendor" on storage.objects for delete to authenticated
  using (bucket_id = 'claim-evidence' and private.can_attach_claim_file(name));

revoke execute on function private.claim_file_org(text), private.claim_file_claim(text), private.enterprise_can_read_claim_file(text),
  private.can_attach_claim_file(text) from public, anon;
grant execute on function private.claim_file_org(text), private.claim_file_claim(text) to authenticated;
grant execute on function private.enterprise_can_read_claim_file(text), private.can_attach_claim_file(text) to authenticated;

-- A decision belongs to the claim as it was reviewed: the document counts too.
create or replace function private.clear_reviews_on_claim_change()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if (new.kind, new.reference, new.valid_until, new.org_id, new.subject_user_id, new.evidence_path)
     is distinct from (old.kind, old.reference, old.valid_until, old.org_id, old.subject_user_id, old.evidence_path) then
    delete from public.enterprise_claim_reviews where claim_id = old.id;
  end if;
  return new;
end;
$$;

-- The compliance view also says where each claim's document is, so the Enterprise can open it.
drop function public.enterprise_vendor_compliance(uuid);
create function public.enterprise_vendor_compliance(p_enterprise uuid)
returns table (vendor_org_id uuid, vendor_name text, roster_status text, kind public.claim_kind, state text,
               claim_id uuid, reference text, valid_until date, duly_status text, reviewed_at timestamptz, note text, evidence_path text)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (private.is_member(p_enterprise) or private.is_platform_admin()) then raise exception 'Not allowed to see this Enterprise''s vendors'; end if;
  return query
  select ev.vendor_org_id, o.name, ev.status, rq.kind,
         case
           when cl.id is null then 'not_sent'
           when cl.valid_until is not null and cl.valid_until < current_date then 'expired'
           when rv.decision = 'rejected' then 'rejected'
           when rv.decision = 'accepted' then 'accepted'
           else 'awaiting'
         end,
         cl.id, cl.reference, cl.valid_until, cl.status::text, rv.reviewed_at, rv.note, cl.evidence_path
    from public.enterprise_vendors ev
    join public.organisations o on o.id = ev.vendor_org_id
    join public.enterprise_requirements rq on rq.enterprise_org_id = ev.enterprise_org_id
    left join lateral (
      select c.* from public.verification_claims c
       where c.org_id = ev.vendor_org_id and c.subject_user_id is null and c.kind = rq.kind
       order by c.created_at desc, c.id limit 1) cl on true
    left join public.enterprise_claim_reviews rv on rv.claim_id = cl.id and rv.enterprise_org_id = ev.enterprise_org_id
   where ev.enterprise_org_id = p_enterprise
   order by o.name, rq.kind;
end;
$$;
revoke execute on function public.enterprise_vendor_compliance(uuid) from public, anon;
grant execute on function public.enterprise_vendor_compliance(uuid) to authenticated;
