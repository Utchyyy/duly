import { createServerFn } from '@tanstack/react-start'
import { DraftError, LIMITS } from './brief-draft.ts'

type Input = { accessToken: string; orgId: string; text?: string; filePath?: string }

function parse(raw: unknown): Input {
  const d = (raw && typeof raw === 'object' ? raw : {}) as Record<string, unknown>
  const str = (v: unknown, max: number) => (typeof v === 'string' ? v.slice(0, max) : undefined)
  const accessToken = str(d.accessToken, 8_000)
  const orgId = str(d.orgId, 64)
  if (!accessToken || !orgId) throw new Error('Please sign in again.')
  return { accessToken, orgId, text: str(d.text, LIMITS.inputText + 1), filePath: str(d.filePath, 300) }
}

/**
 * Draft a brief with AI and queue it for a person to approve. Runs on the server only. The model key
 * (ANTHROPIC_API_KEY) never reaches the browser, and the call is made as the signed-in person.
 */
export const draftBrief = createServerFn({ method: 'POST' })
  .validator(parse)
  .handler(async ({ data }): Promise<{ id: string }> => {
    const { runBriefDraft } = await import('./run-draft.server.ts')
    try {
      return await runBriefDraft(data)
    } catch (error) {
      if (error instanceof DraftError) throw new Error(error.message)
      console.error('Brief drafting failed', error)
      throw new Error('Drafting failed. Please try again.')
    }
  })
