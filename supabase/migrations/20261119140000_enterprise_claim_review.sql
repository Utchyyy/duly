-- The Enterprise verifies its own vendors' claims.
--
-- Duly's own checks (verification_claims.status, the vendor's tier) stay as they are. An Enterprise now also decides, for its own
-- roster, whether each company claim a vendor has sent (Companies House, insurance, ISO, CHAS...) satisfies it, and says which kinds
-- it requires of every vendor. Nothing here changes who can be appointed: the roster is still the gate, and this is the evidence
-- the Enterprise uses to accept or suspend a vendor. Operative claims (DBS, right to work) are personal and are not reviewed here.
--   enterprise_requirements   the kinds of claim this Enterprise requires of its vendors
--   enterprise_claim_reviews  the Enterprise's decision on one claim (accepted / rejected, with a note)
-- A decision belongs to the claim as it was reviewed: if the vendor changes the reference, the kind or the expiry, the decision is
-- cleared and the claim waits for review again.

create table public.enterprise_requirements (
  id uuid not null default gen_random_uuid() unique,
  enterprise_org_id uuid not null references public.organisations(id) on delete cascade,
  kind public.claim_kind not null check (kind not in ('dbs', 'right_to_work')),
  created_at timestamptz not null default now(),
  primary key (enterprise_org_id, kind)
);
alter table public.enterprise_requirements enable row level security;
create policy "requirements visible" on public.enterprise_requirements for select to authenticated
  using (private.is_platform_admin() or private.is_member(enterprise_org_id));

create table public.enterprise_claim_reviews (
  id uuid primary key default gen_random_uuid(),
  enterprise_org_id uuid not null references public.organisations(id) on delete cascade,
  claim_id uuid not null references public.verification_claims(id) on delete cascade,
  decision text not null check (decision in ('accepted', 'rejected')),
  note text check (length(note) <= 500),
  reviewed_by uuid default auth.uid() references auth.users(id) on delete set null,
  reviewed_at timestamptz not null default now(),
  unique (enterprise_org_id, claim_id)
);
create index enterprise_claim_reviews_claim_idx on public.enterprise_claim_reviews (claim_id);
create index enterprise_claim_reviews_by_idx on public.enterprise_claim_reviews (reviewed_by);
alter table public.enterprise_claim_reviews enable row level security;
-- The Enterprise sees its decisions; the vendor sees what each Enterprise said about its own claims (so a rejection can be put right).
create policy "reviews visible" on public.enterprise_claim_reviews for select to authenticated
  using (private.is_platform_admin() or private.is_member(enterprise_org_id)
         or exists (select 1 from public.verification_claims c where c.id = claim_id and private.is_vendor_staff(c.org_id)));

create trigger audit_enterprise_requirements after insert or update or delete on public.enterprise_requirements for each row execute function private.audit_row();
create trigger audit_enterprise_claim_reviews after insert or update or delete on public.enterprise_claim_reviews for each row execute function private.audit_row();

-- A change to what was reviewed clears the decisions on it.
create function private.clear_reviews_on_claim_change()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if (new.kind, new.reference, new.valid_until, new.org_id, new.subject_user_id)
     is distinct from (old.kind, old.reference, old.valid_until, old.org_id, old.subject_user_id) then
    delete from public.enterprise_claim_reviews where claim_id = old.id;
  end if;
  return new;
end;
$$;
create trigger verification_claims_clear_reviews after update on public.verification_claims
  for each row execute function private.clear_reviews_on_claim_change();

-- The kinds this Enterprise requires of every vendor (replaces the list).
create function public.enterprise_set_requirements(p_enterprise uuid, p_kinds public.claim_kind[])
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not (private.has_org_role(p_enterprise, array['owner', 'approver']::public.member_role[]) or private.is_platform_admin()) then
    raise exception 'Only the Enterprise''s owner or approvers can set what it requires';
  end if;
  if not private.is_enterprise(p_enterprise) then raise exception 'That is not an Enterprise'; end if;
  if exists (select 1 from unnest(coalesce(p_kinds, '{}')) k where k in ('dbs', 'right_to_work')) then
    raise exception 'DBS and right to work are checked per person, not for the company';
  end if;
  delete from public.enterprise_requirements where enterprise_org_id = p_enterprise and not (kind = any (coalesce(p_kinds, '{}')));
  insert into public.enterprise_requirements (enterprise_org_id, kind)
    select p_enterprise, k from (select distinct unnest(coalesce(p_kinds, '{}')) as k) s
    on conflict (enterprise_org_id, kind) do nothing;
end;
$$;

-- The Enterprise's decision on one company claim of a vendor on its roster.
create function public.enterprise_review_claim(p_enterprise uuid, p_claim uuid, p_decision text, p_note text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare c public.verification_claims;
begin
  if not (private.has_org_role(p_enterprise, array['owner', 'approver']::public.member_role[]) or private.is_platform_admin()) then
    raise exception 'Only the Enterprise''s owner or approvers can review a claim';
  end if;
  if p_decision not in ('accepted', 'rejected') then raise exception 'A claim is accepted or rejected'; end if;
  if p_decision = 'rejected' and nullif(trim(coalesce(p_note, '')), '') is null then raise exception 'Say why the claim is rejected so the vendor can put it right'; end if;
  select * into c from public.verification_claims where id = p_claim;
  if not found or c.subject_user_id is not null then raise exception 'That is not a company claim'; end if;
  if not exists (select 1 from public.enterprise_vendors ev where ev.enterprise_org_id = p_enterprise and ev.vendor_org_id = c.org_id) then
    raise exception 'That vendor is not on this Enterprise''s roster';
  end if;
  insert into public.enterprise_claim_reviews (enterprise_org_id, claim_id, decision, note, reviewed_by, reviewed_at)
    values (p_enterprise, p_claim, p_decision, nullif(trim(coalesce(p_note, '')), ''), (select auth.uid()), now())
    on conflict (enterprise_org_id, claim_id) do update
      set decision = excluded.decision, note = excluded.note, reviewed_by = excluded.reviewed_by, reviewed_at = excluded.reviewed_at;
end;
$$;

-- Each roster vendor against each required kind, worked out here so the app only displays it. For a kind the vendor has sent several
-- times, the latest claim counts. state:
--   not_sent  the vendor has sent nothing of this kind
--   awaiting  sent, not yet reviewed by this Enterprise
--   accepted  this Enterprise accepted it and it has not run out
--   rejected  this Enterprise rejected it (the note says why)
--   expired   past its valid-until date, reviewed or not: a renewal is needed
create function public.enterprise_vendor_compliance(p_enterprise uuid)
returns table (vendor_org_id uuid, vendor_name text, roster_status text, kind public.claim_kind, state text,
               claim_id uuid, reference text, valid_until date, duly_status text, reviewed_at timestamptz, note text)
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
         cl.id, cl.reference, cl.valid_until, cl.status::text, rv.reviewed_at, rv.note
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

revoke execute on function public.enterprise_set_requirements(uuid, public.claim_kind[]), public.enterprise_review_claim(uuid, uuid, text, text),
  public.enterprise_vendor_compliance(uuid) from public, anon;
grant execute on function public.enterprise_set_requirements(uuid, public.claim_kind[]), public.enterprise_review_claim(uuid, uuid, text, text),
  public.enterprise_vendor_compliance(uuid) to authenticated;
revoke execute on function private.clear_reviews_on_claim_change() from public, anon, authenticated;
