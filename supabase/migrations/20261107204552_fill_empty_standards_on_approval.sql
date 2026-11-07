-- When a person approves an AI draft, any area the drafter left without standards gets the segment's
-- standards_library entries for that area type (up to 3), so the brief can be locked. The library is
-- human-maintained data; the model still supplies no standards of its own here. Areas whose type has no
-- library entries stay empty and the brief editor says which to fix.
-- A person approves a draft (as they edited it). This creates the site (or uses an existing one) and an
-- ordinary, unlocked draft brief, and records who approved what.
create or replace function public.approve_brief_draft(
  p_item uuid, p_draft jsonb,
  p_site uuid default null, p_site_lat numeric default null, p_site_lng numeric default null)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  q public.approval_queue;
  v_site uuid; v_brief uuid; v_sched jsonb; v_days text[]; v_start time;
  v_name text; v_postcode text; v_segment text;
begin
  select * into q from public.approval_queue where id = p_item for update;
  if not found or q.kind <> 'brief_draft' then raise exception 'Draft not found'; end if;
  if not (private.has_org_role(q.org_id, array['owner', 'approver']::public.member_role[]) or private.is_platform_admin()) then
    raise exception 'Only an owner or approver can approve a draft';
  end if;
  if q.status <> 'pending' then raise exception 'This draft is already %', q.status; end if;
  perform private.validate_brief_draft(p_draft);
  select segment into v_segment from public.organisations where id = q.org_id;

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
               'standards', case when coalesce(jsonb_array_length(a -> 'standards'), 0) = 0 then (
                 -- The drafter left this area with nothing to check the clean against. Use the segment's library
                 -- standards for the area type (up to 3), so the brief can be locked. No match leaves it empty.
                 select coalesce(jsonb_agg(jsonb_build_object(
                          'id', 's' || sord || '-' || aord || '-' || l.n || '-' || substr(md5(random()::text || clock_timestamp()::text), 1, 6),
                          'text', l.text) order by l.n), '[]'::jsonb)
                 from (select sl.text, row_number() over (order by sl.created_at, sl.id) as n
                         from public.standards_library sl
                        where sl.segment = v_segment and sl.area_type = nullif(trim(a ->> 'area_type'), '')
                        order by sl.created_at, sl.id limit 3) l)
               else (
                 select coalesce(jsonb_agg(jsonb_build_object(
                          'id', 's' || sord || '-' || aord || '-' || tord || '-' || substr(md5(random()::text || clock_timestamp()::text), 1, 6),
                          'text', trim(t #>> '{}'))
                        order by tord), '[]'::jsonb)
                 from jsonb_array_elements(a -> 'standards') with ordinality as z (t, tord)) end
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
