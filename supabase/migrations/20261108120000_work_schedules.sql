-- Work schedules: how a vendor will clean, in response to a brief.
--
-- A vendor answers a brief (a quote request) with a work schedule built from a template: Section > Sub-section >
-- Cleaning area, each set per weekday to a method (scrub, wash, clean or mop), with the vendor's minutes for each
-- method. The client sees it with the quote. When the client accepts, it locks and becomes the record the crew work
-- from and the client checks the work against. A complaint can name the exact cleaning area it is about.
--
-- The schedule is for the work, not the price: price_quote is unchanged and still prices the brief.

create table public.work_plan_templates (
  id uuid primary key default gen_random_uuid(),
  vendor_org_id uuid references public.organisations(id) on delete cascade,   -- null = shared library template
  name text not null check (length(name) between 1 and 120),
  description text check (length(description) <= 600),
  segment text references public.segments(code),
  legend jsonb not null,
  plan jsonb not null,
  created_at timestamptz not null default now()
);
create index work_plan_templates_vendor_idx on public.work_plan_templates (vendor_org_id);
create index work_plan_templates_segment_idx on public.work_plan_templates (segment);
alter table public.work_plan_templates enable row level security;

create policy "templates readable by vendor staff" on public.work_plan_templates for select to authenticated
  using (
    private.is_platform_admin()
    or (vendor_org_id is null and exists (select 1 from public.memberships m
          where m.user_id = (select auth.uid()) and m.role in ('vendor_admin', 'dispatcher')))
    or (vendor_org_id is not null and private.is_vendor_staff(vendor_org_id)));
create policy "templates written by owner" on public.work_plan_templates for insert to authenticated
  with check (private.is_platform_admin() or (vendor_org_id is not null and private.is_vendor_staff(vendor_org_id)));
create policy "templates changed by owner" on public.work_plan_templates for update to authenticated
  using (private.is_platform_admin() or (vendor_org_id is not null and private.is_vendor_staff(vendor_org_id)))
  with check (private.is_platform_admin() or (vendor_org_id is not null and private.is_vendor_staff(vendor_org_id)));
create policy "templates removed by owner" on public.work_plan_templates for delete to authenticated
  using (private.is_platform_admin() or (vendor_org_id is not null and private.is_vendor_staff(vendor_org_id)));

create table public.work_schedules (
  id uuid primary key default gen_random_uuid(),
  quote_id uuid not null unique references public.quotes(id) on delete cascade,
  brief_id uuid not null references public.briefs(id) on delete cascade,
  vendor_org_id uuid not null references public.organisations(id) on delete cascade,
  status text not null default 'draft' check (status in ('draft', 'submitted', 'locked')),
  legend jsonb not null,
  plan jsonb not null,
  submitted_at timestamptz,
  locked_at timestamptz,
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index work_schedules_brief_idx on public.work_schedules (brief_id);
create index work_schedules_vendor_idx on public.work_schedules (vendor_org_id);
create index work_schedules_created_by_idx on public.work_schedules (created_by);
alter table public.work_schedules enable row level security;

-- Checks the shape and, for a submitted schedule, that it is complete: at least one cleaning area, and minutes for every
-- method it uses. Ids must be unique because complaints point at them.
create function private.validate_work_schedule(p_plan jsonb, p_legend jsonb, p_complete boolean)
returns void language plpgsql immutable set search_path = ''
as $$
declare
  s jsonb; ss jsonb; a jsonb; k text; v text; ids text[] := '{}'; v_id text; n integer := 0; used text[] := '{}';
  methods constant text[] := array['scrub', 'wash', 'clean', 'mop'];
  weekdays constant text[] := array['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];
begin
  if jsonb_typeof(p_plan) <> 'object' or jsonb_typeof(p_plan -> 'sections') <> 'array' then raise exception 'The work schedule is not in the right shape'; end if;
  if octet_length(p_plan::text) > 400000 then raise exception 'The work schedule is too large'; end if;
  if jsonb_typeof(p_legend) <> 'object' then raise exception 'The method times are not in the right shape'; end if;
  for k in select jsonb_object_keys(p_legend) loop
    if k <> all (methods) then raise exception 'Unknown cleaning method %', k; end if;
    if p_legend -> k ->> 'minutes' is not null and ((p_legend -> k ->> 'minutes') !~ '^[0-9]+$' or (p_legend -> k ->> 'minutes')::integer > 600) then
      raise exception 'Minutes for % must be a whole number up to 600', k;
    end if;
  end loop;
  for s in select * from jsonb_array_elements(p_plan -> 'sections') loop
    if coalesce(length(trim(s ->> 'name')), 0) not between 1 and 120 then raise exception 'Every section needs a name'; end if;
    for ss in select * from jsonb_array_elements(coalesce(s -> 'subsections', '[]')) loop
      if coalesce(length(trim(ss ->> 'name')), 0) not between 1 and 120 then raise exception 'Every sub-section needs a name'; end if;
      for a in select * from jsonb_array_elements(coalesce(ss -> 'areas', '[]')) loop
        v_id := a ->> 'id';
        if coalesce(length(v_id), 0) not between 1 and 60 then raise exception 'Every cleaning area needs an id'; end if;
        if v_id = any (ids) then raise exception 'Cleaning area ids must be unique'; end if;
        ids := ids || v_id; n := n + 1;
        if coalesce(length(trim(a ->> 'name')), 0) not between 1 and 200 then raise exception 'Every cleaning area needs a name'; end if;
        if jsonb_typeof(coalesce(a -> 'days', '{}')) <> 'object' then raise exception 'Days are not in the right shape'; end if;
        for k in select jsonb_object_keys(coalesce(a -> 'days', '{}')) loop
          if k <> all (weekdays) then raise exception 'Unknown weekday %', k; end if;
          v := a -> 'days' ->> k;
          if v <> all (methods) then raise exception 'Unknown cleaning method %', v; end if;
          used := used || v;
        end loop;
      end loop;
    end loop;
  end loop;
  if p_complete then
    if n = 0 then raise exception 'Add at least one cleaning area before sending the schedule'; end if;
    if array_length(used, 1) is null then raise exception 'Set a method on at least one day'; end if;
    foreach v in array (select array_agg(distinct u) from unnest(used) u) loop
      if coalesce((p_legend -> v ->> 'minutes')::integer, 0) <= 0 then raise exception 'Set the minutes for % before sending the schedule', v; end if;
    end loop;
  end if;
end;
$$;

-- Label for one cleaning area ("Section > Sub-section > Area"), looked up server-side so a complaint's label cannot be forged.
create function private.plan_item_label(p_plan jsonb, p_item text)
returns text language sql immutable set search_path = ''
as $$
  select concat_ws(' > ', s ->> 'name', ss ->> 'name', a ->> 'name')
    from jsonb_array_elements(p_plan -> 'sections') s,
         jsonb_array_elements(coalesce(s -> 'subsections', '[]')) ss,
         jsonb_array_elements(coalesce(ss -> 'areas', '[]')) a
   where a ->> 'id' = p_item
   limit 1;
$$;

create function private.work_schedule_guard()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare q public.quotes;
begin
  if tg_op = 'INSERT' then
    select * into q from public.quotes where id = new.quote_id;
    if not found then raise exception 'Quote not found'; end if;
    if not private.is_vendor_staff(q.vendor_org_id) and not private.is_platform_admin() then raise exception 'Only the vendor can build the work schedule'; end if;
    if q.status not in ('invited', 'submitted') then raise exception 'A work schedule can only be built while the quote is open'; end if;
    new.brief_id := q.brief_id; new.vendor_org_id := q.vendor_org_id;
    new.status := 'draft'; new.submitted_at := null; new.locked_at := null;
  else
    if old.status = 'locked' and (current_setting('duly.locking', true) is distinct from 'on') then
      raise exception 'This work schedule is locked: the client accepted it';
    end if;
    if new.quote_id <> old.quote_id or new.brief_id <> old.brief_id or new.vendor_org_id <> old.vendor_org_id then raise exception 'A work schedule cannot be moved'; end if;
    if new.status = 'locked' and old.status <> 'locked' and (current_setting('duly.locking', true) is distinct from 'on') then
      raise exception 'A work schedule is locked when the client accepts the quote';
    end if;
    if old.status <> 'locked' and (current_setting('duly.locking', true) is distinct from 'on') then
      select * into q from public.quotes where id = new.quote_id;
      if q.status not in ('invited', 'submitted') then raise exception 'The quote is no longer open, so the schedule cannot change'; end if;
    end if;
    if new.status = 'submitted' and old.status <> 'submitted' then new.submitted_at := now(); end if;
    if new.status = 'draft' then new.submitted_at := null; end if;
  end if;
  perform private.validate_work_schedule(new.plan, new.legend, new.status in ('submitted', 'locked'));
  new.updated_at := now();
  return new;
end;
$$;
create trigger work_schedules_guard before insert or update on public.work_schedules
  for each row execute function private.work_schedule_guard();

-- Accepting a quote locks the schedule that was sent with it.
create function private.lock_work_schedule_on_accept()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.status = 'accepted' and old.status is distinct from 'accepted' then
    perform set_config('duly.locking', 'on', true);
    update public.work_schedules set status = 'locked', locked_at = now() where quote_id = new.id and status = 'submitted';
    perform set_config('duly.locking', 'off', true);
  end if;
  return null;
end;
$$;
create trigger quotes_lock_work_schedule after update on public.quotes
  for each row execute function private.lock_work_schedule_on_accept();

create policy "work schedules visible" on public.work_schedules for select to authenticated
  using (
    private.is_platform_admin()
    or private.is_vendor_staff(vendor_org_id)
    or (status in ('submitted', 'locked') and exists (select 1 from public.briefs b where b.id = work_schedules.brief_id and private.is_member(b.buyer_org_id)))
    or (status = 'locked' and exists (select 1 from public.jobs j join public.job_assignments a on a.job_id = j.id
          where j.quote_id = work_schedules.quote_id and a.user_id = (select auth.uid()))));
create policy "work schedules built by vendor" on public.work_schedules for insert to authenticated
  with check (private.is_platform_admin() or private.is_vendor_staff(vendor_org_id));
create policy "work schedules changed by vendor" on public.work_schedules for update to authenticated
  using (private.is_platform_admin() or (status <> 'locked' and private.is_vendor_staff(vendor_org_id)))
  with check (private.is_platform_admin() or private.is_vendor_staff(vendor_org_id));
create policy "work schedules removed by vendor" on public.work_schedules for delete to authenticated
  using (private.is_platform_admin() or (status <> 'locked' and private.is_vendor_staff(vendor_org_id)));

-- Complaints can name the cleaning area they are about.
alter table public.issues add column plan_item_id text check (length(plan_item_id) <= 60), add column plan_label text check (length(plan_label) <= 520);
create function private.issue_plan_item()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare v_plan jsonb; v_label text;
begin
  if new.plan_item_id is null then new.plan_label := null; return new; end if;
  if tg_op = 'UPDATE' and new.plan_item_id is not distinct from old.plan_item_id then new.plan_label := old.plan_label; return new; end if;
  select ws.plan into v_plan from public.jobs j join public.work_schedules ws on ws.quote_id = j.quote_id and ws.status = 'locked' where j.id = new.job_id;
  if v_plan is null then raise exception 'This job has no work schedule to point at'; end if;
  v_label := private.plan_item_label(v_plan, new.plan_item_id);
  if v_label is null then raise exception 'That cleaning area is not in the work schedule'; end if;
  new.plan_label := v_label;
  return new;
end;
$$;
create trigger issues_plan_item before insert or update on public.issues
  for each row execute function private.issue_plan_item();

revoke execute on function private.validate_work_schedule(jsonb, jsonb, boolean), private.plan_item_label(jsonb, text), private.work_schedule_guard(),
  private.lock_work_schedule_on_accept(), private.issue_plan_item() from public, anon, authenticated;

-- Record who sent, changed the status of or locked a schedule, and when (drafts are not logged on every save).
create or replace function private.audit_write(
  p_table text, p_op text, p_new jsonb, p_old jsonb, p_actor uuid, p_at timestamptz, p_source text, p_skip text[])
returns void language plpgsql security definer set search_path = ''
as $$
declare
  j jsonb := coalesce(p_new, p_old);
  v_brief uuid; v_quote uuid; v_job uuid; v_row text; v_orgs uuid[] := '{}';
  v_buyer uuid; v_vendor uuid; v_org uuid; v_contract uuid;
  v_changes jsonb := '{}'::jsonb; v_summary text; v_kind text; k text; v_noun text;
begin
  -- Which brief, quote and job this belongs to.
  v_brief := nullif(coalesce(j ->> 'brief_id', case when p_table = 'briefs' then j ->> 'id' end), '')::uuid;
  v_quote := nullif(coalesce(case when p_table = 'quotes' then j ->> 'id' end, j ->> 'quote_id'), '')::uuid;
  v_job := nullif(coalesce(case when p_table = 'jobs' then j ->> 'id' end, j ->> 'job_id'), '')::uuid;
  v_row := coalesce(j ->> 'id', concat_ws('/', j ->> 'job_id', j ->> 'area_id', j ->> 'standard_id', j ->> 'user_id', j ->> 'brief_id', j ->> 'version'));
  v_buyer := nullif(j ->> 'buyer_org_id', '')::uuid;
  v_vendor := nullif(j ->> 'vendor_org_id', '')::uuid;
  v_org := nullif(j ->> 'org_id', '')::uuid;
  v_contract := nullif(j ->> 'contract_id', '')::uuid;

  if v_job is not null and (v_brief is null or v_buyer is null or v_vendor is null) then
    select coalesce(v_brief, jb.brief_id), coalesce(v_quote, jb.quote_id), coalesce(v_buyer, jb.buyer_org_id), coalesce(v_vendor, jb.vendor_org_id)
      into v_brief, v_quote, v_buyer, v_vendor from public.jobs jb where jb.id = v_job;
  end if;
  if v_contract is not null and v_job is null and (v_buyer is null or v_vendor is null) then
    select coalesce(v_brief, c.brief_id), coalesce(v_quote, c.quote_id), coalesce(v_buyer, c.buyer_org_id), coalesce(v_vendor, c.vendor_org_id)
      into v_brief, v_quote, v_buyer, v_vendor from public.contracts c where c.id = v_contract;
  end if;
  if v_brief is not null and v_buyer is null then
    select b.buyer_org_id into v_buyer from public.briefs b where b.id = v_brief;
  end if;
  select coalesce(array_agg(distinct o), '{}') into v_orgs from unnest(array[v_buyer, v_vendor, v_org]) o where o is not null;

  -- What changed: everything for an insert or delete, only the changed columns for an update.
  if p_op = 'UPDATE' then
    for k in select key from jsonb_object_keys(p_new) key loop
      continue when k = 'updated_at' or k = any (coalesce(p_skip, '{}'));
      if p_new -> k is distinct from p_old -> k then
        v_changes := v_changes || jsonb_build_object(k, jsonb_build_object('from', p_old -> k, 'to', p_new -> k));
      end if;
    end loop;
    if v_changes = '{}'::jsonb then return; end if;   -- nothing worth recording changed
  else
    v_changes := j - coalesce(p_skip, '{}') - 'updated_at';
  end if;

  v_kind := coalesce(j ->> 'kind', '');
  v_noun := case p_table
    when 'briefs' then 'Brief' when 'brief_versions' then 'Brief version' when 'quotes' then 'Quote' when 'contracts' then 'Contract'
    when 'jobs' then 'Job' when 'job_assignments' then 'Crew assignment' when 'evidence' then 'Photo' when 'area_results' then 'Standard'
    when 'issues' then 'Issue' when 'payments' then 'Payment' when 'verification_claims' then 'Verification claim'
    when 'approval_queue' then 'AI draft' when 'work_schedules' then 'Work schedule' else initcap(replace(p_table, '_', ' ')) end;
  v_summary := v_noun || case p_op when 'INSERT' then ' created' when 'DELETE' then ' deleted' else ' updated' end;
  if p_op = 'UPDATE' then
    if v_changes ? 'status' then
      v_summary := v_noun || ' status ' || coalesce(p_old ->> 'status', 'none') || ' to ' || coalesce(p_new ->> 'status', 'none');
    elsif v_changes ? 'verdict' then
      v_summary := 'Standard marked ' || replace(coalesce(p_new ->> 'verdict', 'cleared'), '_', ' ');
    elsif v_changes ? 'locked_at' then
      v_summary := 'Brief version ' || (p_new ->> 'version') || ' locked';
    elsif v_changes ? 'done_by_operative' then
      v_summary := 'Standard ' || case when (p_new ->> 'done_by_operative')::boolean then 'ticked' else 'unticked' end || ' by crew';
    end if;
  elsif p_table = 'area_results' and p_op = 'INSERT' then
    v_summary := case when (p_new ->> 'done_by_operative')::boolean then 'Standard ticked by crew' else 'Standard added to the checklist' end;
  elsif v_kind <> '' then
    v_summary := v_summary || ' (' || replace(v_kind, '_', ' ') || ')';
  end if;
  if p_source = 'backfill' then
    v_summary := v_summary || ' (recorded from the current row: who did it and any earlier changes were not logged)';
  end if;

  insert into public.audit_log (at, actor, table_name, op, row_id, brief_id, quote_id, job_id, org_ids, summary, changes, source)
  values (coalesce(p_at, clock_timestamp()), p_actor, p_table, p_op, v_row, v_brief, v_quote, v_job, v_orgs, v_summary, v_changes, p_source);
end;
$$;
create trigger audit_work_schedules_insert after insert on public.work_schedules for each row execute function private.audit_row();
create trigger audit_work_schedules_status after update on public.work_schedules
  for each row when (old.status is distinct from new.status) execute function private.audit_row();
create trigger audit_work_schedules_delete after delete on public.work_schedules for each row execute function private.audit_row();

-- Starting points from a gym operator's sample schedule. Minutes are left for each vendor to set.
insert into public.work_plan_templates (vendor_org_id, name, description, segment, legend, plan) values
  (null, 'Gym changing rooms', $d$Changing rooms by section and sub-section: toilets, changing area, cubicles and mirrors, lockers and showers, plus an accessible room. Based on a gym operator's cleaning schedule; the days and methods are a starting point.$d$, 'sme', $j${"scrub":{"label":"Scrub","minutes":null},"wash":{"label":"Wash","minutes":null},"clean":{"label":"Clean","minutes":null},"mop":{"label":"Mop","minutes":null}}$j$::jsonb, $j${"sections":[{"id":"s1","name":"Male Changing Room","subsections":[{"id":"s1-1","name":"Toilet","brief_area_id":null,"areas":[{"id":"s1-1-1","name":"Toilet Bowls - in, corners and beneath","days":{"sun":"scrub","mon":"clean","tue":"clean","wed":"wash","thu":"clean","fri":"clean"}},{"id":"s1-1-2","name":"Urinal Bowls - in, corners and beneath","days":{"sun":"scrub","mon":"clean","tue":"clean","wed":"wash","thu":"clean","fri":"clean"}},{"id":"s1-1-3","name":"Metal Walls, Doors and Lintels","days":{"sun":"wash","mon":"clean","tue":"clean","wed":"wash","thu":"clean","fri":"clean"}},{"id":"s1-1-4","name":"Wall Skirts","days":{"sun":"wash"}},{"id":"s1-1-5","name":"Hand-wash Sinks - in, corners and beneath","days":{"sun":"scrub"}},{"id":"s1-1-6","name":"Floors","days":{"sun":"scrub"}}]},{"id":"s1-2","name":"Changing Area","brief_area_id":null,"areas":[{"id":"s1-2-1","name":"Walls","days":{}},{"id":"s1-2-2","name":"Floors","days":{"sun":"scrub"}},{"id":"s1-2-3","name":"Benches","days":{}},{"id":"s1-2-4","name":"Wall corners","days":{}},{"id":"s1-2-5","name":"Wall Skirts","days":{"sun":"scrub"}},{"id":"s1-2-6","name":"Bins","days":{}}]},{"id":"s1-3","name":"Cubicles & Mirrors","brief_area_id":null,"areas":[{"id":"s1-3-1","name":"Benches","days":{}},{"id":"s1-3-2","name":"Underneath the Benches","days":{}},{"id":"s1-3-3","name":"Cubicle Floors","days":{"sun":"scrub"}},{"id":"s1-3-4","name":"Inside Skirts","days":{"sun":"scrub"}},{"id":"s1-3-5","name":"All Mirrors","days":{"sun":"clean"}},{"id":"s1-3-6","name":"Dressing Slabs","days":{"sun":"clean"}}]},{"id":"s1-4","name":"Lockers","brief_area_id":null,"areas":[{"id":"s1-4-1","name":"Tops","days":{"sun":"wash"}},{"id":"s1-4-2","name":"Surfaces","days":{}},{"id":"s1-4-3","name":"Hidden joints","days":{}},{"id":"s1-4-4","name":"Opened boxes","days":{}}]},{"id":"s1-5","name":"Shower Cubicles","brief_area_id":null,"areas":[{"id":"s1-5-1","name":"Shower heads","days":{}},{"id":"s1-5-2","name":"Shower Drains","days":{}},{"id":"s1-5-3","name":"Cubicle Walls","days":{}},{"id":"s1-5-4","name":"Cubicle Floor","days":{}},{"id":"s1-5-5","name":"Cubicle Doors - Hinges, frames and holes","days":{}}]}]},{"id":"s2","name":"Female Changing Room","subsections":[{"id":"s2-1","name":"Toilet","brief_area_id":null,"areas":[{"id":"s2-1-1","name":"Toilet Bowls - in, corners and beneath","days":{"sun":"scrub"}},{"id":"s2-1-2","name":"Metal Walls, Doors and Lintels","days":{"sun":"wash"}},{"id":"s2-1-3","name":"Wall Skirts","days":{"sun":"wash"}},{"id":"s2-1-4","name":"Hand-wash Sinks - in, corners and beneath","days":{"sun":"scrub"}},{"id":"s2-1-5","name":"Floors","days":{"sun":"scrub"}}]},{"id":"s2-2","name":"Changing Area","brief_area_id":null,"areas":[{"id":"s2-2-1","name":"Walls","days":{}},{"id":"s2-2-2","name":"Floors","days":{"sun":"scrub"}},{"id":"s2-2-3","name":"Benches","days":{}},{"id":"s2-2-4","name":"Wall corners","days":{}},{"id":"s2-2-5","name":"Wall Skirts","days":{"sun":"scrub"}},{"id":"s2-2-6","name":"Bins","days":{}}]},{"id":"s2-3","name":"Cubicles & Mirrors","brief_area_id":null,"areas":[{"id":"s2-3-1","name":"Benches","days":{}},{"id":"s2-3-2","name":"Underneath the Benches","days":{}},{"id":"s2-3-3","name":"Cubicle Floors","days":{"sun":"scrub"}},{"id":"s2-3-4","name":"Inside Skirts","days":{"sun":"scrub"}},{"id":"s2-3-5","name":"All Mirrors","days":{"sun":"clean"}},{"id":"s2-3-6","name":"Dressing Slabs","days":{"sun":"clean"}}]},{"id":"s2-4","name":"Lockers","brief_area_id":null,"areas":[{"id":"s2-4-1","name":"Tops","days":{"sun":"wash"}},{"id":"s2-4-2","name":"Surfaces","days":{}},{"id":"s2-4-3","name":"Hidden joints","days":{}},{"id":"s2-4-4","name":"Opened boxes","days":{}}]},{"id":"s2-5","name":"Shower Cubicles","brief_area_id":null,"areas":[{"id":"s2-5-1","name":"Shower heads","days":{}},{"id":"s2-5-2","name":"Shower Drains","days":{}},{"id":"s2-5-3","name":"Cubicle Walls","days":{}},{"id":"s2-5-4","name":"Cubicle Floor","days":{}},{"id":"s2-5-5","name":"Cubicle Doors - Hinges, frames and holes","days":{}}]}]},{"id":"s3","name":"Accessible","subsections":[{"id":"s3-1","name":"Accessible","brief_area_id":null,"areas":[{"id":"s3-1-1","name":"Toilet Bowls - in, corners and beneath","days":{"sun":"scrub"}},{"id":"s3-1-2","name":"Wall Skirts and Hand-dryer","days":{"sun":"scrub"}},{"id":"s3-1-3","name":"Hand-wash Sinks and Mirrors","days":{"sun":"scrub"}},{"id":"s3-1-4","name":"Floor","days":{"sun":"scrub"}},{"id":"s3-1-5","name":"Walls and Wall Corners","days":{}},{"id":"s3-1-6","name":"Bench","days":{}},{"id":"s3-1-7","name":"Shower Heads and Pipes","days":{}}]}]}]}$j$::jsonb);
insert into public.work_plan_templates (vendor_org_id, name, description, segment, legend, plan) values
  (null, 'Gym floors', $d$Gym floors by level and zone: entrance, studios, weights, cardio and staircases. Based on a gym operator's cleaning schedule; the days and methods are a starting point.$d$, 'sme', $j${"scrub":{"label":"Scrub","minutes":null},"wash":{"label":"Wash","minutes":null},"clean":{"label":"Clean","minutes":null},"mop":{"label":"Mop","minutes":null}}$j$::jsonb, $j${"sections":[{"id":"s1","name":"Downstairs","subsections":[{"id":"s1-1","name":"Entrance to Welcome Desk Area","brief_area_id":null,"areas":[{"id":"s1-1-1","name":"Entrance Area","days":{}},{"id":"s1-1-2","name":"Entrance Pods/Door","days":{}},{"id":"s1-1-3","name":"Entrance Strip","days":{"sun":"wash"}},{"id":"s1-1-4","name":"Welcome Desk Area","days":{"sun":"wash"}},{"id":"s1-1-5","name":"Water and Drink Founts","days":{"sun":"clean"}},{"id":"s1-1-6","name":"Vending Machines","days":{"sun":"clean"}},{"id":"s1-1-7","name":"Bins","days":{}}]},{"id":"s1-2","name":"Function Area","brief_area_id":null,"areas":[{"id":"s1-2-1","name":"Function Floor","days":{"sun":"wash"}},{"id":"s1-2-2","name":"Function Carpet","days":{"sun":"wash"}}]},{"id":"s1-3","name":"Free Weights Area","brief_area_id":null,"areas":[{"id":"s1-3-1","name":"Floor","days":{"sun":"wash"}},{"id":"s1-3-2","name":"Carpets","days":{"sun":"wash"}},{"id":"s1-3-3","name":"Mirrors","days":{}}]},{"id":"s1-4","name":"Cycle Studio","brief_area_id":null,"areas":[{"id":"s1-4-1","name":"Floor","days":{"sun":"mop"}},{"id":"s1-4-2","name":"Walls and Corners","days":{}}]},{"id":"s1-5","name":"Threadmills Area","brief_area_id":null,"areas":[{"id":"s1-5-1","name":"Carpets","days":{}}]},{"id":"s1-6","name":"Flex Area","brief_area_id":null,"areas":[{"id":"s1-6-1","name":"Floor","days":{"sun":"wash"}},{"id":"s1-6-2","name":"Mirrors","days":{}}]}]},{"id":"s2","name":"Upstairs","subsections":[{"id":"s2-1","name":"Fixed Pins","brief_area_id":null,"areas":[{"id":"s2-1-1","name":"Floor","days":{}},{"id":"s2-1-2","name":"Wall Skirts","days":{}}]},{"id":"s2-2","name":"Threadmills Area","brief_area_id":null,"areas":[{"id":"s2-2-1","name":"Floor","days":{}},{"id":"s2-2-2","name":"Glass Rails","days":{}}]},{"id":"s2-3","name":"Weight Studio","brief_area_id":null,"areas":[{"id":"s2-3-1","name":"Floor","days":{}},{"id":"s2-3-2","name":"Mirrors","days":{}},{"id":"s2-3-3","name":"Bins","days":{}},{"id":"s2-3-4","name":"Bin Area Skirts","days":{}}]},{"id":"s2-4","name":"Flex Area","brief_area_id":null,"areas":[{"id":"s2-4-1","name":"Floor","days":{}},{"id":"s2-4-2","name":"Mirrors","days":{}},{"id":"s2-4-3","name":"Skirts","days":{}}]},{"id":"s2-5","name":"Staircase","brief_area_id":null,"areas":[{"id":"s2-5-1","name":"Floor","days":{}},{"id":"s2-5-2","name":"Glass Rails","days":{}},{"id":"s2-5-3","name":"Hollow Sides","days":{}},{"id":"s2-5-4","name":"Skirts","days":{}},{"id":"s2-5-5","name":"Bins","days":{}}]}]}]}$j$::jsonb);
