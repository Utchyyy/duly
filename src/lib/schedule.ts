import type { Json } from './database.types'

export type Standard = { id: string; text: string }
export type Area = { id: string; name: string; area_type?: string; minutes: number; standards: Standard[] }
export type Section = { name: string; areas: Area[] }
export type Schedule = Section[]

export function parseSchedule(json: Json | null | undefined): Schedule {
  if (!Array.isArray(json)) return []
  return json.map((s) => {
    const sec = (s ?? {}) as Record<string, unknown>
    const areas = Array.isArray(sec.areas) ? (sec.areas as Record<string, unknown>[]) : []
    return {
      name: String(sec.name ?? 'Section'),
      areas: areas.map((a) => ({
        id: String(a.id ?? newId()),
        name: String(a.name ?? 'Area'),
        area_type: typeof a.area_type === 'string' ? a.area_type : undefined,
        minutes: Number(a.minutes ?? 0),
        standards: Array.isArray(a.standards)
          ? (a.standards as Record<string, unknown>[]).map((st) => ({ id: String(st.id), text: String(st.text) }))
          : [],
      })),
    }
  })
}

export function totalMinutes(schedule: Schedule): number {
  return schedule.reduce((sum, s) => sum + s.areas.reduce((m, a) => m + (Number.isFinite(a.minutes) ? a.minutes : 0), 0), 0)
}

export function newId(): string {
  return Math.random().toString(36).slice(2, 10)
}

export type LibraryStandard = { id: string; segment: string; area_type: string; text: string }

/** Copy a template into a brief, attaching standards from the library for the buyer's segment. */
export function fromTemplate(templateSections: Json, library: LibraryStandard[], segment: string): Schedule {
  const base = parseSchedule(templateSections)
  const pick = (areaType?: string) => {
    if (!areaType) return []
    const own = library.filter((l) => l.area_type === areaType && l.segment === segment)
    const any = own.length ? own : library.filter((l) => l.area_type === areaType)
    return any.map((l) => ({ id: l.id, text: l.text }))
  }
  return base.map((s) => ({
    ...s,
    areas: s.areas.map((a) => ({ ...a, id: `${a.id}-${newId()}`, standards: a.standards.length ? a.standards : pick(a.area_type) })),
  }))
}

export function hoursLabel(minutes: number): string {
  const h = Math.floor(minutes / 60)
  const m = Math.round(minutes % 60)
  return h ? `${h}h${m ? ` ${m}m` : ''}` : `${m}m`
}
