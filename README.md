# Duly

Verified cleaning marketplace: buyer app (`/`), Duly for Business (`/business`), Duly Pro (`/pro`), Duly Crew (`/crew`, installable) and Duly Admin (`/admin`).

Stack: TanStack Start + React 19 + Tailwind 4 on Vercel (functions in Dublin, `dub1`); Supabase (Postgres 17, eu-west-1) for auth, data and storage.

## Run locally

```bash
pnpm install
cp .env.example .env   # public URL and publishable key only
pnpm dev               # http://localhost:3000
```

## Database

Every schema change is a migration in `supabase/migrations`, applied to the Supabase project `mnlyltdxnvzbttugkmng`. Regenerate types after a change into `src/lib/database.types.ts`.

See `CLAUDE.md` for the build rules.

## AI brief drafting

Buyers can paste a description, or upload a specification, tender or photo, and an AI assistant drafts the areas, minutes and standards. The rules:

- The draft goes only into `approval_queue`, as a pending row. Nothing becomes a site or brief until an owner or approver reviews it and approves it (`approve_brief_draft`), and approval creates an ordinary *unlocked* draft brief. The person still locks it and asks for quotes.
- The model never ranks, prices or recommends vendors, and its schema has no price field. Ranking and pricing stay in SQL (`rank_vendors`, `price_quote`).
- The model is called from a server function (`src/lib/drafting/`), as the signed-in person, so row-level security applies. `ANTHROPIC_API_KEY` is server-only; see `.env.example`. A draft can take up to a minute, so check the function duration allowed in your Vercel project.
- Before relying on it, run `ANTHROPIC_API_KEY=… pnpm draft:smoke` once. It makes one real model call (a few cents) with made-up text containing a price, a door code and a planted instruction, and checks none of them reach the draft.
- Drafts are limited to 10 waiting and 25 a day per organisation, enforced in the database.

## Notifications

People are told when something needs them: a quote asked for or arrived, a clean to check, a cleaner assigned, a problem raised, a shift offered, a payment due, a clean about to start or running late.

- **In the app:** the bell and `/notifications`, instant. Created in SQL, by triggers on the real events and by `private.notify_due_items()` for things that happen because time passed (reminders, lateness, deadlines, payments due). That scan runs every five minutes through `pg_cron` where the extension exists.
- **By email:** each notification is also queued for email unless the person has switched that off (Account, Notifications). A protected endpoint, `POST /api/notifications/send`, sends the queue through Resend. It needs `CRON_SECRET`, so only a scheduler can call it: `.github/workflows/notifications.yml` does that every five minutes once the `APP_URL` and `CRON_SECRET` repository secrets are set. See `.env.example` for the server settings. Swapping provider means replacing `src/lib/notifications/resend.server.ts`.
- **What is never said:** staff pay, amounts, street addresses, access notes, or anything about a safeguarding report. Email goes through a third party, so text says what happened and links into the app. The SQL tests check this.
- **A notification can never block the action it reports:** the trigger functions catch their own errors.

## Tests

`pnpm test:unit` runs the TypeScript unit tests (the drafting pipeline, with a fake model and a fake database). `pnpm test:db` applies every migration to a throwaway Postgres and runs `supabase/tests/*.test.sql`: the booking-to-payment workflow, escrow and disputes, recurring visits, who can see or change what (RLS, anon, protected fields), WFX shifts and DBS, evidence storage, and per-segment money rules (invoice terms, hospitality, policy-driven releases and fee). It needs `psql` and a Postgres superuser via the usual `PGHOST`/`PGPORT`/`PGUSER`/`PGPASSWORD`, and it drops and recreates a database called `duly_test`. CI runs both, plus lint, typecheck and build.
