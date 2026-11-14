-- The vendor dispatch board: every visit in a date range with who is on it and what needs attention right now.
--
-- All the judgement is made here, in SQL, from what the crew and the system already record, using the same rules as the
-- reminder scan (private.notify_due_items): the lateness tolerance is the brief's, then the policy's, then 15 minutes. The app
-- shows the rows in the order given and counts the flags; it does not rank or re-sort them. Rows that need attention come first
-- (oldest first), then the rest in time order.
--   late         booked but nobody has checked in, past the lateness tolerance
--   no_crew      a visit that is still to be done with nobody assigned
--   crew_clash   a cleaner is assigned to another visit at an overlapping time
--   overrunning  in progress and past its planned end
--   held         a complaint holds the visit (the vendor may owe a rework visit)
-- Cancelled visits are left out. A visit from before the range that is still unfinished is included so it cannot be forgotten.
-- No pay, no price and no client contact detail appears here. Vendor staff (admin and dispatcher) and Duly only: crew cannot.

create function public.dispatch_board(p_vendor uuid, p_from date, p_to date)
returns table (
  job_id uuid, scheduled_start timestamptz, scheduled_end timestamptz, status text, site_name text, town text,
  is_rework boolean, rework_area text, planned_minutes integer, checked_in_at timestamptz, on_site_minutes integer,
  crew jsonb, needs_crew boolean, crew_clash boolean, late_minutes integer, overrunning boolean, held boolean,
  awaiting_client boolean, attention text)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (private.is_platform_admin() or private.is_vendor_staff(p_vendor)) then raise exception 'Not allowed to see this vendor''s visits'; end if;
  return query
  with base as (
    select j.*, s.name as site_name, s.town as site_town,
           coalesce((select m.timezone from public.organisations o join public.markets m on m.code = o.market where o.id = j.buyer_org_id), 'UTC') as tz,
           (select min(e.at) from public.job_events e where e.job_id = j.id and e.kind = 'check_in') as ci,
           (select max(e.at) from public.job_events e where e.job_id = j.id and e.kind = 'check_out') as co,
           coalesce(bv.lateness_tolerance_min, (private.policy_for_org(j.buyer_org_id)).lateness_tolerance_min, 15) as tol,
           j.status in ('matched', 'en_route', 'on_site', 'in_progress', 'requested') as still_to_do
      from public.jobs j
      join public.sites s on s.id = j.site_id
      left join public.brief_versions bv on bv.brief_id = j.brief_id and bv.version = j.brief_version
     where j.vendor_org_id = p_vendor and j.status <> 'cancelled'),
  shown as (
    select * from base b
     where (b.scheduled_start at time zone b.tz)::date between p_from and p_to
        or (b.still_to_do and (b.scheduled_start at time zone b.tz)::date < p_from)),
  rows as (
    select b.*,
           coalesce((select jsonb_agg(jsonb_build_object('user_id', a.user_id,
                       'name', coalesce(nullif(trim(p.full_name), ''), split_part(u.email, '@', 1)), 'role', a.role) order by a.role desc, a.created_at)
                       from public.job_assignments a join auth.users u on u.id = a.user_id left join public.profiles p on p.id = a.user_id
                      where a.job_id = b.id), '[]'::jsonb) as crew_json,
           not exists (select 1 from public.job_assignments a where a.job_id = b.id) as nobody,
           b.status in ('matched', 'en_route', 'on_site', 'in_progress', 'requested') and exists (
             select 1 from public.job_assignments a1
               join public.job_assignments a2 on a2.user_id = a1.user_id and a2.job_id <> a1.job_id
               join public.jobs o on o.id = a2.job_id
              where a1.job_id = b.id and o.vendor_org_id = p_vendor
                and o.status in ('matched', 'en_route', 'on_site', 'in_progress', 'requested')
                and o.scheduled_start < b.scheduled_end and b.scheduled_start < o.scheduled_end) as clash
      from shown b)
  select r.id, r.scheduled_start, r.scheduled_end, r.status::text, r.site_name, r.site_town,
         r.rework_of_issue is not null,
         (select i.plan_label from public.issues i where i.id = r.rework_of_issue),
         private.job_planned_minutes(r.id),
         r.ci,
         case when r.ci is null then null else floor(extract(epoch from (coalesce(r.co, now()) - r.ci)) / 60)::integer end,
         r.crew_json,
         r.nobody and r.status in ('matched', 'requested'),
         r.clash,
         case when r.status in ('matched', 'en_route') and r.ci is null and now() >= r.scheduled_start + make_interval(mins => r.tol)
              then floor(extract(epoch from (now() - r.scheduled_start)) / 60)::integer end,
         r.status = 'in_progress' and now() > r.scheduled_end,
         r.status = 'disputed',
         r.status = 'completed',
         case
           when r.status in ('matched', 'en_route') and r.ci is null and now() >= r.scheduled_start + make_interval(mins => r.tol) then 'late'
           when r.nobody and r.status in ('matched', 'requested') then 'no_crew'
           when r.clash then 'crew_clash'
           when r.status = 'in_progress' and now() > r.scheduled_end then 'overrunning'
           when r.status = 'disputed' then 'held'
         end
    from rows r
   order by (case
               when r.status in ('matched', 'en_route') and r.ci is null and now() >= r.scheduled_start + make_interval(mins => r.tol) then false
               when r.nobody and r.status in ('matched', 'requested') then false
               when r.clash then false
               when r.status = 'in_progress' and now() > r.scheduled_end then false
               when r.status = 'disputed' then false
               else true end),
            r.scheduled_start, r.id;
end;
$$;

-- Each cleaner's load in the range, lightest first, so the next visit can go to someone who has room.
create function public.dispatch_crew(p_vendor uuid, p_from date, p_to date)
returns table (user_id uuid, name text, visits integer, scheduled_minutes integer, next_visit timestamptz, on_a_visit boolean)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (private.is_platform_admin() or private.is_vendor_staff(p_vendor)) then raise exception 'Not allowed to see this vendor''s crew'; end if;
  return query
  select m.user_id,
         coalesce(nullif(trim(p.full_name), ''), split_part(u.email, '@', 1)),
         count(j.id)::integer,
         coalesce(sum(extract(epoch from (j.scheduled_end - j.scheduled_start)) / 60), 0)::integer,
         min(j.scheduled_start) filter (where j.scheduled_start >= now() and j.status in ('matched', 'requested')),
         coalesce(bool_or(j.status = 'in_progress'), false)
    from public.memberships m
    join auth.users u on u.id = m.user_id
    left join public.profiles p on p.id = m.user_id
    left join lateral (
      select jb.* from public.jobs jb join public.job_assignments a on a.job_id = jb.id and a.user_id = m.user_id
       where jb.vendor_org_id = p_vendor and jb.status <> 'cancelled'
         and (jb.scheduled_start at time zone coalesce((select mk.timezone from public.organisations o join public.markets mk on mk.code = o.market where o.id = jb.buyer_org_id), 'UTC'))::date between p_from and p_to
    ) j on true
   where m.org_id = p_vendor and m.role = 'operative'
   group by m.user_id, p.full_name, u.email
   order by 4, 2;
end;
$$;

revoke execute on function public.dispatch_board(uuid, date, date), public.dispatch_crew(uuid, date, date) from public, anon;
grant execute on function public.dispatch_board(uuid, date, date), public.dispatch_crew(uuid, date, date) to authenticated;
