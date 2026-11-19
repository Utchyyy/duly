-- Documents for verification claims: who may add, replace, read and remove them, and what a change does to an Enterprise's decision.

create function pg_temp.email_of(u uuid) returns text language sql security definer as $$ select email::text from auth.users where id = u $$;
create function pg_temp.files(p text) returns bigint language sql as $$ select count(*) from storage.objects where bucket_id = 'claim-evidence' and name = p $$;

do $$
declare
  admin_u uuid := tests.mk_user('admin'); owner1 uuid := tests.mk_user('ent1-owner'); owner2 uuid := tests.mk_user('ent2-owner');
  viewer1 uuid := tests.mk_user('ent1-viewer'); vend_u uuid := tests.mk_user('vendor-admin'); vend2_u uuid := tests.mk_user('other-vendor-admin'); stranger uuid := tests.mk_user('stranger');
  duly_org uuid; ent1 uuid; ent2 uuid; vend uuid; vend2 uuid; iso uuid; dbs uuid; other_claim uuid;
  p1 text; p1b text; p_orphan text; p_dbs text; n bigint; b record; r record;
begin
  select id into duly_org from public.organisations where kind = 'platform';
  insert into public.memberships values (duly_org, admin_u, 'platform_admin');
  perform tests.as_user(admin_u);
  ent1 := public.admin_create_enterprise('Soft FM One', pg_temp.email_of(owner1));
  ent2 := public.admin_create_enterprise('Soft FM Two', pg_temp.email_of(owner2));
  vend := public.admin_create_vendor('Vendor Co', pg_temp.email_of(vend_u));
  vend2 := public.admin_create_vendor('Second Vendor Co', pg_temp.email_of(vend2_u));
  perform public.enterprise_add_vendor(ent1, vend);
  perform tests.as_su();
  insert into public.memberships values (ent1, viewer1, 'viewer');
  perform tests.as_user(owner1);
  perform public.enterprise_set_requirements(ent1, array['iso_9001']::public.claim_kind[]);
  perform tests.as_user(vend_u);
  insert into public.verification_claims (org_id, kind, reference, status) values (vend, 'iso_9001', 'ISO-1', 'pending') returning id into iso;
  insert into public.verification_claims (org_id, kind, reference, status) values (vend, 'dbs', 'Enhanced, 12 staff', 'pending') returning id into dbs;
  perform tests.as_user(vend2_u);
  insert into public.verification_claims (org_id, kind, reference, status) values (vend2, 'iso_9001', 'ISO-2', 'pending') returning id into other_claim;
  perform tests.as_su();
  p1 := vend || '/' || iso || '/cert.pdf'; p1b := vend || '/' || iso || '/cert-v2.pdf'; p_orphan := vend || '/' || iso || '/unused.pdf'; p_dbs := vend || '/' || dbs || '/dbs.pdf';

  select * into b from storage.buckets where id = 'claim-evidence';
  perform tests.eq(b.public, false, 'the bucket is private');
  perform tests.ok(b.file_size_limit <= 20 * 1024 * 1024, 'files have a size limit');
  perform tests.ok(b.allowed_mime_types @> array['application/pdf', 'image/jpeg', 'image/png'], 'PDFs and photos are allowed');
  perform tests.ok(not (b.allowed_mime_types && array['text/html', 'image/svg+xml', 'application/javascript']), 'no scriptable types');

  -- Adding a file.
  perform tests.as_user(vend_u);
  insert into storage.objects (bucket_id, name) values ('claim-evidence', p1);
  perform tests.eq(pg_temp.files(p1), 1::bigint, 'the vendor adds a document to its own claim and reads it back');
  insert into storage.objects (bucket_id, name) values ('claim-evidence', p_orphan);
  perform tests.throws(format('insert into storage.objects (bucket_id, name) values (''claim-evidence'', %L)', vend2 || '/' || other_claim || '/x.pdf'), '%row-level security%', 'not into another vendor''s folder');
  perform tests.throws(format('insert into storage.objects (bucket_id, name) values (''claim-evidence'', %L)', vend || '/' || other_claim || '/x.pdf'), '%row-level security%', 'nor under another vendor''s claim in its own folder');
  perform tests.throws(format('insert into storage.objects (bucket_id, name) values (''claim-evidence'', %L)', vend || '/x.pdf'), '%row-level security%', 'a file must sit under a claim');
  perform tests.throws(format('insert into storage.objects (bucket_id, name) values (''claim-evidence'', %L)', 'not-an-org/' || iso || '/x.pdf'), '%row-level security%', 'a path that does not start with an organisation is refused');
  perform tests.throws(format('insert into storage.objects (bucket_id, name) values (''claim-evidence'', %L)', vend || '/' || iso || '/deep/x.pdf'), '%row-level security%', 'and one nested deeper is refused');
  perform tests.as_user(owner1);
  perform tests.throws(format('insert into storage.objects (bucket_id, name) values (''claim-evidence'', %L)', vend || '/' || iso || '/enterprise.pdf'), '%row-level security%', 'an Enterprise cannot add a document to a vendor''s claim');
  perform tests.as_user(stranger);
  perform tests.throws(format('insert into storage.objects (bucket_id, name) values (''claim-evidence'', %L)', vend || '/' || iso || '/stranger.pdf'), '%row-level security%', 'nor a stranger');

  -- The claim must point at its own files.
  perform tests.as_user(vend_u);
  perform tests.throws(format('update public.verification_claims set evidence_path = %L where id = %L', vend2 || '/' || other_claim || '/x.pdf', iso), '%check constraint%', 'a claim cannot point at another vendor''s file');
  perform tests.throws(format('update public.verification_claims set evidence_path = %L where id = %L', vend || '/' || dbs || '/x.pdf', iso), '%check constraint%', 'nor at another of its own claims''s file');
  update public.verification_claims set evidence_path = p1 where id = iso;
  perform tests.ok(true, 'it can point at its own');

  -- Who can read.
  perform tests.eq(pg_temp.files(p_orphan), 1::bigint, 'the vendor reads a file even if no claim points at it yet');
  perform tests.as_user(owner1);
  perform tests.eq(pg_temp.files(p1), 1::bigint, 'an Enterprise owner whose roster has the vendor reads the file its claim points at');
  perform tests.eq(pg_temp.files(p_orphan), 0::bigint, 'but not a file no claim points at');
  perform tests.as_user(viewer1);
  perform tests.eq(pg_temp.files(p1), 1::bigint, 'an Enterprise viewer can too');
  perform tests.as_user(owner2);
  perform tests.eq(pg_temp.files(p1), 0::bigint, 'an Enterprise without the vendor on its roster cannot');
  perform tests.as_user(vend2_u);
  perform tests.eq(pg_temp.files(p1), 0::bigint, 'nor another vendor');
  perform tests.as_user(stranger);
  perform tests.eq(pg_temp.files(p1), 0::bigint, 'nor a stranger');
  perform tests.as_anon();
  perform tests.eq((select count(*) from storage.objects where bucket_id = 'claim-evidence'), 0::bigint, 'signed-out visitors read none');
  perform tests.as_user(admin_u);
  perform tests.eq(pg_temp.files(p1) + pg_temp.files(p_orphan), 2::bigint, 'Duly reads all of them');

  -- Personal checks stay between the vendor and Duly.
  perform tests.as_user(vend_u);
  insert into storage.objects (bucket_id, name) values ('claim-evidence', p_dbs);
  update public.verification_claims set evidence_path = p_dbs where id = dbs;
  perform tests.eq(pg_temp.files(p_dbs), 1::bigint, 'the vendor keeps a DBS document');
  perform tests.as_user(owner1);
  perform tests.eq(pg_temp.files(p_dbs), 0::bigint, 'an Enterprise cannot read a DBS document, even for a vendor on its roster');
  perform tests.as_user(admin_u);
  perform tests.eq(pg_temp.files(p_dbs), 1::bigint, 'Duly can');

  -- The Enterprise sees where the document is.
  perform tests.as_user(owner1);
  select * into r from public.enterprise_vendor_compliance(ent1) where kind = 'iso_9001';
  perform tests.eq(r.evidence_path, p1, 'the compliance view carries the document''s path');
  perform tests.eq(r.state, 'awaiting', 'a claim with a document still waits for review');
  perform public.enterprise_review_claim(ent1, iso, 'accepted', 'Certificate seen');
  select * into r from public.enterprise_vendor_compliance(ent1) where kind = 'iso_9001'; perform tests.eq(r.state, 'accepted', 'the Enterprise accepts it');

  -- Replacing the file clears the decision.
  perform tests.as_user(vend_u);
  insert into storage.objects (bucket_id, name) values ('claim-evidence', p1b);
  update public.verification_claims set evidence_path = p1b where id = iso;
  perform tests.as_user(owner1);
  select * into r from public.enterprise_vendor_compliance(ent1) where kind = 'iso_9001';
  perform tests.eq(r.state, 'awaiting', 'replacing the document clears the decision: it waits for review again'); perform tests.eq(r.evidence_path, p1b, 'on the new document');
  perform tests.eq(pg_temp.files(p1b), 1::bigint, 'the Enterprise reads the new one');
  perform tests.eq(pg_temp.files(p1), 0::bigint, 'and no longer the old one');
  perform tests.as_user(vend_u);
  perform tests.eq(pg_temp.files(p1), 1::bigint, 'the vendor still has the old file until it removes it');
  delete from storage.objects where bucket_id = 'claim-evidence' and name = p1;
  perform tests.eq(pg_temp.files(p1), 0::bigint, 'and can remove it');
  perform tests.as_user(owner1);
  delete from storage.objects where bucket_id = 'claim-evidence' and name = p1b; get diagnostics n = row_count;
  perform tests.eq(n, 0::bigint, 'an Enterprise cannot remove a vendor''s document');

  -- Removing the document from the claim also clears the decision.
  perform public.enterprise_review_claim(ent1, iso, 'accepted');
  perform tests.as_user(vend_u);
  update public.verification_claims set evidence_path = null where id = iso;
  perform tests.as_su(); perform tests.eq((select count(*) from public.enterprise_claim_reviews where claim_id = iso), 0::bigint, 'taking the document off the claim clears the decision too');

  -- Once Duly has verified a claim, its documents are fixed.
  perform tests.as_user(vend_u);
  update public.verification_claims set evidence_path = p1b where id = iso;
  perform tests.as_user(admin_u);
  update public.verification_claims set status = 'verified', verified_by = admin_u, verified_at = now() where id = iso;
  perform tests.as_user(vend_u);
  perform tests.throws(format('insert into storage.objects (bucket_id, name) values (''claim-evidence'', %L)', vend || '/' || iso || '/late.pdf'), '%row-level security%', 'a verified claim takes no new document');
  delete from storage.objects where bucket_id = 'claim-evidence' and name = p1b; get diagnostics n = row_count;
  perform tests.eq(n, 0::bigint, 'and its document cannot be removed by the vendor');
  perform tests.as_su();
  perform tests.ok((select count(*) from public.audit_log where table_name = 'verification_claims' and row_id = iso::text) >= 3, 'document changes are on the record');
end $$;
