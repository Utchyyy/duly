import assert from 'node:assert/strict'
import { test } from 'node:test'
import { DraftError } from './brief-draft.ts'
import type { BriefDraft } from './brief-draft.ts'
import { createBriefDraft, mimeFor } from './create-draft.ts'
import type { DraftDeps, GenerateParams, SourceFile } from './create-draft.ts'

const ORG = '11111111-1111-4111-8111-111111111111'
const OTHER_ORG = '22222222-2222-4222-8222-222222222222'
const raw = { title: 'T', sections: [{ name: 'S', areas: [{ name: 'Hall', area_type: 'public area', minutes: 20, minutes_source: 'stated', standards: ['Floor clean'] }] }] }

function setup(over: Partial<DraftDeps> = {}) {
  const calls = { generate: [] as GenerateParams[], download: [] as string[], queued: [] as { org_id: string; source: Record<string, unknown>; draft: BriefDraft }[] }
  const deps: DraftDeps = {
    generate: async (p) => (calls.generate.push(p), { raw, model: 'test-model', usage: { input_tokens: 10, output_tokens: 5 } }),
    rolesIn: async () => ['owner'],
    download: async (path): Promise<SourceFile> => (calls.download.push(path), { path, mime: 'application/pdf', bytes: new Uint8Array([1, 2, 3]) }),
    addToQueue: async (row) => (calls.queued.push(row), 'queue-id-1'),
    now: () => new Date('2026-11-07T12:00:00Z'),
    ...over,
  }
  return { deps, calls }
}
const code = (c: DraftError['code']) => (e: unknown) => e instanceof DraftError && e.code === c

test('pasted text becomes one pending draft in the queue, and nothing else', async () => {
  const { deps, calls } = setup()
  const out = await createBriefDraft(deps, { orgId: ORG, text: '  Clean the hall weekly.  ' })
  assert.deepEqual(out, { id: 'queue-id-1' })
  assert.equal(calls.generate.length, 1)
  assert.equal(calls.generate[0]?.text, 'Clean the hall weekly.')
  assert.equal(calls.queued.length, 1)
  const row = calls.queued[0]!
  assert.equal(row.org_id, ORG)
  assert.equal(row.source.generated_by, 'ai')
  assert.equal(row.source.model, 'test-model')
  assert.equal(row.source.requested_at, '2026-11-07T12:00:00.000Z')
  assert.equal(row.draft.sections[0]?.areas[0]?.minutes, 20)
})

test('the pipeline can only reach the model, the queue and the source file: its dependencies have no brief, quote or price operations', () => {
  const { deps } = setup()
  assert.deepEqual(Object.keys(deps).sort(), ['addToQueue', 'download', 'generate', 'now', 'rolesIn'])
})

test('an uploaded document is read and passed to the model, and recorded as the source', async () => {
  const { deps, calls } = setup()
  await createBriefDraft(deps, { orgId: ORG, filePath: `${ORG}/1700000000-spec.pdf` })
  assert.deepEqual(calls.download, [`${ORG}/1700000000-spec.pdf`])
  assert.equal(calls.generate[0]?.file?.mime, 'application/pdf')
  assert.equal(calls.queued[0]?.source.file_path, `${ORG}/1700000000-spec.pdf`)
  assert.equal(calls.queued[0]?.source.file_type, 'application/pdf')
})

test('only owners and approvers can draft, and the model is not called for anyone else', async () => {
  for (const roles of [[], ['viewer'], ['vendor_admin'], ['operative']]) {
    const { deps, calls } = setup({ rolesIn: async () => roles })
    await assert.rejects(createBriefDraft(deps, { orgId: ORG, text: 'x' }), code('forbidden'))
    assert.equal(calls.generate.length, 0)
    assert.equal(calls.queued.length, 0)
  }
  const { deps } = setup({ rolesIn: async () => ['approver'] })
  await createBriefDraft(deps, { orgId: ORG, text: 'x' })
})

test('bad input is refused before any work is done', async () => {
  const cases: [Parameters<typeof createBriefDraft>[1], string][] = [
    [{ orgId: 'nope', text: 'x' }, 'bad organisation id'],
    [{ orgId: ORG }, 'nothing to draft from'],
    [{ orgId: ORG, text: '   ' }, 'blank text'],
    [{ orgId: ORG, text: 'x'.repeat(20_001) }, 'too long'],
    [{ orgId: ORG, filePath: `${OTHER_ORG}/a.pdf` }, "another organisation's file"],
    [{ orgId: ORG, filePath: `${ORG}/../${OTHER_ORG}/a.pdf` }, 'path traversal'],
    [{ orgId: ORG, filePath: `${ORG}/a.exe` }, 'unsupported file type'],
    [{ orgId: ORG, filePath: `${ORG}/a.html` }, 'html file'],
  ]
  for (const [req, why] of cases) {
    const { deps, calls } = setup()
    await assert.rejects(createBriefDraft(deps, req), code('invalid_input'), why)
    assert.equal(calls.generate.length + calls.download.length + calls.queued.length, 0, why)
  }
})

test('a refusal or failure from the model queues nothing', async () => {
  for (const err of [new DraftError('model_refused', 'no'), new DraftError('model_failed', 'bad'), new Error('network')]) {
    const { deps, calls } = setup({ generate: async () => { throw err } })
    await assert.rejects(createBriefDraft(deps, { orgId: ORG, text: 'x' }))
    assert.equal(calls.queued.length, 0)
  }
})

test('unusable model output queues nothing', async () => {
  for (const out of [null, {}, { sections: [] }, 'sorry, I cannot', { sections: [{ name: 'S', areas: [] }] }]) {
    const { deps, calls } = setup({ generate: async () => ({ raw: out, model: 'm' }) })
    await assert.rejects(createBriefDraft(deps, { orgId: ORG, text: 'x' }), code('unusable'))
    assert.equal(calls.queued.length, 0)
  }
})

test('what is queued is the sanitised draft, not the raw model output', async () => {
  const hostile = { ...raw, price: 0, title: 'T\u0000\u0000', sections: [{ name: 'S', hack: true, areas: [{ name: 'Hall', minutes: 99999, minutes_source: 'stated', standards: [], cost: 1 }] }] }
  const { deps, calls } = setup({ generate: async () => ({ raw: hostile, model: 'm' }) })
  await createBriefDraft(deps, { orgId: ORG, text: 'x' })
  const text = JSON.stringify(calls.queued[0]?.draft)
  assert.ok(!text.includes('price') && !text.includes('hack') && !text.includes('cost'))
  assert.equal(calls.queued[0]?.draft.sections[0]?.areas[0]?.minutes, 600)
})

test('a failure to queue (limits, access) surfaces and does not retry or double-queue', async () => {
  let attempts = 0
  const { deps } = setup({ addToQueue: async () => { attempts += 1; throw new DraftError('unavailable', 'Daily drafting limit reached') } })
  await assert.rejects(createBriefDraft(deps, { orgId: ORG, text: 'x' }), code('unavailable'))
  assert.equal(attempts, 1)
})

test('file types map to what the model can read', () => {
  assert.equal(mimeFor('a/b.PDF'), 'application/pdf')
  assert.equal(mimeFor('a/b.jpeg'), 'image/jpeg')
  assert.equal(mimeFor('a/b.webp'), 'image/webp')
  assert.equal(mimeFor('a/b.txt'), 'text/plain')
  assert.equal(mimeFor('a/b.svg'), null)
  assert.equal(mimeFor('a/noext'), null)
})
