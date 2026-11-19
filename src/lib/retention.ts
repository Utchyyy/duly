// Wording for the data retention screen. The database decides what each rule would act on (`admin_retention_report`); this only turns the
// rows into plain words and says what turning a rule on will do.

export type RuleAction = 'delete' | 'clear' | 'report'

export const ACTION_TEXT: Record<string, string> = {
  delete: 'Deletes records',
  clear: 'Clears sensitive fields, keeps the record',
  report: 'Counts only: removes nothing',
}

/** "13 months" or "6 years" or "1 year 1 month". */
export function periodText(months: number): string {
  const y = Math.floor(months / 12)
  const m = months % 12
  const years = y > 0 ? `${y} year${y === 1 ? '' : 's'}` : ''
  const mons = m > 0 ? `${m} month${m === 1 ? '' : 's'}` : ''
  return [years, mons].filter(Boolean).join(' ') || '0 months'
}

/** What turning a rule on will do at the next daily scan, before the person confirms it. */
export function consequence(action: string, dueNow: number): string {
  if (action === 'report') return 'This rule only counts, so turning it on removes nothing.'
  if (dueNow === 0) return 'Nothing is due right now. The daily scan will apply it to anything that reaches this age.'
  const what = action === 'delete' ? `permanently delete ${dueNow} record${dueNow === 1 ? '' : 's'}` : `permanently clear the sensitive fields on ${dueNow} record${dueNow === 1 ? '' : 's'}`
  return `At the next daily scan (03:45 UTC) this will ${what}. It cannot be undone.`
}

/** Whether a period typed in a box is one the database will accept. */
export function validMonths(text: string, key: string): { ok: true; months: number } | { ok: false; reason: string } {
  const n = Number(text)
  if (!Number.isInteger(n) || n < 1 || n > 240) return { ok: false, reason: 'Enter a whole number of months from 1 to 240.' }
  if (key === 'audit_log' && n < 72) return { ok: false, reason: 'The audit log is kept for at least six years (72 months).' }
  return { ok: true, months: n }
}
