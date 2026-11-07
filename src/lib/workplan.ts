// Work schedules: a vendor's plan for a brief. Section > Sub-section > Cleaning area, each set per weekday to a
// method (scrub, wash, clean or mop), with the vendor's minutes for each method. The schedule is for the work, not
// the price (price_quote is unchanged). The database checks the same rules before it accepts one.

export const METHODS = ['scrub', 'wash', 'clean', 'mop'] as const
export type Method = (typeof METHODS)[number]
export const DAYS = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'] as const
export type Day = (typeof DAYS)[number]

export const METHOD_LABEL: Record<Method, string> = { scrub: 'Scrub', wash: 'Wash', clean: 'Clean', mop: 'Mop' }
export const DAY_LABEL: Record<Day, string> = { mon: 'Mon', tue: 'Tue', wed: 'Wed', thu: 'Thu', fri: 'Fri', sat: 'Sat', sun: 'Sun' }
export const DAY_FULL: Record<Day, string> = { mon: 'Monday', tue: 'Tuesday', wed: 'Wednesday', thu: 'Thursday', fri: 'Friday', sat: 'Saturday', sun: 'Sunday' }

export type Row = { id: string; name: string; days: Partial<Record<Day, Method>> }
export type SubSection = { id: string; name: string; brief_area_id: string | null; areas: Row[] }
export type Section = { id: string; name: string; subsections: SubSection[] }
export type Plan = { sections: Section[] }
export type Legend = Record<Method, { minutes: number | null }>

const isMethod = (v: unknown): v is Method => typeof v === 'string' && (METHODS as readonly string[]).includes(v)
const isDay = (v: unknown): v is Day => typeof v === 'string' && (DAYS as readonly string[]).includes(v)
const obj = (v: unknown): Record<string, unknown> => (v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : {})
const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : [])

export function newId(): string {
  return Math.random().toString(36).slice(2, 10)
}

export function emptyLegend(): Legend {
  return { scrub: { minutes: null }, wash: { minutes: null }, clean: { minutes: null }, mop: { minutes: null } }
}

export function parseLegend(json: unknown): Legend {
  const out = emptyLegend()
  const src = obj(json)
  for (const m of METHODS) {
    const raw = obj(src[m]).minutes
    const n = typeof raw === 'number' ? raw : typeof raw === 'string' && raw.trim() !== '' ? Number(raw) : NaN
    out[m] = { minutes: Number.isFinite(n) && n >= 0 ? Math.round(n) : null }
  }
  return out
}

export function parsePlan(json: unknown): Plan {
  return {
    sections: arr(obj(json).sections).map((s) => {
      const sec = obj(s)
      return {
        id: String(sec.id ?? newId()),
        name: String(sec.name ?? 'Section'),
        subsections: arr(sec.subsections).map((ss) => {
          const sub = obj(ss)
          return {
            id: String(sub.id ?? newId()),
            name: String(sub.name ?? 'Sub-section'),
            brief_area_id: typeof sub.brief_area_id === 'string' ? sub.brief_area_id : null,
            areas: arr(sub.areas).map((a) => {
              const area = obj(a)
              const days: Partial<Record<Day, Method>> = {}
              for (const [k, v] of Object.entries(obj(area.days))) if (isDay(k) && isMethod(v)) days[k] = v
              return { id: String(area.id ?? newId()), name: String(area.name ?? 'Cleaning area'), days }
            }),
          }
        }),
      }
    }),
  }
}

export function allRows(plan: Plan): { section: Section; sub: SubSection; row: Row }[] {
  return plan.sections.flatMap((section) => section.subsections.flatMap((sub) => sub.areas.map((row) => ({ section, sub, row }))))
}

/** "Section > Sub-section > Area" for a cleaning area id, or null if it is not in the plan. */
export function rowPath(plan: Plan, rowId: string): string | null {
  const hit = allRows(plan).find((r) => r.row.id === rowId)
  return hit ? [hit.section.name, hit.sub.name, hit.row.name].join(' > ') : null
}

/** Minutes of work planned on one weekday: the vendor's minutes for the method set on each cleaning area. */
export function dayMinutes(plan: Plan, legend: Legend, day: Day): number {
  return allRows(plan).reduce((sum, { row }) => {
    const m = row.days[day]
    return sum + (m ? (legend[m].minutes ?? 0) : 0)
  }, 0)
}

export function weekMinutes(plan: Plan, legend: Legend): number {
  return DAYS.reduce((sum, d) => sum + dayMinutes(plan, legend, d), 0)
}

export function methodsUsed(plan: Plan): Method[] {
  const used = new Set<Method>()
  for (const { row } of allRows(plan)) for (const m of Object.values(row.days)) if (m) used.add(m)
  return METHODS.filter((m) => used.has(m))
}

/** What is still missing before a schedule can be sent to the client. Empty means ready. */
export function problemsBeforeSending(plan: Plan, legend: Legend): string[] {
  const out: string[] = []
  const rows = allRows(plan)
  if (rows.length === 0) out.push('Add at least one cleaning area.')
  if (rows.length > 0 && methodsUsed(plan).length === 0) out.push('Set a method on at least one day.')
  for (const m of methodsUsed(plan)) if (!legend[m].minutes || legend[m].minutes <= 0) out.push(`Set the minutes for ${METHOD_LABEL[m].toLowerCase()}.`)
  if (plan.sections.some((s) => s.name.trim() === '')) out.push('Every section needs a name.')
  if (plan.sections.some((s) => s.subsections.some((ss) => ss.name.trim() === ''))) out.push('Every sub-section needs a name.')
  if (rows.some(({ row }) => row.name.trim() === '')) out.push('Every cleaning area needs a name.')
  return out
}

/** The cleaning areas planned on a weekday, grouped as they appear in the schedule. */
export function workForDay(plan: Plan, day: Day): { section: string; sub: SubSection; rows: { row: Row; method: Method }[] }[] {
  const out: { section: string; sub: SubSection; rows: { row: Row; method: Method }[] }[] = []
  for (const section of plan.sections) {
    for (const sub of section.subsections) {
      const rows = sub.areas.flatMap((row) => (row.days[day] ? [{ row, method: row.days[day] as Method }] : []))
      if (rows.length > 0) out.push({ section: section.name, sub, rows })
    }
  }
  return out
}

export function dayOf(date: Date): Day {
  return (['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'] as const)[date.getDay()]
}

export function minutesLabel(min: number): string {
  if (min <= 0) return '0 min'
  const h = Math.floor(min / 60)
  const m = min % 60
  return h > 0 ? (m > 0 ? `${h} h ${m} min` : `${h} h`) : `${m} min`
}
