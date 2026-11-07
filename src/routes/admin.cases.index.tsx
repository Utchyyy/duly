import { Link, createFileRoute } from '@tanstack/react-router'
import { useState } from 'react'
import { Badge, ErrorNote, Loading } from '#/components/ui'
import { must, useLoad, when } from '#/lib/format'
import { supabase } from '#/lib/supabase'

export const Route = createFileRoute('/admin/cases/')({ component: AdminCases })

function AdminCases() {
  const [search, setSearch] = useState('')
  const { data, error } = useLoad(async () => {
    const db = supabase()
    const [briefs, quotes, jobs, issues] = await Promise.all([
      db
        .from('briefs')
        .select(
          'id, title, status, created_at, buyer:organisations!briefs_buyer_org_id_fkey(name), site:sites(name, town, postcode)',
        )
        .order('created_at', { ascending: false })
        .limit(500),
      db.from('quotes').select('brief_id, status, vendor:organisations(name)'),
      db.from('jobs').select('id, brief_id, status'),
      db.from('issues').select('job_id, status').neq('status', 'resolved'),
    ])
    return {
      briefs: must(briefs),
      quotes: must(quotes),
      jobs: must(jobs),
      issues: must(issues),
    }
  }, [])

  if (error) return <ErrorNote message={error} />
  if (!data) return <Loading />

  const rows = data.briefs.map((b) => {
    const q = data.quotes.filter((x) => x.brief_id === b.id)
    const j = data.jobs.filter((x) => x.brief_id === b.id)
    const open = data.issues.filter((i) =>
      j.some((x) => x.id === i.job_id),
    ).length
    return {
      b,
      q,
      j,
      open,
      vendors: q.map((x) => x.vendor?.name ?? '').join(' '),
    }
  })
  const term = search.trim().toLowerCase()
  const shown = term
    ? rows.filter((r) =>
        [
          r.b.title,
          r.b.buyer?.name,
          r.b.site?.name,
          r.b.site?.town,
          r.b.site?.postcode,
          r.vendors,
        ]
          .join(' ')
          .toLowerCase()
          .includes(term),
      )
    : rows

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-3xl">Case files</h1>
        <p className="mt-1 text-sm text-ink-2">
          Every brief with who was invited, what was quoted and agreed, the job
          record, photos, verdicts, issues and payments, and an unalterable
          timeline of who did what and when. Open one to review it for
          arbitration.
        </p>
      </div>
      <div>
        <label htmlFor="case-search" className="text-sm font-medium">
          Find a case
        </label>
        <input
          id="case-search"
          className="field mt-1 w-full max-w-md"
          placeholder="Brief, client, site, postcode or vendor"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
        />
      </div>
      {shown.length === 0 && (
        <p className="text-ink-2">
          {rows.length === 0
            ? 'No briefs yet.'
            : 'Nothing matches that search.'}
        </p>
      )}
      <ul className="space-y-3">
        {shown.map(({ b, q, j, open }) => (
          <li key={b.id}>
            <Link
              to="/admin/cases/$briefId"
              params={{ briefId: b.id }}
              className="card flex min-h-[44px] flex-wrap items-start justify-between gap-3 p-4 hover:border-primary"
            >
              <div>
                <p className="font-semibold">{b.title}</p>
                <p className="text-sm text-ink-2">
                  {b.buyer?.name} · {b.site?.name}, {b.site?.town}{' '}
                  {b.site?.postcode} · created {when(b.created_at)}
                </p>
                <p className="mt-1 text-sm text-ink-2">
                  {q.length} vendor{q.length === 1 ? '' : 's'} invited
                  {q.length > 0 &&
                    ` (${q.map((x) => `${x.vendor?.name ?? 'Vendor'}: ${x.status}`).join(', ')})`}{' '}
                  · {j.length} job{j.length === 1 ? '' : 's'}
                </p>
              </div>
              <div className="flex items-center gap-2">
                {open > 0 && (
                  <span className="text-sm font-semibold text-alert">
                    {open} open issue{open === 1 ? '' : 's'}
                  </span>
                )}
                <Badge value={b.status} />
              </div>
            </Link>
          </li>
        ))}
      </ul>
    </div>
  )
}
