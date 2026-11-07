-- AI brief drafting: drafts live only in approval_queue until a person approves them.
create function pg_temp.sample_draft() returns jsonb language sql as $$
  select '{
    "title": "Weekly surgery clean",
    "site": {"name": "Harbour Dental", "address": "1 Quay Street", "postcode": "co1 1aa", "town": "Colchester", "access_notes": "Key safe"},
    "visits": {"days": ["tue", "thu"], "start_time": "18:00"},
    "sections": [
      {"name": "Clinical", "areas": [
        {"name": "Surgery 1", "area_type": "clinical", "minutes": 45, "minutes_source": "stated",
         "standards": ["Surfaces disinfected", "Floor mopped dry"]},
        {"name": "Waiting room", "area_type": "reception", "minutes": 20, "minutes_source": "estimated", "standards": []}]}
    ],
    "assumptions": ["Minutes for the waiting room were estimated"],
    "questions": ["Is there a second surgery?"]
  }'::jsonb
$$;

do $$
declare
  owner_u uuid := tests.mk_user('owner'); approver_u uuid := tests.mk_user('approver'); viewer_u uuid := tests.mk_user('viewer');
  other_u uuid := tests.mk_user('other-owner'); vendor_u uuid := tests.mk_user('vendor'); stranger_u uuid := tests.mk_user('stranger');
  org uuid; other_org uuid; vendor_org uuid; item uuid; item2 uuid; n bigint; briefs_before bigint;
begin
  perform tests.as_user(owner_u); org := public.create_buyer_org('Harbour Dental', 'sme');
  perform tests.as_user(other_u); other_org := public.create_buyer_org('Someone Else', 'sme');
  perform tests.as_su();
  insert into public.memberships values (org, approver_u, 'approver'), (org, viewer_u, 'viewer');
  select id into vendor_org from public.organisations where name = 'Clean-Fit';
  insert into public.memberships values (vendor_org, vendor_u, 'vendor_admin');
  select count(*) into briefs_before from public.briefs;

  -- Who can add a draft: the organisation's owners and approvers, as themselves, as pending.
  perform tests.as_user(owner_u);
  insert into public.approval_queue (org_id, source, draft) values (org, '{"generated_by":"ai"}', pg_temp.sample_draft()) returning id into item;
  perform tests.ok(item is not null, 'an owner can add a pending draft');
  perform tests.eq((select created_by from public.approval_queue where id = item), owner_u, 'the draft is attributed to the person who requested it');
  perform tests.as_user(approver_u);
  insert into public.approval_queue (org_id, source, draft) values (org, '{}', pg_temp.sample_draft());
  perform tests.ok(true, 'an approver can add a pending draft');
  perform tests.as_user(viewer_u);
  perform tests.throws(format('insert into public.approval_queue (org_id, draft) values (%L, %L)', org, '{}'), '%row-level security%', 'a viewer cannot add drafts');
  perform tests.eq((select count(*) from public.approval_queue where org_id = org), 2::bigint, 'a viewer can see the organisation''s drafts');
  perform tests.as_user(other_u);
  perform tests.throws(format('insert into public.approval_queue (org_id, draft) values (%L, %L)', org, '{}'), '%row-level security%', 'another organisation cannot add drafts here');
  perform tests.eq((select count(*) from public.approval_queue where org_id = org), 0::bigint, 'another organisation cannot see these drafts');
  perform tests.as_user(vendor_u);
  perform tests.throws(format('insert into public.approval_queue (org_id, draft) values (%L, %L)', org, '{}'), '%row-level security%', 'a vendor cannot add drafts');
  perform tests.as_user(stranger_u);
  perform tests.eq((select count(*) from public.approval_queue), 0::bigint, 'a user with no organisation sees no drafts');
  perform tests.as_anon();
  perform tests.eq((select count(*) from (select 1 from public.approval_queue) x), 0::bigint, 'signed-out visitors see no drafts');

  -- A draft can only be added as pending, by the person themselves, with nothing pre-approved.
  perform tests.as_user(owner_u);
  perform tests.throws(format('insert into public.approval_queue (org_id, status, draft) values (%L, %L, %L)', org, 'approved', '{}'), '%row-level security%', 'a draft cannot be added already approved');
  perform tests.throws(format('insert into public.approval_queue (org_id, created_by, draft) values (%L, %L, %L)', org, approver_u, '{}'), '%row-level security%', 'a draft cannot be attributed to someone else');
  perform tests.throws(format('insert into public.approval_queue (org_id, kind, draft) values (%L, %L, %L)', org, 'other', '{}'), '%row-level security%', 'only brief drafts are accepted');

  -- Direct edits do nothing: the queue changes only through approve / reject.
  update public.approval_queue set status = 'approved' where id = item;
  get diagnostics n = row_count;
  perform tests.eq(n, 0::bigint, 'an owner cannot mark a draft approved directly');
  update public.approval_queue set draft = '{"title":"x"}' where id = item;
  get diagnostics n = row_count;
  perform tests.eq(n, 0::bigint, 'an owner cannot rewrite a draft directly');
  delete from public.approval_queue where id = item;
  get diagnostics n = row_count;
  perform tests.eq(n, 0::bigint, 'an owner cannot delete a draft directly');
  perform tests.as_su();
  perform tests.eq((select count(*) from public.briefs), briefs_before, 'adding drafts creates no briefs');
  perform tests.eq((select status::text from public.approval_queue where id = item), 'pending', 'the draft is still pending');

  -- Only an owner or approver approves; nothing is created for anyone else.
  perform tests.as_user(viewer_u);
  perform tests.throws(format('select public.approve_brief_draft(%L, %L)', item, pg_temp.sample_draft()), '%Only an owner or approver%', 'a viewer cannot approve');
  perform tests.as_user(other_u);
  perform tests.throws(format('select public.approve_brief_draft(%L, %L)', item, pg_temp.sample_draft()), '%Only an owner or approver%', 'another organisation cannot approve');
  perform tests.as_user(vendor_u);
  perform tests.throws(format('select public.reject_brief_draft(%L)', item), '%Only an owner or approver%', 'a vendor cannot reject');

  -- Approval needs the site: an existing one of this organisation, or a looked-up postcode.
  perform tests.as_user(approver_u);
  perform tests.throws(format('select public.approve_brief_draft(%L, %L)', item, pg_temp.sample_draft()), '%Look up the postcode%', 'a new site needs coordinates');
  perform tests.as_su();
  perform tests.eq((select count(*) from public.briefs), briefs_before, 'a refused approval creates nothing');

  -- Approve (as edited by the person: they trimmed a minute figure and renamed the brief).
  perform tests.as_user(approver_u);
  item2 := public.approve_brief_draft(item,
    jsonb_set(jsonb_set(pg_temp.sample_draft(), '{title}', '"Weekly surgery clean (edited)"'), '{sections,0,areas,0,minutes}', '50'),
    null, 51.8909, 0.9009);
  perform tests.as_su();
  perform tests.eq((select title from public.briefs where id = item2), 'Weekly surgery clean (edited)', 'the brief carries the person''s edits, not the AI''s text');
  perform tests.eq((select status::text from public.briefs where id = item2), 'draft', 'the new brief is an unlocked draft');
  perform tests.eq((select locked_at is null from public.brief_versions where brief_id = item2 and version = 1), true, 'the brief version is not locked');
  perform tests.eq((select b.buyer_org_id from public.briefs b where b.id = item2), org, 'the brief belongs to the organisation');
  perform tests.eq((select s.name || '|' || s.postcode from public.sites s join public.briefs b on b.site_id = s.id where b.id = item2), 'Harbour Dental|CO1 1AA', 'the site was created with a normalised postcode');
  perform tests.eq((select s.lat from public.sites s join public.briefs b on b.site_id = s.id where b.id = item2), 51.8909::numeric, 'the site has the looked-up coordinates');
  perform tests.eq((select preferred_days from public.brief_versions where brief_id = item2), array['tue', 'thu'], 'visit days carried over');
  perform tests.eq((select preferred_start::text from public.brief_versions where brief_id = item2), '18:00:00', 'start time carried over');
  perform tests.eq((select sum((a ->> 'minutes')::int) from public.brief_versions bv, jsonb_array_elements(bv.schedule) s, jsonb_array_elements(s -> 'areas') a where bv.brief_id = item2), 70::bigint, 'minutes follow the edited draft (50 + 20)');
  perform tests.eq((select count(distinct a ->> 'id') from public.brief_versions bv, jsonb_array_elements(bv.schedule) s, jsonb_array_elements(s -> 'areas') a where bv.brief_id = item2), 2::bigint, 'every area has its own generated id');
  perform tests.eq((select count(*) from public.brief_versions bv, jsonb_array_elements(bv.schedule) s, jsonb_array_elements(s -> 'areas') a, jsonb_array_elements(a -> 'standards') t where bv.brief_id = item2 and a ->> 'name' = 'Surgery 1'), 2::bigint, 'the drafted standards were carried over untouched');
  perform tests.eq((select count(*) from public.brief_versions bv, jsonb_array_elements(bv.schedule) s, jsonb_array_elements(s -> 'areas') a, jsonb_array_elements(a -> 'standards') t where bv.brief_id = item2 and a ->> 'name' = 'Waiting room'), 1::bigint, 'an area with no drafted standards gets the library standard for its type');
  perform tests.eq((select t ->> 'text' from public.brief_versions bv, jsonb_array_elements(bv.schedule) s, jsonb_array_elements(s -> 'areas') a, jsonb_array_elements(a -> 'standards') t where bv.brief_id = item2 and a ->> 'name' = 'Waiting room'), (select text from public.standards_library where segment = 'sme' and area_type = 'reception'), 'and it is the segment''s own library text');
  perform tests.ok(not exists (select 1 from public.brief_versions bv, jsonb_array_elements(bv.schedule) s, jsonb_array_elements(s -> 'areas') a, jsonb_array_elements(a -> 'standards') t where bv.brief_id = item2 and (t ->> 'id') is null), 'library standards get generated ids too');
  perform tests.ok(not exists (select 1 from public.brief_versions bv, jsonb_array_elements(bv.schedule) s, jsonb_array_elements(s -> 'areas') a, jsonb_array_elements(a -> 'standards') t where bv.brief_id = item2 and (t ->> 'id') is null), 'every standard has a generated id');
  perform tests.eq((select status::text from public.approval_queue where id = item), 'approved', 'the queue item is approved');
  perform tests.eq((select reviewed_by from public.approval_queue where id = item), approver_u, 'the approver is recorded');
  perform tests.eq((select result_brief_id from public.approval_queue where id = item), item2, 'the queue item points at the brief it produced');
  perform tests.eq((select draft #>> '{title}' from public.approval_queue where id = item), 'Weekly surgery clean', 'the AI''s original draft is kept as it was');
  perform tests.eq((select final_draft #>> '{title}' from public.approval_queue where id = item), 'Weekly surgery clean (edited)', 'the approved version is kept alongside it');
  perform tests.eq((select count(*) from public.quotes where brief_id = item2), 0::bigint, 'approval invites no vendors and prices nothing');
  perform tests.as_user(approver_u);
  perform tests.throws(format('select public.approve_brief_draft(%L, %L)', item, pg_temp.sample_draft()), '%already approved%', 'a draft cannot be approved twice');
  perform tests.throws(format('select public.reject_brief_draft(%L)', item), '%already approved%', 'an approved draft cannot be rejected');
end $$;

-- Existing site, rejection, and a bad draft never becomes a brief.
do $$
declare
  owner_u uuid := tests.mk_user('owner2'); other_u uuid := tests.mk_user('other2');
  org uuid; other_org uuid; own_site uuid; foreign_site uuid; item uuid; item_b uuid; bid uuid; briefs_before bigint; bad jsonb;
begin
  perform tests.as_user(owner_u); org := public.create_buyer_org('Org Two', 'sme');
  insert into public.sites (org_id, name, postcode, lat, lng) values (org, 'Own site', 'CO2 2BB', 51.9, 0.9) returning id into own_site;
  perform tests.as_user(other_u); other_org := public.create_buyer_org('Other Two', 'sme');
  insert into public.sites (org_id, name, postcode, lat, lng) values (other_org, 'Their site', 'CO3 3CC', 51.9, 0.9) returning id into foreign_site;
  perform tests.as_user(owner_u);
  insert into public.approval_queue (org_id, draft) values (org, pg_temp.sample_draft()) returning id into item;
  insert into public.approval_queue (org_id, draft) values (org, pg_temp.sample_draft()) returning id into item_b;
  perform tests.as_su(); select count(*) into briefs_before from public.briefs;

  perform tests.as_user(owner_u);
  perform tests.throws(format('select public.approve_brief_draft(%L, %L, %L)', item, pg_temp.sample_draft(), foreign_site), '%does not belong%', 'a draft cannot be attached to another organisation''s site');
  bid := public.approve_brief_draft(item, pg_temp.sample_draft(), own_site);
  perform tests.as_su();
  perform tests.eq((select site_id from public.briefs where id = bid), own_site, 'an existing site is used when chosen');
  perform tests.eq((select count(*) from public.sites where org_id = org), 1::bigint, 'no extra site was created');

  -- Rejecting.
  perform tests.as_user(owner_u);
  perform public.reject_brief_draft(item_b, 'Not what we meant');
  perform tests.as_su();
  perform tests.eq((select status::text || '|' || reject_reason from public.approval_queue where id = item_b), 'rejected|Not what we meant', 'a rejected draft records its reason');
  perform tests.as_user(owner_u);
  perform tests.throws(format('select public.approve_brief_draft(%L, %L, %L)', item_b, pg_temp.sample_draft(), own_site), '%already rejected%', 'a rejected draft cannot be approved');

  -- Invalid drafts are refused, whether from the model or from an edit.
  perform tests.as_user(owner_u);
  insert into public.approval_queue (org_id, draft) values (org, '{}') returning id into item;
  perform tests.as_su(); select count(*) into briefs_before from public.briefs; perform tests.as_user(owner_u);
  foreach bad in array array[
    pg_temp.sample_draft() - 'title',
    jsonb_set(pg_temp.sample_draft(), '{sections}', '[]'),
    jsonb_set(pg_temp.sample_draft(), '{sections,0,areas,0,minutes}', '0'),
    jsonb_set(pg_temp.sample_draft(), '{sections,0,areas,0,minutes}', '601'),
    jsonb_set(pg_temp.sample_draft(), '{sections,0,areas,0,minutes}', '12.5'),
    jsonb_set(pg_temp.sample_draft(), '{sections,0,areas,0,minutes}', '"lots"'),
    jsonb_set(pg_temp.sample_draft(), '{sections,0,areas,0,name}', '""'),
    jsonb_set(pg_temp.sample_draft(), '{sections,0,areas,0,standards}', (select jsonb_agg('standard ' || g) from generate_series(1, 13) g)),
    jsonb_set(pg_temp.sample_draft(), '{sections,0,areas,0,standards}', to_jsonb(array[repeat('x', 201)])),
    jsonb_set(pg_temp.sample_draft(), '{visits,days}', '["someday"]'),
    jsonb_set(pg_temp.sample_draft(), '{visits,start_time}', '"6pm"'),
    jsonb_set(pg_temp.sample_draft(), '{title}', to_jsonb(repeat('t', 121)))
  ] loop
    begin
      perform public.approve_brief_draft(item, bad, own_site);
      raise exception 'FAIL: an invalid draft was accepted: %', left(bad::text, 120);
    exception when others then
      if sqlerrm like 'FAIL:%' then raise; end if;
    end;
  end loop;
  perform tests.ok(true, 'twelve kinds of invalid draft were all refused');
  perform tests.as_su();
  perform tests.eq((select count(*) from public.briefs), briefs_before, 'no invalid draft became a brief');
  perform tests.eq((select status::text from public.approval_queue where id = item), 'pending', 'the draft is still waiting after refused approvals');
end $$;

-- Limits: pending drafts and drafts per day.
do $$
declare owner_u uuid := tests.mk_user('owner3'); org uuid; i int;
begin
  perform tests.as_user(owner_u); org := public.create_buyer_org('Org Three', 'sme');
  for i in 1..10 loop insert into public.approval_queue (org_id, draft) values (org, '{}'); end loop;
  perform tests.throws(format('insert into public.approval_queue (org_id, draft) values (%L, %L)', org, '{}'), '%Too many drafts%', 'at most 10 drafts can wait at once');
  perform tests.as_su();
  update public.approval_queue set status = 'rejected' where org_id = org;
  for i in 11..25 loop insert into public.approval_queue (org_id, status, draft) values (org, 'rejected', '{}'); end loop;
  perform tests.as_user(owner_u);
  perform tests.throws(format('insert into public.approval_queue (org_id, draft) values (%L, %L)', org, '{}'), '%Daily drafting limit%', 'at most 25 drafts per organisation per day');
  perform tests.as_su();
end $$;

-- Source documents: private, per organisation, owners and approvers only, never altered.
do $$
declare
  owner_u uuid := tests.mk_user('owner4'); viewer_u uuid := tests.mk_user('viewer4'); other_u uuid := tests.mk_user('other4');
  org uuid; other_org uuid; path text; n bigint; b record;
begin
  perform tests.as_user(owner_u); org := public.create_buyer_org('Org Four', 'sme');
  perform tests.as_user(other_u); other_org := public.create_buyer_org('Other Four', 'sme');
  perform tests.as_su();
  insert into public.memberships values (org, viewer_u, 'viewer');
  path := org || '/1700000000-spec.pdf';
  select * into b from storage.buckets where id = 'brief-sources';
  perform tests.eq(b.public, false, 'the source-document bucket is private');
  perform tests.ok(b.file_size_limit <= 20 * 1024 * 1024, 'source documents have a size limit');
  perform tests.ok(b.allowed_mime_types @> array['application/pdf', 'image/jpeg', 'text/plain'], 'PDFs, photos and text are allowed');
  perform tests.ok(not (b.allowed_mime_types && array['text/html', 'image/svg+xml', 'application/javascript']), 'no scriptable types are allowed');

  perform tests.as_user(owner_u);
  insert into storage.objects (bucket_id, name) values ('brief-sources', path);
  perform tests.ok(true, 'an owner can upload to their organisation''s folder');
  perform tests.eq((select count(*) from storage.objects where name = path), 1::bigint, 'an owner can read it back');
  perform tests.throws(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'brief-sources', other_org || '/x.pdf'), '%row-level security%', 'an owner cannot upload to another organisation''s folder');
  perform tests.throws(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'brief-sources', 'not-an-org/x.pdf'), '%', 'a path that does not start with an organisation id is refused');
  perform tests.as_user(viewer_u);
  perform tests.throws(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'brief-sources', org || '/viewer.pdf'), '%row-level security%', 'a viewer cannot upload');
  perform tests.eq((select count(*) from storage.objects where name = path), 0::bigint, 'a viewer cannot read source documents');
  perform tests.as_user(other_u);
  perform tests.eq((select count(*) from storage.objects where name = path), 0::bigint, 'another organisation cannot read them');
  perform tests.as_anon();
  perform tests.eq((select count(*) from storage.objects), 0::bigint, 'signed-out visitors read no source documents');
  perform tests.as_user(owner_u);
  update storage.objects set name = org || '/renamed.pdf' where name = path;
  get diagnostics n = row_count;
  perform tests.eq(n, 0::bigint, 'an uploaded source document cannot be renamed');
  delete from storage.objects where name = path;
  get diagnostics n = row_count;
  perform tests.eq(n, 0::bigint, 'an uploaded source document cannot be deleted');
  perform tests.as_su();
end $$;

-- An area whose type has no library standards stays empty (the brief editor then says which to fix).
do $$
declare owner_u uuid := tests.mk_user('owner-fill'); org uuid; item uuid; bid uuid; d jsonb;
begin
  perform tests.as_user(owner_u); org := public.create_buyer_org('Fill Org', 'sme');
  d := jsonb_set(pg_temp.sample_draft(), '{sections,0,areas,1,area_type}', '"loading_bay"');
  insert into public.approval_queue (org_id, draft) values (org, d) returning id into item;
  bid := public.approve_brief_draft(item, d, null, 51.9, 0.9);
  perform tests.as_su();
  perform tests.eq((select count(*) from public.brief_versions bv, jsonb_array_elements(bv.schedule) s, jsonb_array_elements(s -> 'areas') a, jsonb_array_elements(a -> 'standards') t where bv.brief_id = bid and a ->> 'name' = 'Waiting room'), 0::bigint, 'no library standards for the type: the area stays empty rather than guessing');
  perform tests.eq((select (final_draft #> '{sections,0,areas,1,standards}')::text from public.approval_queue where id = item), '[]', 'the approved draft on record still shows what the person approved');
end $$;
