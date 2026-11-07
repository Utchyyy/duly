/**
 * The shape of an AI-drafted brief, the schema the model is asked to fill, and the sanitiser that turns
 * whatever it returned into something safe to show a person. Nothing here prices, ranks or books anything:
 * a draft only describes the site, the visits and the areas, minutes and standards, for a person to review.
 *
 * The limits mirror private.validate_brief_draft in the database, which is the final authority.
 */

export const AREA_TYPES = [
  'bathroom', 'bedroom', 'changing room', 'clinical', 'gym floor', 'guest room',
  'kitchen', 'living', 'office', 'public area', 'reception', 'washroom',
] as const
export const DAYS = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'] as const

export type Day = (typeof DAYS)[number]
export type MinutesSource = 'stated' | 'estimated'

export type DraftArea = {
  name: string
  area_type: string | null
  minutes: number
  minutes_source: MinutesSource
  standards: string[]
}
export type DraftSection = { name: string; areas: DraftArea[] }
export type BriefDraft = {
  title: string
  site: { name: string; address: string; postcode: string; town: string; access_notes: string }
  visits: { days: Day[]; start_time: string }
  sections: DraftSection[]
  /** Things the model had to guess. Shown to the person reviewing. */
  assumptions: string[]
  /** Things the person should confirm. */
  questions: string[]
}

export const LIMITS = {
  inputText: 20_000,
  title: 120,
  sections: 12,
  sectionName: 80,
  areasPerSection: 30,
  areas: 60,
  areaName: 80,
  minMinutes: 1,
  maxMinutes: 600,
  defaultMinutes: 15,
  standards: 12,
  standardText: 200,
  notes: 8,
  noteText: 300,
  siteName: 120,
  address: 200,
  postcode: 12,
  town: 80,
  accessNotes: 500,
} as const

/** Sent to the model as the structured-output schema. Every property is required; unknowns are empty. */
export const BRIEF_DRAFT_JSON_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['title', 'site', 'visits', 'sections', 'assumptions', 'questions'],
  properties: {
    title: { type: 'string' },
    site: {
      type: 'object',
      additionalProperties: false,
      required: ['name', 'address', 'postcode', 'town', 'access_notes'],
      properties: {
        name: { type: 'string' },
        address: { type: 'string' },
        postcode: { type: 'string' },
        town: { type: 'string' },
        access_notes: { type: 'string' },
      },
    },
    visits: {
      type: 'object',
      additionalProperties: false,
      required: ['days', 'start_time'],
      properties: {
        days: { type: 'array', items: { type: 'string', enum: [...DAYS] } },
        start_time: { type: 'string' },
      },
    },
    sections: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['name', 'areas'],
        properties: {
          name: { type: 'string' },
          areas: {
            type: 'array',
            items: {
              type: 'object',
              additionalProperties: false,
              required: ['name', 'area_type', 'minutes', 'minutes_source', 'standards'],
              properties: {
                name: { type: 'string' },
                area_type: { type: 'string', enum: [...AREA_TYPES, 'other'] },
                minutes: { type: 'integer' },
                minutes_source: { type: 'string', enum: ['stated', 'estimated'] },
                standards: { type: 'array', items: { type: 'string' } },
              },
            },
          },
        },
      },
    },
    assumptions: { type: 'array', items: { type: 'string' } },
    questions: { type: 'array', items: { type: 'string' } },
  },
} as const

export class DraftError extends Error {
  readonly code: 'invalid_input' | 'forbidden' | 'model_refused' | 'model_failed' | 'unusable' | 'unavailable'
  constructor(code: DraftError['code'], message: string) {
    super(message)
    this.name = 'DraftError'
    this.code = code
  }
}

// eslint-disable-next-line no-control-regex
const CONTROL = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g

/** Plain single-line text: no control characters, collapsed spaces, trimmed and length-limited. */
export function clean(value: unknown, max: number): string {
  if (typeof value !== 'string') return ''
  return value.replace(CONTROL, ' ').replace(/\s+/g, ' ').trim().slice(0, max).trim()
}

function record(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, unknown>) : {}
}

function textList(value: unknown, count: number, max: number): string[] {
  if (!Array.isArray(value)) return []
  const seen = new Set<string>()
  const out: string[] = []
  for (const item of value) {
    const text = clean(item, max)
    const key = text.toLowerCase()
    if (!text || seen.has(key)) continue
    seen.add(key)
    out.push(text)
    if (out.length >= count) break
  }
  return out
}

/**
 * Turn model output into a draft that is safe to show and to approve. Unknown fields are dropped (so
 * a "price" the model volunteered goes nowhere), text is cleaned and limited, numbers are clamped.
 * Throws DraftError('unusable') if no cleaning area is left.
 */
export function sanitiseDraft(raw: unknown): BriefDraft {
  const input = record(raw)
  const sectionsIn = Array.isArray(input.sections) ? input.sections : []
  const assumptions = textList(input.assumptions, LIMITS.notes, LIMITS.noteText)
  const questions = textList(input.questions, LIMITS.notes, LIMITS.noteText)

  let total = 0
  const sections: DraftSection[] = []
  for (const s of sectionsIn.slice(0, LIMITS.sections)) {
    const sec = record(s)
    const areas: DraftArea[] = []
    const areasIn = Array.isArray(sec.areas) ? sec.areas : []
    for (const a of areasIn.slice(0, LIMITS.areasPerSection)) {
      if (total >= LIMITS.areas) break
      const area = record(a)
      const name = clean(area.name, LIMITS.areaName)
      if (!name) continue
      const stated = area.minutes_source === 'stated'
      const minutes = Math.round(Number(area.minutes))
      const usable = Number.isFinite(minutes) && minutes >= LIMITS.minMinutes
      const type = clean(area.area_type, 40).toLowerCase()
      areas.push({
        name,
        area_type: (AREA_TYPES as readonly string[]).includes(type) ? type : null,
        minutes: usable ? Math.min(minutes, LIMITS.maxMinutes) : LIMITS.defaultMinutes,
        minutes_source: stated && usable ? 'stated' : 'estimated',
        standards: textList(area.standards, LIMITS.standards, LIMITS.standardText),
      })
      total += 1
    }
    if (areas.length) sections.push({ name: clean(sec.name, LIMITS.sectionName) || 'Cleaning', areas })
  }
  if (!sections.length) {
    throw new DraftError('unusable', 'We could not find any cleaning areas in that. Add more detail, or start a brief by hand.')
  }

  const site = record(input.site)
  const visits = record(input.visits)
  const days = DAYS.filter((d) => Array.isArray(visits.days) && visits.days.includes(d))
  const time = clean(visits.start_time, 5)

  return {
    title: clean(input.title, LIMITS.title) || clean(sections[0]?.name, LIMITS.title) || 'Cleaning brief',
    site: {
      name: clean(site.name, LIMITS.siteName),
      address: clean(site.address, LIMITS.address),
      postcode: clean(site.postcode, LIMITS.postcode).toUpperCase(),
      town: clean(site.town, LIMITS.town),
      access_notes: clean(site.access_notes, LIMITS.accessNotes),
    },
    visits: { days, start_time: /^([01]\d|2[0-3]):[0-5]\d$/.test(time) ? time : '' },
    sections,
    assumptions,
    questions,
  }
}

/** Minutes and areas across a draft, for the review screen. */
export function draftTotals(draft: BriefDraft): { areas: number; minutes: number; estimated: number } {
  let areas = 0
  let minutes = 0
  let estimated = 0
  for (const s of draft.sections)
    for (const a of s.areas) {
      areas += 1
      minutes += a.minutes
      if (a.minutes_source === 'estimated') estimated += 1
    }
  return { areas, minutes, estimated }
}
