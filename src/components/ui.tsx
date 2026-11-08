import type { ReactNode } from 'react'
import { label } from '#/lib/format'

const good = new Set(['locked', 'submitted', 'accepted', 'active', 'quality_verified', 'paid', 'verified', 'succeeded', 'resolved', 'met'])
const warn = new Set(['disputed', 'declined', 'rejected', 'failed', 'expired', 'withdrawn', 'cancelled', 'not_met', 'open', 'mediation'])

export function Badge({ value, children }: { value: string; children?: ReactNode }) {
  const tone = good.has(value) ? 'bg-tint text-primary' : warn.has(value) ? 'bg-alert-bg text-alert' : 'bg-line/60 text-ink-2'
  return (
    <span className={`inline-flex shrink-0 items-center rounded-full px-2.5 py-1 text-xs font-semibold ${tone}`}>
      {children ?? label(value)}
    </span>
  )
}

export function ErrorNote({ message }: { message: string | null | undefined }) {
  if (!message) return null
  return <p className="rounded-lg bg-alert-bg p-3 text-sm text-alert">{message}</p>
}

export function Loading() {
  return <p className="py-6 text-ink-2">Loading…</p>
}

export function Field({ label: text, htmlFor, children, hint }: { label: string; htmlFor: string; children: ReactNode; hint?: string }) {
  return (
    <div className="space-y-1.5">
      <label className="block text-sm font-medium" htmlFor={htmlFor}>
        {text}
      </label>
      {children}
      {hint && <p className="text-xs text-ink-2">{hint}</p>}
    </div>
  )
}

export function Section({ id, title, action, children }: { id?: string; title: string; action?: ReactNode; children: ReactNode }) {
  return (
    <section id={id} className="space-y-3">
      <div className="flex items-center justify-between gap-3">
        <h2 className="text-xl">{title}</h2>
        {action}
      </div>
      {children}
    </section>
  )
}

export function Table({ head, children }: { head: string[]; children: ReactNode }) {
  return (
    <div className="card overflow-x-auto">
      <table className="w-full text-left text-sm">
        <thead className="border-b border-line text-ink-2">
          <tr>
            {head.map((h) => (
              <th key={h} className="whitespace-nowrap p-3 font-medium">
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody className="[&>tr]:border-b [&>tr]:border-line [&>tr:last-child]:border-0 [&_td]:p-3">{children}</tbody>
      </table>
    </div>
  )
}
