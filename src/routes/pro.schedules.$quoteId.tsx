import { Link, createFileRoute } from '@tanstack/react-router'
import { useEffect, useState } from 'react'
import { WorkPlanEditor, WorkPlanView } from '#/components/WorkPlan'
import { Badge, ErrorNote, Loading, Section } from '#/components/ui'
import { label, must, useLoad } from '#/lib/format'
import { parseSchedule } from '#/lib/schedule'
import { supabase } from '#/lib/supabase'
import { useVendor } from '#/lib/vendor'
import { emptyLegend, minutesLabel, parseLegend, parsePlan, problemsBeforeSending, weekMinutes } from '#/lib/workplan'
import type { Legend, Plan } from '#/lib/workplan'

export const Route = createFileRoute('/pro/schedules/$quoteId')({ component: ProSchedule })

function pickSchedule<T>(res: { data: T | null; error: { message: string } | null }): T | null {
  if (res.error) throw new Error(res.error.message)
  return res.data
}

function ProSchedule() {
  const { quoteId } = Route.useParams()
  const vendor = useVendor()!
  const { data, error, reload } = useLoad(async () => {
    const db = supabase()
    const quote = must(await db.from('quotes').select('id, status, brief_id, brief_version').eq('id', quoteId).eq('vendor_org_id', vendor.id).single())
    const [brief, version, schedule, templates] = await Promise.all([
      db.from('briefs').select('id, title, site:sites(name, town, postcode)').eq('id', quote.brief_id).single(),
      db.from('brief_versions').select('schedule').eq('brief_id', quote.brief_id).eq('version', quote.brief_version).single(),
      db.from('work_schedules').select('id, status, plan, legend, submitted_at, locked_at').eq('quote_id', quoteId).maybeSingle(),
      db.from('work_plan_templates').select('id, name, description, vendor_org_id, plan, legend').order('name'),
    ])
    return { quote, brief: must(brief), briefAreas: parseSchedule(must(version).schedule).flatMap((s) => s.areas.map((a) => ({ id: a.id, name: `${s.name}: ${a.name}` }))), schedule: pickSchedule(schedule), templates: must(templates) }
  }, [quoteId, vendor.id])

  const [plan, setPlan] = useState<Plan | null>(null)
  const [legend, setLegend] = useState<Legend>(emptyLegend())
  const [templateId, setTemplateId] = useState('')
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState<string | null>(null)
  const [problem, setProblem] = useState<string | null>(null)
  const [templateName, setTemplateName] = useState('')

  useEffect(() => {
    if (data?.schedule) {
      setPlan(parsePlan(data.schedule.plan))
      setLegend(parseLegend(data.schedule.legend))
    }
  }, [data?.schedule?.id])

  if (error) return <ErrorNote message={error} />
  if (!data) return <Loading />
  const { quote, brief, schedule, templates } = data
  const open = quote.status === 'invited' || quote.status === 'submitted'
  const status = schedule?.status ?? 'none'

  function start() {
    const t = templates.find((x) => x.id === templateId)
    setPlan(t ? parsePlan(t.plan) : { sections: [{ id: `s${Math.random().toString(36).slice(2, 8)}`, name: 'New section', subsections: [] }] })
    setLegend(t ? parseLegend(t.legend) : emptyLegend())
    setMessage(null)
    setProblem(null)
  }

  async function save(next: 'draft' | 'submitted' | 'keep') {
    if (!plan) return
    setProblem(null)
    setMessage(null)
    if (next === 'submitted') {
      const missing = problemsBeforeSending(plan, legend)
      if (missing.length > 0) return setProblem(missing.join(' '))
    }
    setBusy(true)
    const db = supabase()
    const statusToSet = next === 'keep' ? (schedule?.status === 'submitted' ? 'submitted' : 'draft') : next
    const body = { plan: plan as unknown as never, legend: legend as unknown as never }
    const res = schedule
      ? await db.from('work_schedules').update({ ...body, status: statusToSet }).eq('id', schedule.id)
      : await db.from('work_schedules').insert({ quote_id: quoteId, ...body })
    if (!res.error && !schedule && statusToSet === 'submitted') {
      const again = await db.from('work_schedules').update({ status: 'submitted' }).eq('quote_id', quoteId)
      if (again.error) {
        setBusy(false)
        return setProblem(again.error.message)
      }
    }
    setBusy(false)
    if (res.error) return setProblem(res.error.message)
    setMessage(statusToSet === 'submitted' ? 'Sent. The client can see it with your quote.' : 'Saved.')
    reload()
  }

  async function saveTemplate() {
    if (!plan || !templateName.trim()) return
    setBusy(true)
    const { error: err } = await supabase()
      .from('work_plan_templates')
      .insert({ vendor_org_id: vendor.id, name: templateName.trim(), plan: plan as unknown as never, legend: legend as unknown as never })
    setBusy(false)
    if (err) return setProblem(err.message)
    setTemplateName('')
    setMessage('Saved as one of your templates.')
    reload()
  }

  return (
    <div className="space-y-6">
      <Link to="/pro/quotes" className="link-action text-sm font-medium text-primary">
        ← Quote requests
      </Link>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-3xl">Work schedule</h1>
          <p className="text-sm text-ink-2">
            {brief.title} · {brief.site?.name}, {brief.site?.town} {brief.site?.postcode}
          </p>
        </div>
        <Badge value={status === 'none' ? 'invited' : status}>{status === 'none' ? 'Not started' : label(status)}</Badge>
      </div>
      <p className="text-sm text-ink-2">
        How you will clean, area by area and day by day. The client sees it with your quote. When they accept, it locks, your crew work from it and the client checks the
        work against it. It does not change the price.
      </p>

      {!open && schedule ? (
        <Section title="Locked">
          <p className="text-sm text-ink-2">The quote was accepted, so this schedule is fixed.</p>
          <WorkPlanView plan={parsePlan(schedule.plan)} legend={parseLegend(schedule.legend)} />
        </Section>
      ) : !open ? (
        <p className="text-ink-2">This quote is no longer open, so a schedule cannot be added.</p>
      ) : !plan ? (
        <div className="card space-y-3 p-4">
          <h2 className="text-lg">Start from</h2>
          <select className="field max-w-md" aria-label="Template" value={templateId} onChange={(e) => setTemplateId(e.target.value)}>
            <option value="">A blank schedule</option>
            {templates.map((t) => (
              <option key={t.id} value={t.id}>
                {t.name}
                {t.vendor_org_id ? ' (yours)' : ''}
              </option>
            ))}
          </select>
          {templateId && <p className="text-sm text-ink-2">{templates.find((t) => t.id === templateId)?.description}</p>}
          <button className="btn btn-primary" onClick={start}>
            Start
          </button>
        </div>
      ) : (
        <>
          <WorkPlanEditor plan={plan} legend={legend} briefAreas={data.briefAreas} onPlan={setPlan} onLegend={setLegend} />
          <ErrorNote message={problem} />
          {message && <p className="rounded-lg bg-tint p-3 text-sm text-primary">{message}</p>}
          <p className="text-sm text-ink-2">Whole schedule: {minutesLabel(weekMinutes(plan, legend))} a week.</p>
          <div className="flex flex-wrap gap-2">
            <button className="btn btn-ghost" disabled={busy} onClick={() => void save('keep')}>
              {schedule?.status === 'submitted' ? 'Save changes' : 'Save draft'}
            </button>
            <button className="btn btn-primary" disabled={busy} onClick={() => void save('submitted')}>
              {schedule?.status === 'submitted' ? 'Save and re-send' : 'Send to the client'}
            </button>
            {schedule?.status === 'submitted' && (
              <button className="btn btn-ghost" disabled={busy} onClick={() => void save('draft')}>
                Take back to draft
              </button>
            )}
          </div>
          <div className="card flex flex-wrap items-end gap-2 p-4">
            <label className="min-w-[14rem] flex-1 text-sm">
              <span className="mb-1 block font-medium">Keep as your own template</span>
              <input className="field" placeholder="Template name" value={templateName} onChange={(e) => setTemplateName(e.target.value)} />
            </label>
            <button className="btn btn-ghost" disabled={busy || !templateName.trim()} onClick={() => void saveTemplate()}>
              Save template
            </button>
          </div>
        </>
      )}
    </div>
  )
}
