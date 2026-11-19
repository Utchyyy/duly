// Month handling and the CSV export for the Enterprise's monthly SLA pack. The database works out every number
// (`enterprise_sla_pack`, `enterprise_sla_exceptions`); this only picks the month and writes the rows out as a spreadsheet file.
// Names of vendors and sites are typed by people, so every cell is made safe against spreadsheet formulas.

export type PackRow = {
  vendor_org_id: string
  vendor_name: string
  site_name: string | null
  is_vendor_total: boolean
  scheduled_visits: number
  due_visits: number
  checked_in_visits: number
  evidenced_visits: number
  evidenced_rate: number | null
  on_time_visits: number
  on_time_rate: number | null
  late_visits: number
  missed_visits: number
  avg_late_minutes: number | null
  plan_followed_rate: number | null
  first_time_right_rate: number | null
  complaints: number
  complaints_per_100: number | null
  open_complaints: number
  sla_breaches: number
  on_time_target: number | null
  evidenced_target: number | null
  max_complaints_per_100: number | null
  on_time_met: boolean | null
  evidenced_met: boolean | null
  complaints_met: boolean | null
}

export type ExceptionRow = {
  vendor_name: string
  site_name: string
  scheduled_start: string
  status: string
  missed: boolean
  late_minutes: number | null
  complaints: number
  open_complaints: number
  sla_breached: boolean
  complaint_kinds: string | null
}

/** The first day of the month containing `iso` (yyyy-mm-dd). */
export function monthStart(iso: string): string {
  return `${iso.slice(0, 7)}-01`
}

/** Move a month (any date in it) forward or back, as the first of that month. */
export function shiftMonth(iso: string, by: number): string {
  const y = Number(iso.slice(0, 4))
  const m = Number(iso.slice(5, 7)) - 1 + by
  const d = new Date(Date.UTC(y, m, 1))
  return d.toISOString().slice(0, 10)
}

export function monthLabel(iso: string): string {
  return new Date(`${monthStart(iso)}T00:00:00Z`).toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' })
}

/** Today's month as the first of the month, from the local clock. */
export function thisMonth(today = new Date()): string {
  return `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-01`
}

/** One cell, quoted when it needs it. A cell that would be read as a formula is made plain text first. */
export function csvCell(v: string | number | boolean | null | undefined): string {
  if (v === null || v === undefined) return ''
  let s = typeof v === 'boolean' ? (v ? 'Yes' : 'No') : String(v)
  if (typeof v === 'string' && /^[=+\-@\t\r]/.test(s)) s = `'${s}`
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s
}

const line = (cells: (string | number | boolean | null | undefined)[]) => cells.map(csvCell).join(',')
const percent = (r: number | null) => (r == null ? null : Math.round(r * 1000) / 10)
const met = (m: boolean | null) => (m == null ? '' : m ? 'Met' : 'Not met')

/** What a set of figures rests on, for the file: the day a month was frozen, or the moment live figures were read. */
export function csvBasis(frozenAt: string | null, now = new Date()): string {
  return frozenAt ? `Frozen ${frozenAt.slice(0, 10)}` : `Live ${now.toISOString().slice(0, 16).replace('T', ' ')} UTC`
}

/** The pack as a spreadsheet: one line per vendor and per vendor and site. */
export function packCsv(month: string, enterprise: string, rows: PackRow[], basis: string): string {
  const head = [
    'Month', 'Basis', 'Enterprise', 'Vendor', 'Site', 'Level', 'Visits scheduled', 'Visits due', 'Checked in', 'Evidenced', 'Evidenced %', 'On time', 'On time %',
    'Late', 'Missed', 'Average minutes after the start', 'Planned areas ticked %', 'Right first time %', 'Complaints', 'Complaints per 100 visits',
    'Open complaints', 'Past response time', 'On-time level %', 'On-time result', 'Evidenced level %', 'Evidenced result', 'Most complaints per 100', 'Complaints result',
  ]
  const body = rows.map((r) =>
    line([
      monthLabel(month), basis, enterprise, r.vendor_name, r.is_vendor_total ? 'All sites' : r.site_name, r.is_vendor_total ? 'Vendor' : 'Site',
      r.scheduled_visits, r.due_visits, r.checked_in_visits, r.evidenced_visits, percent(r.evidenced_rate), r.on_time_visits, percent(r.on_time_rate),
      r.late_visits, r.missed_visits, r.avg_late_minutes, percent(r.plan_followed_rate), percent(r.first_time_right_rate), r.complaints, r.complaints_per_100,
      r.open_complaints, r.sla_breaches, percent(r.on_time_target), met(r.on_time_met), percent(r.evidenced_target), met(r.evidenced_met), r.max_complaints_per_100, met(r.complaints_met),
    ]),
  )
  return '﻿' + [line(head), ...body].join('\r\n') + '\r\n'
}

/** The visits behind the numbers as a spreadsheet. */
export function exceptionsCsv(month: string, enterprise: string, rows: ExceptionRow[], basis: string): string {
  const head = ['Month', 'Basis', 'Enterprise', 'Vendor', 'Site', 'Visit starts', 'Status', 'Missed', 'Minutes after the start', 'Complaints', 'Open complaints', 'Past response time', 'Kinds of complaint']
  const body = rows.map((r) =>
    line([monthLabel(month), basis, enterprise, r.vendor_name, r.site_name, r.scheduled_start, r.status, r.missed, r.late_minutes, r.complaints, r.open_complaints, r.sla_breached, r.complaint_kinds]),
  )
  return '﻿' + [line(head), ...body].join('\r\n') + '\r\n'
}

/** A file name for the download. */
export function packFileName(kind: 'pack' | 'visits', enterprise: string, month: string, frozen: boolean): string {
  const slug = enterprise.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'enterprise'
  return `duly-sla-${kind}-${slug}-${month.slice(0, 7)}${frozen ? '-frozen' : '-live'}.csv`
}
