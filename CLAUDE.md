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
- The only callable RPCs are in `public`: `create_buyer_org`, `rank_vendors`, `price_quote`, `rank_candidates`, `demand_by_town`, `corridor_suggestions`. Each checks access itself.

## Auth
Email one-time code (Supabase OTP). Buyers and operatives can sign up; vendor staff and admins are invite-only (`shouldCreateUser: false`). Roles come from `memberships`.

## Design tokens (src/styles.css)
Fraunces 600 for display, Instrument Sans 400–600 for body. Ground #F6F3EC, ink #1B1F1A, secondary #4A5048, primary #1F5C45, tint #E3EEE7, alert #8A3B10 on #FBEBDD, lines #E2DDD2, Pro sidebar #1B2A23. 44px minimum touch targets. Mobile designs at 390px, consoles at 1440px.
