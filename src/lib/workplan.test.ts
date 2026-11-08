import assert from 'node:assert/strict'
import { test } from 'node:test'
import { dayMinutes, dayOf, methodsUsed, minutesLabel, parseLegend, parsePlan, problemsBeforeSending, rowPath, weekMinutes, workForDay } from './workplan.ts'

const plan = parsePlan({
  sections: [
    {
      id: 's1',
      name: 'Changing room',
      subsections: [
        {
          id: 's1-1',
          name: 'Showers',
          areas: [
            { id: 'a', name: 'Drains', days: { sun: 'scrub', tue: 'clean', fri: 'mop' } },
            { id: 'b', name: 'Walls', days: { sun: 'wash', mon: 'polish', bogus: 'wash' } },
          ],
        },
      ],
    },
  ],
})
const legend = parseLegend({ scrub: { minutes: 10 }, wash: { minutes: '6' }, clean: { minutes: 3 }, mop: { minutes: null }, polish: { minutes: 99 } })

test('only known weekdays and methods survive parsing', () => {
  assert.deepEqual(plan.sections[0].subsections[0].areas[1].days, { sun: 'wash' })
})

test('the legend keeps minutes for known methods only, as whole numbers', () => {
  assert.deepEqual(legend, { scrub: { minutes: 10 }, wash: { minutes: 6 }, clean: { minutes: 3 }, mop: { minutes: null } })
  assert.equal(parseLegend({ scrub: { minutes: -4 } }).scrub.minutes, null)
  assert.equal(parseLegend({ scrub: { minutes: 'abc' } }).scrub.minutes, null)
  assert.equal(parseLegend(null).clean.minutes, null)
})

test('a day adds the vendor minutes for the method set on each area', () => {
  assert.equal(dayMinutes(plan, legend, 'sun'), 16) // scrub 10 + wash 6
  assert.equal(dayMinutes(plan, legend, 'tue'), 3)
  assert.equal(dayMinutes(plan, legend, 'fri'), 0) // mop has no minutes yet
  assert.equal(dayMinutes(plan, legend, 'sat'), 0)
  assert.equal(weekMinutes(plan, legend), 19)
})

test('methods in use are reported in a fixed order', () => {
  assert.deepEqual(methodsUsed(plan), ['scrub', 'wash', 'clean', 'mop'])
})

test('a schedule is not ready until it has areas and minutes for every method it uses', () => {
  assert.deepEqual(problemsBeforeSending(parsePlan({ sections: [] }), legend), ['Add at least one cleaning area.'])
  assert.deepEqual(problemsBeforeSending(plan, legend), ['Set the minutes for mop.'])
  assert.deepEqual(problemsBeforeSending(plan, { ...legend, mop: { minutes: 5 } }), [])
  const blank = parsePlan({ sections: [{ id: 's', name: '', subsections: [{ id: 'ss', name: ' ', areas: [{ id: 'r', name: '', days: { mon: 'clean' } }] }] }] })
  const problems = problemsBeforeSending(blank, legend)
  assert.ok(problems.includes('Every section needs a name.') && problems.includes('Every sub-section needs a name.') && problems.includes('Every cleaning area needs a name.'))
  assert.ok(problemsBeforeSending(parsePlan({ sections: [{ id: 's', name: 'S', subsections: [{ id: 'ss', name: 'SS', areas: [{ id: 'r', name: 'R', days: {} }] }] }] }), legend).includes('Set a method on at least one day.'))
})

test('a cleaning area has a path the client can quote in a complaint', () => {
  assert.equal(rowPath(plan, 'a'), 'Changing room > Showers > Drains')
  assert.equal(rowPath(plan, 'nope'), null)
})

test("one day's work lists only the areas planned that day", () => {
  const sunday = workForDay(plan, 'sun')
  assert.equal(sunday.length, 1)
  assert.deepEqual(sunday[0].rows.map((r) => `${r.row.name}:${r.method}`), ['Drains:scrub', 'Walls:wash'])
  assert.deepEqual(workForDay(plan, 'mon'), [])
})

test('weekday names follow the date, with Sunday first in JavaScript', () => {
  assert.equal(dayOf(new Date(2026, 10, 8)), 'sun') // Sun 8 Nov 2026
  assert.equal(dayOf(new Date(2026, 10, 9)), 'mon')
})

test('minutes read as hours and minutes', () => {
  assert.equal(minutesLabel(0), '0 min')
  assert.equal(minutesLabel(45), '45 min')
  assert.equal(minutesLabel(60), '1 h')
  assert.equal(minutesLabel(135), '2 h 15 min')
})
