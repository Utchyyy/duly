import { useState } from 'react'
import { DAYS, DAY_LABEL, METHODS, METHOD_LABEL, dayMinutes, minutesLabel, newId, weekMinutes } from '#/lib/workplan'
import type { Day, Legend, Method, Plan, Row, Section, SubSection } from '#/lib/workplan'

const cell = 'px-2 py-2 text-center text-sm'

function MethodChip({ method }: { method: Method | undefined }) {
  if (!method) return <span className="text-ink-2/50">–</span>
  const tone = method === 'scrub' ? 'bg-primary text-white' : method === 'wash' ? 'bg-tint text-primary' : method === 'mop' ? 'bg-line text-ink' : 'bg-ground text-ink ring-1 ring-line'
  return <span className={`inline-block rounded-full px-2 py-0.5 text-xs font-semibold ${tone}`}>{METHOD_LABEL[method]}</span>
}

function Totals({ plan, legend }: { plan: Plan; legend: Legend }) {
  return (
    <tr className="border-t border-line bg-ground/60 font-medium">
      <td className="p-3 text-sm">Time planned</td>
      {DAYS.map((d) => (
        <td key={d} className={cell}>
          {dayMinutes(plan, legend, d) > 0 ? minutesLabel(dayMinutes(plan, legend, d)) : '–'}
        </td>
      ))}
    </tr>
  )
}

/** The method times the vendor set, shown wherever a schedule is shown. */
export function LegendNote({ legend }: { legend: Legend }) {
  return (
    <p className="text-sm text-ink-2">
      {METHODS.map((m) => `${METHOD_LABEL[m]} ${legend[m].minutes ? `${legend[m].minutes} min` : 'not set'}`).join(' · ')} per cleaning area.
    </p>
  )
}

/**
 * Read-only schedule for the client, crew and Duly. With `onReport`, each cleaning area gets a button so a complaint can
 * name the exact area. `highlight` marks one weekday (the day of the visit being looked at).
 */
export function WorkPlanView({
  plan,
  legend,
  highlight,
  onReport,
}: {
  plan: Plan
  legend: Legend
  highlight?: Day
  onReport?: (row: Row, path: string) => void
}) {
  if (plan.sections.length === 0) return <p className="text-sm text-ink-2">This schedule has no cleaning areas.</p>
  return (
    <div className="space-y-4">
      <LegendNote legend={legend} />
      {plan.sections.map((section) => (
        <div key={section.id} className="card overflow-x-auto">
          <table className="w-full min-w-[640px] text-left text-sm">
            <thead>
              <tr className="border-b border-line bg-tint/60">
                <th className="p-3 font-semibold">{section.name}</th>
                {DAYS.map((d) => (
                  <th key={d} className={`${cell} font-medium ${highlight === d ? 'bg-primary text-white' : ''}`}>
                    {DAY_LABEL[d]}
                  </th>
                ))}
                {onReport && <th className="p-3" />}
              </tr>
            </thead>
            <tbody>
              {section.subsections.map((sub) => (
                <SubRows key={sub.id} section={section} sub={sub} highlight={highlight} onReport={onReport} />
              ))}
            </tbody>
            <tfoot>
              <Totals plan={{ sections: [section] }} legend={legend} />
            </tfoot>
          </table>
        </div>
      ))}
      <p className="text-sm font-medium">Whole schedule: {minutesLabel(weekMinutes(plan, legend))} a week.</p>
    </div>
  )
}

function SubRows({ section, sub, highlight, onReport }: { section: Section; sub: SubSection; highlight?: Day; onReport?: (row: Row, path: string) => void }) {
  return (
    <>
      <tr className="bg-ground/70">
        <td colSpan={DAYS.length + 1 + (onReport ? 1 : 0)} className="px-3 py-2 text-xs font-semibold uppercase tracking-wide text-ink-2">
          {sub.name}
        </td>
      </tr>
      {sub.areas.filter((row) => !row.standard).map((row) => (
        <tr key={row.id} className="border-b border-line last:border-0">
          <td className="p-3">{row.name}</td>
          {DAYS.map((d) => (
            <td key={d} className={`${cell} ${highlight === d ? 'bg-tint/50' : ''}`}>
              <MethodChip method={row.days[d]} />
            </td>
          ))}
          {onReport && (
            <td className="p-1 text-right">
              <button className="btn btn-ghost text-xs" onClick={() => onReport(row, [section.name, sub.name, row.name].join(' > '))}>
                Report a problem
              </button>
            </td>
          )}
        </tr>
      ))}
      {sub.areas.some((row) => row.standard) && (
        <tr className="border-b border-line last:border-0">
          <td colSpan={DAYS.length + 1 + (onReport ? 1 : 0)} className="px-3 py-2 text-xs text-ink-2">
            Client standards also checked here: {sub.areas.filter((row) => row.standard).map((row) => row.name).join(' · ')}
          </td>
        </tr>
      )}
    </>
  )
}

/** The vendor's builder. The parent owns the plan and legend so it can save, send and keep them as a template. */
export function WorkPlanEditor({
  plan,
  legend,
  briefAreas,
  onPlan,
  onLegend,
}: {
  plan: Plan
  legend: Legend
  briefAreas: { id: string; name: string }[]
  onPlan: (p: Plan) => void
  onLegend: (l: Legend) => void
}) {
  const [newArea, setNewArea] = useState<Record<string, string>>({})
  const edit = (fn: (draft: Plan) => void) => {
    const draft = structuredClone(plan)
    fn(draft)
    onPlan(draft)
  }

  return (
    <div className="space-y-6">
      <div className="card space-y-3 p-4">
        <h2 className="text-lg">Minutes for each method</h2>
        <p className="text-sm text-ink-2">How long one cleaning area takes with each method. The time planned for each day adds these up.</p>
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          {METHODS.map((m) => (
            <label key={m} className="text-sm">
              <span className="mb-1 block font-medium">{METHOD_LABEL[m]}</span>
              <input
                type="number"
                min={0}
                max={600}
                className="field"
                value={legend[m].minutes ?? ''}
                placeholder="min"
                onChange={(e) => onLegend({ ...legend, [m]: { minutes: e.target.value === '' ? null : Math.max(0, Math.round(Number(e.target.value))) } })}
              />
            </label>
          ))}
        </div>
      </div>

      {plan.sections.map((section, si) => (
        <div key={section.id} className="card overflow-x-auto">
          <div className="flex flex-wrap items-center gap-2 border-b border-line bg-tint/60 p-3">
            <input
              className="field min-w-[12rem] flex-1 font-semibold"
              aria-label="Section name"
              value={section.name}
              onChange={(e) => edit((d) => void (d.sections[si].name = e.target.value))}
            />
            <button className="btn btn-ghost text-sm" onClick={() => edit((d) => void d.sections.splice(si, 1))}>
              Remove section
            </button>
          </div>
          <table className="w-full min-w-[1000px] text-left text-sm">
            <thead>
              <tr className="border-b border-line">
                <th className="p-3 font-medium">Cleaning area</th>
                {DAYS.map((d) => (
                  <th key={d} className={`${cell} font-medium`}>
                    {DAY_LABEL[d]}
                  </th>
                ))}
                <th className="p-3" />
              </tr>
            </thead>
            <tbody>
              {section.subsections.map((sub, ssi) => (
                <EditorSub
                  key={sub.id}
                  sub={sub}
                  briefAreas={briefAreas}
                  newName={newArea[sub.id] ?? ''}
                  setNewName={(v) => setNewArea((p) => ({ ...p, [sub.id]: v }))}
                  onChange={(fn) => edit((d) => fn(d.sections[si].subsections[ssi]))}
                  onRemove={() => edit((d) => void d.sections[si].subsections.splice(ssi, 1))}
                />
              ))}
            </tbody>
          </table>
          <div className="p-3">
            <button
              className="btn btn-ghost text-sm"
              onClick={() => edit((d) => void d.sections[si].subsections.push({ id: `${section.id}-${newId()}`, name: 'New sub-section', brief_area_id: null, areas: [] }))}
            >
              Add a sub-section
            </button>
          </div>
        </div>
      ))}

      <button className="btn btn-ghost" onClick={() => edit((d) => void d.sections.push({ id: `s${newId()}`, name: 'New section', subsections: [] }))}>
        Add a section
      </button>

      <div className="card overflow-x-auto">
        <table className="w-full min-w-[640px] text-left text-sm">
          <tbody>
            <Totals plan={plan} legend={legend} />
          </tbody>
        </table>
        <p className="p-3 text-sm font-medium">Whole schedule: {minutesLabel(weekMinutes(plan, legend))} a week.</p>
      </div>
    </div>
  )
}

function EditorSub({
  sub,
  briefAreas,
  newName,
  setNewName,
  onChange,
  onRemove,
}: {
  sub: SubSection
  briefAreas: { id: string; name: string }[]
  newName: string
  setNewName: (v: string) => void
  onChange: (fn: (sub: SubSection) => void) => void
  onRemove: () => void
}) {
  return (
    <>
      <tr className="bg-ground/70">
        <td colSpan={DAYS.length + 2} className="p-2">
          <div className="flex flex-wrap items-center gap-2">
            <input className="field min-w-[12rem] flex-1 text-sm font-semibold" aria-label="Sub-section name" value={sub.name} onChange={(e) => onChange((s) => void (s.name = e.target.value))} />
            {briefAreas.length > 0 && (
              <select
                className="field w-auto text-sm"
                aria-label={`Brief area for ${sub.name}`}
                value={sub.brief_area_id ?? ''}
                onChange={(e) => onChange((s) => void (s.brief_area_id = e.target.value || null))}
              >
                <option value="">Brief area (its standards are checked too)…</option>
                {briefAreas.map((a) => (
                  <option key={a.id} value={a.id}>
                    {a.name}
                  </option>
                ))}
              </select>
            )}
            <button className="btn btn-ghost text-sm" onClick={onRemove}>
              Remove sub-section
            </button>
          </div>
        </td>
      </tr>
      {sub.areas.map((row, ri) => (
        <tr key={row.id} className="border-b border-line">
          <td className="min-w-[280px] p-1">
            <input className="field text-sm" aria-label="Cleaning area name" value={row.name} onChange={(e) => onChange((s) => void (s.areas[ri].name = e.target.value))} />
          </td>
          {DAYS.map((d) => (
            <td key={d} className="p-1">
              <select
                className="field px-1 text-sm"
                aria-label={`${row.name || 'Cleaning area'} on ${DAY_LABEL[d]}`}
                value={row.days[d] ?? ''}
                onChange={(e) =>
                  onChange((s) => {
                    if (e.target.value) s.areas[ri].days[d] = e.target.value as Method
                    else delete s.areas[ri].days[d]
                  })
                }
              >
                <option value="">–</option>
                {METHODS.map((m) => (
                  <option key={m} value={m}>
                    {METHOD_LABEL[m]}
                  </option>
                ))}
              </select>
            </td>
          ))}
          <td className="p-1 text-right">
            <button className="btn btn-ghost text-xs" aria-label={`Remove ${row.name || 'cleaning area'}`} onClick={() => onChange((s) => void s.areas.splice(ri, 1))}>
              Remove
            </button>
          </td>
        </tr>
      ))}
      <tr className="border-b border-line">
        <td colSpan={DAYS.length + 2} className="p-2">
          <div className="flex flex-wrap gap-2">
            <input className="field min-w-[12rem] flex-1 text-sm" placeholder="New cleaning area" aria-label={`New cleaning area in ${sub.name}`} value={newName} onChange={(e) => setNewName(e.target.value)} />
            <button
              className="btn btn-ghost text-sm"
              disabled={!newName.trim()}
              onClick={() => {
                onChange((s) => void s.areas.push({ id: `${s.id}-${newId()}`, name: newName.trim(), days: {} }))
                setNewName('')
              }}
            >
              Add area
            </button>
          </div>
        </td>
      </tr>
    </>
  )
}
