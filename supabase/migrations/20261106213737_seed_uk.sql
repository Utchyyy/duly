-- Seed: UK market, segments, policies, standards, towns, a library schedule template,
-- Clean-Fit as the first real vendor (no scores until it has real jobs), and clearly
-- labelled sample vendors for testing search and ranking. Delete the samples before launch:
--   delete from public.organisations where name like '%(sample)';

insert into public.markets (code, name, currency, locale, tax_name, tax_rate, data_region, postcode_pattern) values
  ('UK', 'United Kingdom', 'GBP', 'en-GB', 'VAT', 20.00, 'eu-west-1',
   '^[A-Z]{1,2}[0-9][A-Z0-9]? ?[0-9][A-Z]{2}$');

insert into public.segments (code, name, description) values
  ('homeowner',   'Homes',       'One-off and recurring domestic cleans paid through escrow.'),
  ('sme',         'Small business', 'Offices, gyms, shops and clinics on monthly plans.'),
  ('enterprise',  'Enterprise',  'Multi-site contracts on invoice terms.'),
  ('healthcare',  'Healthcare',  'Clinical and care settings with stricter verification.'),
  ('hospitality', 'Hospitality', 'Hotels, short lets and venues with turnaround windows.');

-- platform_fee_pct is left unset on purpose: set it in Duly Admin once agreed.
insert into public.policies (market, segment, payment_model, first_release_pct, first_release_on, balance_release_hours, min_verification_tier, reclean_window_hours, standards_library) values
  ('UK', 'homeowner',   'escrow_one_off',     55, 'approval',  48, 1, 24, 'homeowner'),
  ('UK', 'sme',         'monthly_in_advance', 55, 'month_end', 48, 1, 24, 'sme'),
  ('UK', 'enterprise',  'invoice_terms',      55, 'approval',  48, 2, 24, 'sme'),
  ('UK', 'healthcare',  'invoice_terms',      55, 'approval',  48, 2, 12, 'healthcare'),
  ('UK', 'hospitality', 'monthly_in_advance', 55, 'month_end', 48, 1, 12, 'hospitality');

insert into public.standards_library (segment, area_type, text) values
  ('homeowner', 'kitchen',   'Worktops, hob and sink wiped and dry; no crumbs or grease marks.'),
  ('homeowner', 'kitchen',   'Appliance fronts and handles smear-free.'),
  ('homeowner', 'bathroom',  'Toilet, basin, bath and shower descaled; no visible limescale or hair.'),
  ('homeowner', 'bathroom',  'Mirrors and glass streak-free.'),
  ('homeowner', 'living',    'Surfaces dust-free at hand height; floors vacuumed edge to edge.'),
  ('homeowner', 'bedroom',   'Beds made if linen provided; floors vacuumed including under bed edges.'),
  ('sme', 'office',          'Desks cleared of dust where unoccupied; bins emptied and relined.'),
  ('sme', 'office',          'Touch points (handles, switches, lift buttons) wiped with disinfectant.'),
  ('sme', 'washroom',        'Sanitary fittings disinfected; consumables refilled; floor mopped dry.'),
  ('sme', 'gym_floor',       'Equipment touch points disinfected; floor free of debris and sweat marks.'),
  ('sme', 'changing_room',   'Benches, lockers and showers disinfected; drains clear; no standing water.'),
  ('sme', 'reception',       'Entrance glass streak-free; mats vacuumed; seating wiped.'),
  ('healthcare', 'clinical', 'Colour-coded equipment used per national guidance; high-touch surfaces disinfected.'),
  ('healthcare', 'clinical', 'Clinical waste untouched; general waste removed and bins relined.'),
  ('hospitality', 'guest_room', 'Linen changed, room reset to checklist, bathroom to hotel standard.'),
  ('hospitality', 'public_area', 'Lobby and corridors vacuumed; glass and brass polished.');

insert into public.towns (name, lat, lng) values
  ('Clacton-on-Sea', 51.788900, 1.148700),
  ('Colchester',     51.895900, 0.891900),
  ('Harwich',        51.942000, 1.288000),
  ('Ipswich',        52.056700, 1.148200),
  ('Manningtree',    51.944000, 1.057000),
  ('Sudbury',        52.040000, 0.733300);

-- Shared library template (vendor_org_id null). Minutes drive deterministic pricing.
insert into public.schedule_templates (vendor_org_id, name, segment, sections) values
  (null, 'Gym: floor, studios and changing rooms', 'sme', '[
    {"name": "Gym floor", "areas": [
      {"id": "gym-cardio",   "name": "Cardio zone",          "area_type": "gym_floor",     "minutes": 30},
      {"id": "gym-weights",  "name": "Free weights and rigs", "area_type": "gym_floor",     "minutes": 35},
      {"id": "gym-studio",   "name": "Studio",               "area_type": "gym_floor",     "minutes": 20}
    ]},
    {"name": "Changing and washrooms", "areas": [
      {"id": "gym-change-m", "name": "Changing room A",      "area_type": "changing_room", "minutes": 30},
      {"id": "gym-change-f", "name": "Changing room B",      "area_type": "changing_room", "minutes": 30},
      {"id": "gym-wc",       "name": "Accessible washroom",  "area_type": "washroom",      "minutes": 10}
    ]},
    {"name": "Front of house", "areas": [
      {"id": "gym-reception","name": "Reception and entrance","area_type": "reception",    "minutes": 15}
    ]}
  ]'::jsonb),
  (null, 'Home: standard clean (3-bed)', 'homeowner', '[
    {"name": "Downstairs", "areas": [
      {"id": "home-kitchen", "name": "Kitchen",     "area_type": "kitchen",  "minutes": 40},
      {"id": "home-living",  "name": "Living room", "area_type": "living",   "minutes": 25}
    ]},
    {"name": "Upstairs", "areas": [
      {"id": "home-bath",    "name": "Bathroom",    "area_type": "bathroom", "minutes": 30},
      {"id": "home-bed1",    "name": "Bedroom 1",   "area_type": "bedroom",  "minutes": 15},
      {"id": "home-bed2",    "name": "Bedroom 2",   "area_type": "bedroom",  "minutes": 15},
      {"id": "home-bed3",    "name": "Bedroom 3",   "area_type": "bedroom",  "minutes": 15}
    ]}
  ]'::jsonb);

-- The platform organisation that Duly Admin staff belong to.
insert into public.organisations (kind, name, market) values ('platform', 'Duly', 'UK');

-- Clean-Fit: the first real vendor. Tier 0 and no rate or scores until it is verified
-- and has completed jobs, so it will not appear in search until then.
with o as (
  insert into public.organisations (kind, name, market, segment, verification_tier)
  values ('vendor', 'Clean-Fit', 'UK', 'sme', 0) returning id
)
insert into public.vendor_profiles (org_id, description, base_lat, base_lng, service_radius_km)
select id, 'Commercial and gym cleaning across north-east Essex.', 51.895900, 0.891900, 30 from o;

-- Sample vendors for testing only. Names end in "(sample)"; scores are illustrative.
with v (name, tier, lat, lng, radius, rate, quality, met, on_time, disputes, repeat_rate, jobs) as (
  values
    ('Harbour Shine (sample)',   2, 51.942000, 1.288000, 25, 19.50, 92.0, 94.0, 96.0, 1.0, 61.0, 140),
    ('Colne Clean Co (sample)',  1, 51.895900, 0.891900, 20, 17.00, 86.5, 88.0, 91.0, 3.0, 48.0,  72),
    ('Stour Valley Care (sample)', 3, 52.040000, 0.733300, 35, 22.00, 95.5, 97.0, 98.0, 0.5, 70.0, 210),
    ('Tendring Fresh (sample)',  1, 51.788900, 1.148700, 18, 16.00, 79.0, 81.0, 85.0, 5.0, 33.0,  38)
),
o as (
  insert into public.organisations (kind, name, market, segment, verification_tier)
  select 'vendor', name, 'UK', 'sme', tier from v
  returning id, name
),
p as (
  insert into public.vendor_profiles (org_id, description, base_lat, base_lng, service_radius_km, hourly_rate)
  select o.id, 'Sample vendor for testing search and ranking.', v.lat, v.lng, v.radius, v.rate
  from o join v using (name)
  returning org_id
)
insert into public.vendor_scores (org_id, quality_score, standards_met_rate, on_time_rate, dispute_rate, repeat_client_rate, jobs_completed)
select o.id, v.quality, v.met, v.on_time, v.disputes, v.repeat_rate, v.jobs
from o join v using (name);
