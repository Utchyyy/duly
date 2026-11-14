// Wording and grouping for the vendor dispatch board. The database decides what needs attention and in what order
// (`dispatch_board`); this only turns its rows into plain words and groups them by day. It never ranks or re-sorts them.
import { minutesText } from './measures.ts'

export type Attention = 'late' | 'no_crew' | 'crew_clash' | 'overrunning' | 'held'

export type BoardLike = {
  attention: string | null
  late_minutes: number | null
  on_site_minutes: number | null
  planned_minutes: number
}

/** What is wrong with a visit, in a sentence. */
export function attentionText(r: BoardLike): string {
  switch (r.attention) {
    case 'late':
      return `${minutesText(r.late_minutes)} late: nobody has checked in`
    case 'no_crew':
      return 'Nobody is assigned yet'
    case 'crew_clash':
      return 'A cleaner is on another visit at the same time'
    case 'overrunning':
      return `Past its planned end: ${minutesText(r.on_site_minutes)} on site against ${minutesText(r.planned_minutes)} planned`
    case 'held':
      return 'A complaint is holding this visit'
    default:
      return ''
  }
}

/** Counts of each kind of attention, for the summary tiles. */
export function attentionCounts(rows: { attention: string | null }[]): Record<Attention, number> & { total: number } {
  const out = { late: 0, no_crew: 0, crew_clash: 0, overrunning: 0, held: 0, total: 0 }
  for (const r of rows) {
    if (r.attention && r.attention in out) {
      out[r.attention as Attention] += 1
      out.total += 1
    }
  }
  return out
}

/** Keeps the order the database gave, starting a new group each time the day changes. */
export function groupByDay<T extends { scheduled_start: string }>(rows: T[], dayOf: (iso: string) => string): { day: string; rows: T[] }[] {
  const out: { day: string; rows: T[] }[] = []
  for (const r of rows) {
    const d = dayOf(r.scheduled_start)
    const last = out[out.length - 1]
    if (last && last.day === d) last.rows.push(r)
    else out.push({ day: d, rows: [r] })
  }
  return out
}

export type BoardRange = 'today' | '7' | '14'

/** From today to the end of the range (inclusive, as yyyy-mm-dd). */
export function boardDates(range: BoardRange, today = new Date()): { from: string; to: string } {
  const iso = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
  const end = new Date(today)
  end.setDate(end.getDate() + (range === 'today' ? 0 : Number(range)))
  return { from: iso(today), to: iso(end) }
}

export function crewNames(crew: unknown): { user_id: string; name: string; role: string }[] {
  return Array.isArray(crew) ? (crew as { user_id: string; name: string; role: string }[]) : []
}
