import assert from 'node:assert/strict'
import { test } from 'node:test'
import { minutesText, pct, rangeDates, timeAgainstPlan, visitNotes } from './measures.ts'

test('rates read as whole percentages, and nothing to measure is a dash', () => {
  assert.equal(pct(0.667), '67%')
  assert.equal(pct(1), '100%')
  assert.equal(pct(0), '0%')
  assert.equal(pct(null), '–')
  assert.equal(pct(undefined), '–')
})

test('minutes read as minutes, or hours and minutes', () => {
  assert.equal(minutesText(0), '0 min')
  assert.equal(minutesText(42.7), '43 min')
  assert.equal(minutesText(60), '1 h')
  assert.equal(minutesText(128), '2 h 8 min')
  assert.equal(minutesText(null), '–')
})

test('time against plan flags both a rush job and an overrun', () => {
  assert.equal(timeAgainstPlan(null).tone, 'none')
  assert.equal(timeAgainstPlan(0.39).tone, 'watch')
  assert.match(timeAgainstPlan(0.39).label, /quicker than planned/)
  assert.equal(timeAgainstPlan(1).tone, 'ok')
  assert.equal(timeAgainstPlan(1.3).tone, 'ok')
  assert.equal(timeAgainstPlan(1.31).tone, 'watch')
  assert.match(timeAgainstPlan(1.5).label, /much longer/)
})

const visit = { late_minutes: 0, on_time: true, planned_minutes: 60, on_site_minutes: 60, planned_areas: 5, ticked_areas: 5, complaints: 0, first_time_right: true }

test('a visit is described by what went wrong, or that nothing did', () => {
  assert.deepEqual(visitNotes(visit), ['On time', 'Right first time'])
  assert.deepEqual(visitNotes({ ...visit, on_time: false, late_minutes: 20 }), ['20 min late', 'Right first time'])
  assert.deepEqual(visitNotes({ ...visit, ticked_areas: 3 }), ['On time', '3 of 5 areas ticked', 'Right first time'])
  assert.deepEqual(visitNotes({ ...visit, complaints: 1, first_time_right: false }), ['On time', '1 complaint'])
  assert.deepEqual(visitNotes({ ...visit, complaints: 2, first_time_right: false }), ['On time', '2 complaints'])
  assert.deepEqual(visitNotes({ ...visit, planned_areas: 0, ticked_areas: 0 }), ['On time', 'Right first time'])
})

test('a range ends tomorrow, so a visit later today is included', () => {
  assert.deepEqual(rangeDates(30, new Date(2026, 10, 14)), { from: '2026-10-15', to: '2026-11-15' })
  assert.deepEqual(rangeDates(90, new Date(2026, 0, 5)), { from: '2025-10-07', to: '2026-01-06' })
})
