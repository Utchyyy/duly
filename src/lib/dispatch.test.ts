import assert from 'node:assert/strict'
import { test } from 'node:test'
import { attentionCounts, attentionText, boardDates, crewNames, groupByDay } from './dispatch.ts'

const row = { attention: null, late_minutes: null, on_site_minutes: null, planned_minutes: 60 }

test('each kind of attention reads as a sentence', () => {
  assert.equal(attentionText({ ...row, attention: 'late', late_minutes: 35 }), '35 min late: nobody has checked in')
  assert.equal(attentionText({ ...row, attention: 'late', late_minutes: 125 }), '2 h 5 min late: nobody has checked in')
  assert.equal(attentionText({ ...row, attention: 'no_crew' }), 'Nobody is assigned yet')
  assert.equal(attentionText({ ...row, attention: 'crew_clash' }), 'A cleaner is on another visit at the same time')
  assert.equal(attentionText({ ...row, attention: 'overrunning', on_site_minutes: 95 }), 'Past its planned end: 1 h 35 min on site against 1 h planned')
  assert.equal(attentionText({ ...row, attention: 'held' }), 'A complaint is holding this visit')
  assert.equal(attentionText(row), '')
})

test('the summary counts each kind and the total', () => {
  const counts = attentionCounts([{ attention: 'late' }, { attention: 'late' }, { attention: 'no_crew' }, { attention: null }, { attention: 'held' }])
  assert.deepEqual(counts, { late: 2, no_crew: 1, crew_clash: 0, overrunning: 0, held: 1, total: 4 })
  assert.equal(attentionCounts([]).total, 0)
})

test('rows keep the order they came in, grouped when the day changes', () => {
  const rows = [
    { id: 'a', scheduled_start: '2026-11-16T09:00:00Z' },
    { id: 'b', scheduled_start: '2026-11-16T14:00:00Z' },
    { id: 'c', scheduled_start: '2026-11-17T08:00:00Z' },
    { id: 'd', scheduled_start: '2026-11-16T20:00:00Z' },
  ]
  const groups = groupByDay(rows, (iso) => iso.slice(0, 10))
  assert.deepEqual(groups.map((g) => [g.day, g.rows.map((r) => r.id)]), [
    ['2026-11-16', ['a', 'b']],
    ['2026-11-17', ['c']],
    ['2026-11-16', ['d']],
  ])
})

test('the board range runs from today', () => {
  assert.deepEqual(boardDates('today', new Date(2026, 10, 14)), { from: '2026-11-14', to: '2026-11-14' })
  assert.deepEqual(boardDates('7', new Date(2026, 10, 14)), { from: '2026-11-14', to: '2026-11-21' })
  assert.deepEqual(boardDates('14', new Date(2026, 11, 25)), { from: '2026-12-25', to: '2027-01-08' })
})

test('the crew list is always an array', () => {
  assert.deepEqual(crewNames(null), [])
  assert.deepEqual(crewNames([{ user_id: 'u', name: 'Sam', role: 'lead' }]), [{ user_id: 'u', name: 'Sam', role: 'lead' }])
})
