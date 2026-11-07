-- AI brief drafting. A model may turn a pasted description or an uploaded document into a *draft* brief,
-- and that draft goes only into approval_queue. Nothing the model produced reaches a real brief until an
-- owner or approver reviews it and approves it here. The model never ranks, prices or locks anything:
-- approval creates an ordinary unlocked draft brief that the person then edits and locks themselves.

alter table public.approval_queue
  add column result_brief_id uuid references public.briefs(id) on delete set null,
  add column reject_reason text,
  add column final_draft jsonb;   -- what the person actually approved (the AI's own draft stays in `draft`)
create index approval_queue_result_brief_idx on public.approval_queue (result_brief_id);

-- People can add pending drafts (the server function does it as the signed-in person) but cannot edit,
-- approve, reject or delete them directly: that goes through the two functions below.
drop policy "approval queue managed" on public.approval_queue;
create policy "approval queue drafts added" on public.approval_queue for insert to authenticated
  with check (
    kind = 'brief_draft' and status = 'pending'
    and created_by = (select auth.uid())
    and reviewed_by is null and reviewed_at is null and result_brief_id is null and final_draft is null
    and private.has_org_role(org_id, array['owner', 'approver']::public.member_role[])
  );
create policy "approval queue admin" on public.approval_queue for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

-- Cost and clutter guard that applies to every insert, whoever makes it.
create function private.approval_queue_limits()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if (select count(*) from public.approval_queue where org_id = new.org_id and created_at > now() - interval '24 hours') >= 25 then
    raise exception 'Daily drafting limit reached: try again tomorrow';
  end if;
  if (select count(*) from public.approval_queue where org_id = new.org_id and status = 'pending') >= 10 then
    raise exception 'Too many drafts are waiting: approve or reject some first';
  end if;
  return new;
end;
$$;
create trigger approval_queue_limits before insert on public.approval_queue
  for each row execute function private.approval_queue_limits();
revoke execute on function private.approval_queue_limits() from public, anon, authenticated;

-- The shape a brief draft must have to be approved. Strict on purpose: it is the last line of defence
-- between model output (or an edited draft) and a real brief.
create function private.validate_brief_draft(p jsonb)
returns void language plpgsql immutable set search_path = ''
as $$
declare
  sec jsonb; ar jsonb; st jsonb; d jsonb;
  n_areas integer := 0;
begin
  if jsonb_typeof(p) is distinct from 'object' then raise exception 'The draft is not valid'; end if;
  if coalesce(length(trim(p ->> 'title')), 0) not between 1 and 120 then
    raise exception 'Give the brief a title (up to 120 characters)';
  end if;
  if jsonb_typeof(p -> 'sections') is distinct from 'array' or jsonb_array_length(p -> 'sections') not between 1 and 12 then
    raise exception 'A brief needs between 1 and 12 sections';
  end if;
  for sec in select * from jsonb_array_elements(p -> 'sections') loop
    if jsonb_typeof(sec) is distinct from 'object' or coalesce(length(trim(sec ->> 'name')), 0) not between 1 and 80 then
      raise exception 'Every section needs a name (up to 80 characters)';
    end if;
    if jsonb_typeof(sec -> 'areas') is distinct from 'array' or jsonb_array_length(sec -> 'areas') not between 1 and 30 then
      raise exception 'Every section needs between 1 and 30 areas';
    end if;
    for ar in select * from jsonb_array_elements(sec -> 'areas') loop
      n_areas := n_areas + 1;
      if jsonb_typeof(ar) is distinct from 'object' or coalesce(length(trim(ar ->> 'name')), 0) not between 1 and 80 then
        raise exception 'Every area needs a name (up to 80 characters)';
      end if;
      if coalesce(ar ->> 'minutes', '') !~ '^[0-9]{1,3}$' or (ar ->> 'minutes')::integer not between 1 and 600 then
        raise exception 'Minutes for "%" must be a whole number from 1 to 600', left(ar ->> 'name', 40);
      end if;
      if ar ? 'area_type' and jsonb_typeof(ar -> 'area_type') not in ('string', 'null') then
        raise exception 'The area type for "%" is not valid', left(ar ->> 'name', 40);
      end if;
      if jsonb_typeof(ar -> 'standards') is distinct from 'array' or jsonb_array_length(ar -> 'standards') > 12 then
        raise exception '"%" needs a list of up to 12 standards', left(ar ->> 'name', 40);
      end if;
      for st in select * from jsonb_array_elements(ar -> 'standards') loop
        if jsonb_typeof(st) is distinct from 'string' or length(trim(st #>> '{}')) not between 1 and 200 then
          raise exception 'Each standard must be text of up to 200 characters';
        end if;
      end loop;
    end loop;
  end loop;
  if n_areas > 60 then raise exception 'A brief can have at most 60 areas'; end if;
  if p ? 'visits' and jsonb_typeof(p -> 'visits') = 'object' then
    if p -> 'visits' ? 'days' and jsonb_typeof(p -> 'visits' -> 'days') is distinct from 'array' then
      raise exception 'Visit days are not valid';
    end if;
    for d in select * from jsonb_array_elements(coalesce(p -> 'visits' -> 'days', '[]'::jsonb)) loop
      if jsonb_typeof(d) is distinct from 'string' or (d #>> '{}') not in ('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun') then
        raise exception 'Visit days must be mon to sun';
      end if;
    end loop;
    if coalesce(p -> 'visits' ->> 'start_time', '') <> '' and (p -> 'visits' ->> 'start_time') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
      raise exception 'The start time must look like 18:00';
    end if;
  end if;
end;
$$;
revoke execute on function private.validate_brief_draft(jsonb) from public, anon;
grant execute on function private.validate_brief_draft(jsonb) to authenticated, service_role;

-- A person approves a draft (as they edited it). This creates the site (or uses an existing one) and an
-- ordinary, unlocked draft brief, and records who approved what.
create function public.approve_brief_draft(
  p_item uuid, p_draft jsonb,
  p_site uuid default null, p_site_lat numeric default null, p_site_lng numeric default null)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  q public.approval_queue;
  v_site uuid; v_brief uuid; v_sched jsonb; v_days text[]; v_start time;
  v_name text; v_postcode text;
begin
  select * into q from public.approval_queue where id = p_item for update;
  if not found or q.kind <> 'brief_draft' then raise exception 'Draft not found'; end if;
  if not (private.has_org_role(q.org_id, array['owner', 'approver']::public.member_role[]) or private.is_platform_admin()) then
    raise exception 'Only an owner or approver can approve a draft';
  end if;
  if q.status <> 'pending' then raise exception 'This draft is already %', q.status; end if;
  perform private.validate_brief_draft(p_draft);

  if p_site is not null then
    if not exists (select 1 from public.sites where id = p_site and org_id = q.org_id) then
      raise exception 'That site does not belong to this organisation';
    end if;
    v_site := p_site;
  else
    v_name := trim(p_draft #>> '{site,name}');
    v_postcode := trim(p_draft #>> '{site,postcode}');
    if coalesce(length(v_name), 0) not between 1 and 120 then raise exception 'Give the site a name'; end if;
    if coalesce(length(v_postcode), 0) not between 1 and 12 then raise exception 'Give the site a postcode'; end if;
    if p_site_lat is null or p_site_lng is null then raise exception 'Look up the postcode first'; end if;
    insert into public.sites (org_id, name, address_line1, town, postcode, lat, lng, access_notes)
    values (q.org_id, v_name, nullif(trim(left(p_draft #>> '{site,address}', 200)), ''),
            nullif(trim(left(p_draft #>> '{site,town}', 80)), ''), upper(v_postcode), p_site_lat, p_site_lng,
            nullif(trim(left(p_draft #>> '{site,access_notes}', 500)), ''))
    returning id into v_site;
  end if;

  -- Ids are made here, never taken from the model or the browser.
  select jsonb_agg(jsonb_build_object(
           'name', trim(s ->> 'name'),
           'areas', (
             select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'id', 'a' || sord || '-' || aord || '-' || substr(md5(random()::text || clock_timestamp()::text), 1, 6),
               'name', trim(a ->> 'name'),
               'area_type', nullif(trim(a ->> 'area_type'), ''),
               'minutes', (a ->> 'minutes')::integer,
               'standards', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                          'id', 's' || sord || '-' || aord || '-' || tord || '-' || substr(md5(random()::text || clock_timestamp()::text), 1, 6),
                          'text', trim(t #>> '{}'))
                        order by tord), '[]'::jsonb)
                 from jsonb_array_elements(a -> 'standards') with ordinality as z (t, tord))
             )) order by aord)
             from jsonb_array_elements(s -> 'areas') with ordinality as y (a, aord))
         ) order by sord)
    into v_sched
  from jsonb_array_elements(p_draft -> 'sections') with ordinality as x (s, sord);

  select array_agg(value #>> '{}' order by ord) into v_days
  from jsonb_array_elements(coalesce(p_draft -> 'visits' -> 'days', '[]'::jsonb)) with ordinality as e (value, ord);
  v_start := nullif(p_draft -> 'visits' ->> 'start_time', '')::time;

  insert into public.briefs (buyer_org_id, site_id, title) values (q.org_id, v_site, trim(p_draft ->> 'title'))
  returning id into v_brief;
  insert into public.brief_versions (brief_id, version, schedule, preferred_days, preferred_start)
  values (v_brief, 1, v_sched, v_days, v_start);

  update public.approval_queue
     set status = 'approved', reviewed_by = (select auth.uid()), reviewed_at = now(),
         result_brief_id = v_brief, final_draft = p_draft
   where id = p_item;
  return v_brief;
end;
$$;

create function public.reject_brief_draft(p_item uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare q public.approval_queue;
begin
  select * into q from public.approval_queue where id = p_item for update;
  if not found or q.kind <> 'brief_draft' then raise exception 'Draft not found'; end if;
  if not (private.has_org_role(q.org_id, array['owner', 'approver']::public.member_role[]) or private.is_platform_admin()) then
    raise exception 'Only an owner or approver can reject a draft';
  end if;
  if q.status <> 'pending' then raise exception 'This draft is already %', q.status; end if;
  update public.approval_queue
     set status = 'rejected', reviewed_by = (select auth.uid()), reviewed_at = now(),
         reject_reason = nullif(trim(left(p_reason, 500)), '')
   where id = p_item;
end;
$$;

revoke execute on function public.approve_brief_draft(uuid, jsonb, uuid, numeric, numeric), public.reject_brief_draft(uuid, text) from public, anon;
grant execute on function public.approve_brief_draft(uuid, jsonb, uuid, numeric, numeric), public.reject_brief_draft(uuid, text) to authenticated;

-- Source documents for drafting: a private bucket, files under <org_id>/..., for that organisation's owners
-- and approvers only. Files can't be replaced or removed once uploaded.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('brief-sources', 'brief-sources', false, 10485760,
        array['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'text/plain'])
on conflict (id) do nothing;

create policy "brief sources readable by buyer staff" on storage.objects for select to authenticated
  using (bucket_id = 'brief-sources'
         and (private.has_org_role(((storage.foldername(name))[1])::uuid, array['owner', 'approver']::public.member_role[])
              or private.is_platform_admin()));
create policy "brief sources uploaded by buyer staff" on storage.objects for insert to authenticated
  with check (bucket_id = 'brief-sources'
              and private.has_org_role(((storage.foldername(name))[1])::uuid, array['owner', 'approver']::public.member_role[]));
