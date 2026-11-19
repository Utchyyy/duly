// Wording, ranges and counts for the Enterprise delivery view. The database decides what needs attention, in what order, and every
// rate (`enterprise_delivery_board`, `enterprise_vendor_delivery`, `enterprise_open_issues`); this only turns rows into plain words.
// It never ranks or re-sorts them.
import { minutesText } from './measures.ts'

export type DeliveryAttention = 'missed' | 'late' | 'no_crew' | 'overrunning' | 'held' | 'awaiting_check'

export const ATTENTION_ORDER: DeliveryAttention[] = ['missed', 'late', 'no_crew', 'overrunning', 'held', 'awaiting_check']

export const ATTENTION_LABEL: Record<DeliveryAttention, string> = {
  missed: 'Missed',
  late: 'Late',
  no_crew: 'No cleaner',
  overrunning: 'Overrunning',
  held: 'Held by a complaint',
  awaiting_check: 'Waiting for your check',
}

export type DeliveryRow = { attention: string | null; late_minutes: number | null; on_site_minutes: number | null; planned_minutes: number; vendor_name: string; site_name: string }

/** What is wrong with a visit, in a sentence. */
export function deliveryText(r: DeliveryRow): string {
  switch (r.attention) {
    case 'missed':
      return `Nobody came: ${r.vendor_name} has not checked in and the visit should be over`
    case 'late':
      return `${minutesText(r.late_minutes)} late: ${r.vendor_name} has not checked in`
    case 'no_crew':
      return `${r.vendor_name} has not assigned anyone yet`
    case 'overrunning':
      return `Past its planned end: ${minutesText(r.on_site_minutes)} on site against ${minutesText(r.planned_minutes)} planned`
    case 'held':
      return 'A complaint is holding this visit'
    case 'awaiting_check':
      return 'The cleaner has finished: check the work'
    default:
      return ''
  }
}

/** Counts of each kind of attention, for the summary tiles. */
export function deliveryCounts(rows: { attention: string | null }[]): Record<DeliveryAttention, number> & { total: number; problems: number } {
  const out = { missed: 0, late: 0, no_crew: 0, overrunning: 0, held: 0, awaiting_check: 0, total: 0, problems: 0 }
  for (const r of rows) {
    if (r.attention && r.attention in out) {
      out[r.attention as DeliveryAttention] += 1
      out.total += 1
      // "Problems" are what the vendor owes; waiting for the Enterprise's own check is not one.
      if (r.attention !== 'awaiting_check') out.problems += 1
    }
  }
  return out
}

export type DeliveryRange = 'today' | 'last7' | 'last30' | 'next7'

export const DELIVERY_RANGES: { key: DeliveryRange; text: string }[] = [
  { key: 'today', text: 'Today' },
  { key: 'last7', text: 'Last 7 days' },
  { key: 'last30', text: 'Last 30 days' },
  { key: 'next7', text: 'Next 7 days' },
]

/** The range as yyyy-mm-dd dates. */
export function deliveryDates(range: DeliveryRange, today = new Date()): { from: string; to: string } {
  const iso = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
  const shift = (n: number) => {
    const d = new Date(today)
    d.setDate(d.getDate() + n)
    return d
  }
  switch (range) {
    case 'today':
      return { from: iso(today), to: iso(today) }
    case 'last7':
      return { from: iso(shift(-6)), to: iso(today) }
    case 'last30':
      return { from: iso(shift(-29)), to: iso(today) }
    case 'next7':
      return { from: iso(today), to: iso(shift(7)) }
  }
}

/** How long a problem has been open, in words. */
export function openFor(hours: number): string {
  if (hours < 1) return 'just now'
  if (hours < 48) return `${hours} h`
  return `${Math.floor(hours / 24)} days`
}
