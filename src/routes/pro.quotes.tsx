import { Link, createFileRoute } from '@tanstack/react-router'
import { useState } from 'react'
import { Empty } from '#/components/Shells'
import { Badge, ErrorNote, Loading } from '#/components/ui'
import { day, money, must, useLoad } from '#/lib/format'
import { hoursLabel, parseSchedule, totalMinutes } from '#/lib/schedule'
import { supabase } from '#/lib/supabase'
import { useVendor } from '#/lib/vendor'

export const Route = createFileRoute('/pro/quotes')({ component: ProQuotes })

function ProQuotes() {
  const vendor = useVendor()!
  const { data, error, reload } = useLoad(async () => {
    const db = supabase()
    const quotes = must(
      await db
        .from('quotes')
        .select('id, status, total, currency, valid_until, created_at, brief_id, brief_version, urgency')
        .eq('vendor_org_id', vendor.id)
        .order('created_at', { ascending: false }),
    )
    const briefIds = Array.from(new Set(quotes.map((q) => q.brief_id)))
    const [briefs, versions] = await Promise.all([
      briefIds.length
        ? db.from('briefs').select('id, title, site:sites(name, town, postcode)').in('id', briefIds)
        : Promise.resolve({ data: [], error: null }),
      briefIds.length
        ? db.from('brief_versions').select('brief_id, version, schedule').in('brief_id', briefIds)
        : Promise.resolve({ data: [], error: null }),
    ])
    const schedules = quotes.length ? must(await db.from('work_schedules').select('quote_id, status').in('quote_id', quotes.map((q) => q.id))) : []
    return { quotes, briefs: must(briefs), versions: must(versions), schedules }
  }, [vendor.id])
  const [busy, setBusy] = useState<string | null>(null)
  const [actionError, setActionError] = useState<string | null>(null)

  async function act(id: string, fn: 'submit_quote' | 'decline_quote') {
    setBusy(id)
    setActionError(null)
    const { error: err } = fn === 'submit_quote' ? await supabase().rpc('submit_quote', { p_quote: id }) : await supabase().rpc('decline_quote', { p_quote: id })
    setBusy(null)
    if (err) setActionError(err.message)
    reload()
  }

  if (error) return <ErrorNote message={error} />
  if (!data) return <Loading />

  return (
    <div className="space-y-6">
      <h1 className="text-3xl">Quote requests</h1>
      <p className="text-sm text-ink-2">
        Duly prices each brief from its areas and minutes at your hourly rate, so every client sees the same basis. Submit to send
        the price, or decline if you can't take it on.
      </p>
      <ErrorNote message={actionError} />
      {data.quotes.length === 0 ? (
        <Empty title="No quote requests yet">When a client asks you to quote, it appears here.</Empty>
      ) : (
        <div className="space-y-3">
          {data.quotes.map((q) => {
            const b = data.briefs.find((x) => x.id === q.brief_id)
            const v = data.versions.find((x) => x.brief_id === q.brief_id && x.version === q.brief_version)
            const sched = parseSchedule(v?.schedule)
            return (
              <div key={q.id} className="card space-y-3 p-4">
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div>
                    <p className="font-semibold">{b?.title}</p>
                    <p className="text-sm text-ink-2">
                      {b?.site?.name}, {b?.site?.town} {b?.site?.postcode} · v{q.brief_version} · asked {day(q.created_at)}
                    </p>
                  </div>
                  <Badge value={q.status} />
                </div>
                <p className="text-sm text-ink-2">
                  {sched.reduce((n, s) => n + s.areas.length, 0)} areas · {hoursLabel(totalMinutes(sched))} per visit
                  {q.total != null && ` · ${money(q.total, q.currency)} · valid until ${day(q.valid_until)}`}
                </p>
                <details className="text-sm">
                  <summary className="flex min-h-[44px] cursor-pointer items-center font-medium text-primary">See the brief</summary>
                  {sched.map((s) => (
                    <div key={s.name} className="mt-2">
                      <p className="font-medium">{s.name}</p>
                      <ul className="list-disc pl-5 text-ink-2">
                        {s.areas.map((a) => (
                          <li key={a.id}>
                            {a.name} · {a.minutes} min · {a.standards.length} standards
                          </li>
                        ))}
                      </ul>
                    </div>
                  ))}
                </details>
                <WorkScheduleLink quoteId={q.id} status={data.schedules.find((x) => x.quote_id === q.id)?.status} quoteStatus={q.status} />
                {(q.status === 'invited' || q.status === 'submitted') && (
                  <div className="flex flex-wrap gap-2">
                    <button className="btn btn-primary" disabled={busy === q.id} onClick={() => void act(q.id, 'submit_quote')}>
                      {q.status === 'invited' ? 'Submit quote' : 'Re-price and resubmit'}
                    </button>
                    <button className="btn btn-ghost" disabled={busy === q.id} onClick={() => void act(q.id, 'decline_quote')}>
                      {q.status === 'invited' ? 'Decline' : 'Withdraw'}
                    </button>
                  </div>
                )}
              </div>
            )
          })}
        </div>
      )}
    </div>
  )
}

function WorkScheduleLink({ quoteId, status, quoteStatus }: { quoteId: string; status: string | undefined; quoteStatus: string }) {
  if (!status && quoteStatus !== 'invited' && quoteStatus !== 'submitted') return null
  const text = status === 'locked' ? 'Work schedule (locked)' : status === 'submitted' ? 'Work schedule (sent)' : status === 'draft' ? 'Work schedule (draft)' : 'Build a work schedule'
  return (
    <div>
      <Link to="/pro/schedules/$quoteId" params={{ quoteId }} className="link-action text-sm font-semibold text-primary">
        {text}
      </Link>
    </div>
  )
}
