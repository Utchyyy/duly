-- A photo is evidence once. The Crew app sends photos that were taken without a signal as soon as there is one,
-- possibly from two places at the same moment (two tabs, a retry after a dropped connection). The check "is it
-- already recorded?" is not atomic, so the database has to be the one that says no: one evidence row per stored file.
-- The app treats this violation as "already recorded", not as an error.
create unique index evidence_storage_path_key on public.evidence (storage_path);
