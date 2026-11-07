# Duly build rules

## Product
Duly is a verified cleaning marketplace. Surfaces: buyer app `/`, Duly for Business `/business`, Duly Pro vendor console `/pro`, Duly Crew operative PWA `/crew`, Duly Admin `/admin`. WFX is the labour and infrastructure layer underneath (workers, shifts, DBS, matching).

## Non-negotiables
- Ranking, matching, pricing and scoring are deterministic SQL functions (`rank_vendors`, `rank_candidates`, `price_quote`, `commute_band`). The frontend never re-sorts their output; AI never ranks or prices.
- AI output goes only to `approval_queue` as a draft for a human to approve.
- RLS on every table. No anon access. Signed-out visitors see marketing only.
- No hard-coded currency, tax, payment terms or check types: read `markets`, `segments`, `policies`.
- Payment release follows `policies`: first release (default 55%) on approval, or at month end for monthly plans; balance 48h after no complaint; platform fee deducted from the balance.
- Staff pay (`shifts.hourly_pay`) is visible only in Duly Pro and Admin.
- Every schema change is a migration in `supabase/migrations`. Never edit an applied migration; add a new one.
- Don't rewrite published git history. Never commit `.env`, exports or CSVs with personal data.

## Schema layout
- App tables live in `public` (exposed through the API, guarded by RLS).
- Access helpers (`is_member`, `has_org_role`, `can_see_job`, …) are SECURITY DEFINER functions in the `private` schema, which the API does not expose. Policies call them.
- The only callable RPCs are in `public`, and each checks access itself:
  - Matching and pricing: `rank_vendors`, `price_quote`, `rank_candidates`, `demand_by_town`, `corridor_suggestions`
  - Workflow: `create_buyer_org`, `submit_quote`, `decline_quote`, `accept_quote`, `schedule_visits`, `check_in`, `complete_job`, `approve_job`, `mark_payment_paid`
  - WFX shifts: `offer_shift`, `respond_to_shift` (WIIx score computed by trigger from the four ratings)
  - People: `add_member`, `org_member_emails`, `mark_notifications_read`
  - Email worker (service role only, never callable by people): `worker_claim_notification_emails`, `worker_finish_notification_email`
  - AI drafts: `approve_brief_draft`, `reject_brief_draft` (the model's output sits in `approval_queue` until a person approves it)
- Triggers guard what direct writes can't be trusted with: job status/value (`protect_job_fields`), verdicts (`protect_area_result_fields`), verification tier (`protect_org_fields`), evidence geofence, issue SLA and dispute holds.

## Workflow
Brief (draft → locked version) → client invites ranked vendors → vendor submits (price computed by `price_quote`) → client accepts with a start time (creates contract, job, escrow line for escrow segments) → vendor assigns crew → crew checks in (geofence checked in SQL), ticks standards, uploads after-photos to `evidence/<job_id>/<area_id>/…` → `complete_job` → client marks each standard met/not met → `approve_job` schedules releases from `policies`, or a reported issue holds the job as `disputed` → Duly records bank transfers with `mark_payment_paid` (Stripe to replace) → `recompute_vendor_score` from real jobs only. Client charges: escrow segments get an `escrow_hold` line per clean; monthly plans get a `direct_debit` line per month (due at the start of the month) and invoice-terms clients an `invoice` line (due month end + payment terms), both kept in step with booked visits by `refresh_client_charges`.

AI drafting (optional): a buyer pastes text or uploads a document → a server function (`src/lib/drafting`, as the signed-in person) asks the model for a draft → a pending row in `approval_queue` → an owner or approver reviews it → `approve_brief_draft` creates the site and an unlocked draft brief (areas the drafter left without standards get up to 3 `standards_library` entries for the organisation's segment and the area type) → the person edits, locks and asks for quotes as usual. The schema has no price or vendor field, and limits (10 pending, 25 a day per organisation) are enforced by trigger. `ANTHROPIC_API_KEY` is server-only.

Notifications: created only in SQL (triggers on quotes, jobs, assignments, issues, shifts, DBS and verification, plus the scheduled `private.notify_due_items()`), into `notifications` (the in-app inbox, which doubles as the email outbox). They never carry staff pay, amounts, street addresses, access notes or safeguarding detail, they never block the action they report, and people can only read them and mark them read. Email is sent by `POST /api/notifications/send` (needs `CRON_SECRET`), which uses the service role; those secrets are server-only.

Crew offline: `public/crew-sw.js` (scope `/crew`) caches only the app's static files and the Crew page shell, never data, and never anything cross-origin or non-GET. Check-in, ticking and completing need a connection because the database records their time and place as "now". Photos taken without one are kept in IndexedDB (`src/lib/crew/outbox.ts`) with their original time and place and sent when the signal returns; `evidence.storage_path` is unique so a resend cannot duplicate. A failed load is never shown as "no jobs" or "no access" (`loadFailed` in `useAuth`).

## Auth
Email one-time code (Supabase OTP). Buyers and operatives can sign up; vendor staff and admins are invite-only (`shouldCreateUser: false`). Roles come from `memberships`.

## Design tokens (src/styles.css)
Fraunces 600 for display, Instrument Sans 400–600 for body. Ground #F6F3EC, ink #1B1F1A, secondary #4A5048, primary #1F5C45, tint #E3EEE7, alert #8A3B10 on #FBEBDD, lines #E2DDD2, Pro sidebar #1B2A23. 44px minimum touch targets. Mobile designs at 390px, consoles at 1440px.
