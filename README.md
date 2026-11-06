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
