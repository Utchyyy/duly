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

## Tests

`pnpm test:db` applies every migration to a throwaway Postgres and runs `supabase/tests/*.test.sql`: the booking-to-payment workflow, escrow and disputes, recurring visits, who can see or change what (RLS, anon, protected fields), WFX shifts and DBS, evidence storage, and per-segment money rules (invoice terms, hospitality, policy-driven releases and fee). It needs `psql` and a Postgres superuser via the usual `PGHOST`/`PGPORT`/`PGUSER`/`PGPASSWORD`, and it drops and recreates a database called `duly_test`. CI runs the same script, plus lint, typecheck and build.
