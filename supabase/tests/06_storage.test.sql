-- Evidence storage: a private bucket, files under <job_id>/..., readable by the job's parties, writable by its crew.
do $$
declare
  f jsonb; g jsonb; v_job uuid; path text; n bigint; b record; v_other_u uuid := tests.mk_user('rival');
begin
  insert into public.memberships select id, v_other_u, 'vendor_admin' from public.organisations where name = 'Colne Clean Co (sample)';
  f := tests.book_job('sme');
  g := tests.book_job('sme');                 -- an unrelated job with its own crew
  v_job := (f ->> 'job')::uuid;
  path := v_job || '/a1/1700000000000-photo_after.jpg';

  select * into b from storage.buckets where id = 'evidence';
  perform tests.ok(b.id is not null, 'the evidence bucket exists');
  perform tests.eq(b.public, false, 'the evidence bucket is private');
  perform tests.ok(b.file_size_limit is not null and b.file_size_limit <= 20 * 1024 * 1024, 'uploads have a size limit');
  perform tests.ok(b.allowed_mime_types @> array['image/jpeg', 'image/png'], 'photos are allowed');
  perform tests.ok(not (b.allowed_mime_types && array['text/html', 'image/svg+xml', 'application/javascript']), 'no scriptable types are allowed');

  -- Upload: only crew on this job.
  perform tests.as_user((f ->> 'crew')::uuid);
  insert into storage.objects (bucket_id, name) values ('evidence', path);
  perform tests.ok(true, 'assigned crew can upload to their job folder');
  perform tests.throws(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'evidence', (g ->> 'job') || '/a1/x.jpg'),
                       '%row-level security%', 'crew cannot upload to another job''s folder');
  perform tests.throws(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'other', v_job || '/a1/x.jpg'),
                       '%row-level security%', 'uploads to other buckets are not allowed by these policies');
  perform tests.throws(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'evidence', 'not-a-job/a1/x.jpg'),
                       '%', 'a path that does not start with a job id is refused');
  perform tests.as_user((f ->> 'buyer')::uuid);
  perform tests.throws(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'evidence', v_job || '/a1/buyer.jpg'),
                       '%row-level security%', 'the client cannot upload evidence');
  -- The job's own vendor staff may work a job (can_work_job); another vendor's staff may not.
  perform tests.as_user((f ->> 'vendor')::uuid);
  insert into storage.objects (bucket_id, name) values ('evidence', v_job || '/a2/office.jpg');
  perform tests.ok(true, 'the job''s own vendor staff can upload evidence');
  perform tests.as_user(v_other_u);
  perform tests.throws(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'evidence', v_job || '/a1/rival.jpg'),
                       '%row-level security%', 'another vendor''s staff cannot upload evidence');
  perform tests.eq((select count(*) from storage.objects where bucket_id = 'evidence'), 0::bigint, 'another vendor cannot read the evidence');
  perform tests.as_anon();
  perform tests.throws(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'evidence', v_job || '/a1/anon.jpg'),
                       '%', 'signed-out visitors cannot upload');

  -- Read: the job's parties and Duly only.
  perform tests.as_user((f ->> 'buyer')::uuid);
  perform tests.eq((select count(*) from storage.objects where bucket_id = 'evidence' and name = path), 1::bigint, 'the client can read the evidence');
  perform tests.as_user((f ->> 'vendor')::uuid);
  perform tests.eq((select count(*) from storage.objects where bucket_id = 'evidence' and name = path), 1::bigint, 'the vendor can read the evidence');
  perform tests.as_user((f ->> 'admin')::uuid);
  perform tests.eq((select count(*) from storage.objects where bucket_id = 'evidence' and name = path), 1::bigint, 'Duly can read the evidence');
  perform tests.as_user((g ->> 'buyer')::uuid);
  perform tests.eq((select count(*) from storage.objects where name = path), 0::bigint, 'another client cannot read it');
  -- Note: operatives of the same company can currently read all of that company's jobs
  -- (private.can_see_job uses is_member on the vendor org); not asserted here.
  perform tests.as_user(tests.mk_user('stranger'));
  perform tests.eq((select count(*) from storage.objects where name = path), 0::bigint, 'a user with no organisation cannot read it');
  perform tests.as_anon();
  perform tests.eq((select count(*) from storage.objects), 0::bigint, 'signed-out visitors read no files');

  -- Evidence cannot be replaced or removed by the people who captured it.
  perform tests.as_user((f ->> 'crew')::uuid);
  update storage.objects set name = v_job || '/a1/renamed.jpg' where name = path;
  get diagnostics n = row_count;
  perform tests.eq(n, 0::bigint, 'crew cannot rename an uploaded file');
  delete from storage.objects where name = path;
  get diagnostics n = row_count;
  perform tests.eq(n, 0::bigint, 'crew cannot delete an uploaded file');
  perform tests.as_user((f ->> 'vendor')::uuid);
  delete from storage.objects where name = path;
  get diagnostics n = row_count;
  perform tests.eq(n, 0::bigint, 'the vendor cannot delete an uploaded file');
  perform tests.as_su();
  perform tests.eq((select count(*) from storage.objects where name = path), 1::bigint, 'the file is still there');

  -- The evidence table itself: only crew on the job can add rows.
  perform tests.as_user((f ->> 'buyer')::uuid);
  perform tests.throws(format('insert into public.evidence (job_id, area_id, kind, storage_path) values (%L, %L, %L, %L)', v_job, 'a1', 'photo_after', path),
                       '%row-level security%', 'the client cannot add evidence rows');
  perform tests.as_user((g ->> 'crew')::uuid);
  perform tests.throws(format('insert into public.evidence (job_id, area_id, kind, storage_path) values (%L, %L, %L, %L)', v_job, 'a1', 'photo_after', path),
                       '%row-level security%', 'crew on another job cannot add evidence rows');
  perform tests.as_user((f ->> 'crew')::uuid);
  insert into public.evidence (job_id, area_id, kind, storage_path) values (v_job, 'a1', 'photo_after', path);
  perform tests.eq((select uploaded_by from public.evidence where storage_path = path), (f ->> 'crew')::uuid, 'the uploader is recorded by the database');
  update public.evidence set within_geofence = true where storage_path = path;
  get diagnostics n = row_count;
  perform tests.eq(n, 0::bigint, 'crew cannot edit an evidence row (geofence result stays as recorded)');
  perform tests.as_su();
end $$;
