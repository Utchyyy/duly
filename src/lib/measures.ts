// Wording for the operational measures the database works out for each visit and for each vendor.
// The database does the arithmetic (see `visit_measures`, `vendor_operations`); this only turns numbers into plain words.

/** 0.667 -> "67%". Nothing to measure shows as a dash. */
export function pct(rate: number | null | undefined): string {
  return rate == null ? '–' : `${Math.round(rate * 100)}%`
}

export function minutesText(min: number | null | undefined): string {
  if (min == null) return '–'
  if (min < 60) return `${Math.round(min)} min`
  const h = Math.floor(min / 60)
  const m = Math.round(min % 60)
  return m > 0 ? `${h} h ${m} min` : `${h} h`
}

/** Time on site against the time planned: well under the plan can mean work was skipped, well over can mean trouble. */
export function timeAgainstPlan(ratio: number | null | undefined): { label: string; tone: 'ok' | 'watch' | 'none' } {
  if (ratio == null) return { label: 'Not enough visits to compare', tone: 'none' }
  if (ratio < 0.6) return { label: `${Math.round(ratio * 100)}% of the planned time: quicker than planned, check the work was all done`, tone: 'watch' }
  if (ratio > 1.3) return { label: `${Math.round(ratio * 100)}% of the planned time: much longer than planned`, tone: 'watch' }
  return { label: `${Math.round(ratio * 100)}% of the planned time: in line with the plan`, tone: 'ok' }
}

export type VisitLike = {
  late_minutes: number
  on_time: boolean
  planned_minutes: number
  on_site_minutes: number | null
  planned_areas: number
  ticked_areas: number
  complaints: number
  first_time_right: boolean
}

/** One-line reading of a visit for lists: what went wrong, or that nothing did. */
export function visitNotes(v: VisitLike): string[] {
  const notes: string[] = []
  notes.push(v.on_time ? 'On time' : `${v.late_minutes} min late`)
  if (v.planned_areas > 0 && v.ticked_areas < v.planned_areas) notes.push(`${v.ticked_areas} of ${v.planned_areas} areas ticked`)
  if (v.complaints > 0) notes.push(`${v.complaints} complaint${v.complaints === 1 ? '' : 's'}`)
  else if (v.first_time_right) notes.push('Right first time')
  return notes
}

export type RangeKey = '30' | '90'

/** Date range (inclusive, as yyyy-mm-dd) ending today. */
export function rangeDates(days: number, today = new Date()): { from: string; to: string } {
  const iso = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
  const start = new Date(today)
  start.setDate(start.getDate() - days)
  const end = new Date(today)
  end.setDate(end.getDate() + 1) // a visit later today still counts
  return { from: iso(start), to: iso(end) }
}
