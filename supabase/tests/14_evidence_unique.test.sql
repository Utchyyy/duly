-- One evidence row per stored photo, so a photo sent twice (a retry, two tabs) is recorded once.
do $$
declare f jsonb; g jsonb; job uuid; path text; n bigint;
begin
  f := tests.book_job('sme'); g := tests.book_job('sme');
  job := (f ->> 'job')::uuid;
  path := job || '/a1/1700000000001-photo_after.jpg';

  perform tests.as_user((f ->> 'crew')::uuid);
  insert into public.evidence (job_id, area_id, kind, storage_path, lat, lng, taken_at) values (job, 'a1', 'photo_after', path, 51.8893, 0.9043, '2026-11-07T08:15:00Z');
  perform tests.throws(format('insert into public.evidence (job_id, area_id, kind, storage_path) values (%L, %L, %L, %L)', job, 'a1', 'photo_after', path),
                       '%duplicate key%', 'the same stored photo cannot be recorded twice');
  perform tests.throws(format('insert into public.evidence (job_id, area_id, kind, storage_path) values (%L, %L, %L, %L)', job, 'a2', 'photo_before', path),
                       '%duplicate key%', 'nor under a different area or kind');
  insert into public.evidence (job_id, area_id, kind, storage_path) values (job, 'a1', 'photo_after', job || '/a1/1700000000002-photo_after.jpg');
  perform tests.ok(true, 'a different photo of the same area is fine');
  perform tests.as_su();
  select count(*) into n from public.evidence where job_id = job;
  perform tests.eq(n, 2::bigint, 'exactly the two distinct photos are recorded');

  -- The time it was actually taken, not the time it was sent, is what is kept.
  perform tests.eq((select taken_at from public.evidence where storage_path = path), '2026-11-07T08:15:00Z'::timestamptz, 'a late upload keeps the time the photo was taken');
  perform tests.eq((select within_geofence from public.evidence where storage_path = path), true, 'and the place it was taken is checked against the site');
end $$;
