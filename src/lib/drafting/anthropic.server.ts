import Anthropic from '@anthropic-ai/sdk'
import { BRIEF_DRAFT_JSON_SCHEMA, DraftError } from './brief-draft.ts'
import type { Generated, GenerateParams } from './create-draft.ts'
import { DOCUMENT_ONLY_REQUEST, SYSTEM_PROMPT, materialText } from './prompt.ts'

/** Server only: reads ANTHROPIC_API_KEY. The browser never sees the key or calls the model. */
export const DEFAULT_MODEL = 'claude-opus-5-5'

type Block = Anthropic.Beta.BetaContentBlockParam

function contentFor({ text, file }: GenerateParams): Block[] {
  const blocks: Block[] = []
  if (file) {
    const data = Buffer.from(file.bytes).toString('base64')
    if (file.mime === 'application/pdf') {
      blocks.push({ type: 'document', source: { type: 'base64', media_type: 'application/pdf', data } })
    } else if (file.mime === 'text/plain') {
      blocks.push({ type: 'text', text: materialText(new TextDecoder().decode(file.bytes).slice(0, 60_000)) })
    } else {
      blocks.push({ type: 'image', source: { type: 'base64', media_type: file.mime, data } })
    }
  }
  if (text) blocks.push({ type: 'text', text: materialText(text) })
  if (file && !text && file.mime !== 'text/plain') blocks.push({ type: 'text', text: DOCUMENT_ONLY_REQUEST })
  return blocks
}

export function anthropicGenerator(options: { apiKey?: string; model?: string } = {}) {
  const apiKey = options.apiKey ?? process.env.ANTHROPIC_API_KEY
  const model = options.model ?? process.env.DRAFT_MODEL ?? DEFAULT_MODEL

  return async (params: GenerateParams): Promise<Generated> => {
    if (!apiKey) {
      console.error('ANTHROPIC_API_KEY is not set: AI drafting is unavailable')
      throw new DraftError('unavailable', 'AI drafting is not switched on yet. You can still start a brief by hand.')
    }
    const client = new Anthropic({ apiKey })
    try {
      // Structured output (not forced tool use, which this model refuses). `fallbacks: 'default'` lets the API
      // retry on a substitute model if the safety systems decline the first, so a harmless brief isn't lost.
      const response = await client.beta.messages.create({
        model,
        max_tokens: 16_000,
        betas: ['server-side-fallback-2026-07-01'],
        fallbacks: 'default',
        system: SYSTEM_PROMPT,
        output_config: { effort: 'medium', format: { type: 'json_schema', schema: BRIEF_DRAFT_JSON_SCHEMA } },
        messages: [{ role: 'user', content: contentFor(params) }],
      })
      if (response.stop_reason === 'refusal') {
        throw new DraftError('model_refused', 'The drafting assistant declined to draft from that. Try different wording, or start a brief by hand.')
      }
      if (response.stop_reason === 'max_tokens') {
        throw new DraftError('model_failed', 'That was too big to draft in one go. Try a shorter description or part of the document.')
      }
      const textBlock = response.content.find((b): b is Anthropic.Beta.BetaTextBlock => b.type === 'text')
      if (!textBlock) throw new DraftError('model_failed', 'The drafting assistant did not return a draft. Please try again.')
      let raw: unknown
      try {
        raw = JSON.parse(textBlock.text)
      } catch {
        throw new DraftError('model_failed', 'The drafting assistant returned something we could not read. Please try again.')
      }
      return {
        raw,
        model: response.model,
        usage: { input_tokens: response.usage.input_tokens, output_tokens: response.usage.output_tokens },
      }
    } catch (error) {
      if (error instanceof DraftError) throw error
      if (error instanceof Anthropic.RateLimitError) {
        throw new DraftError('unavailable', 'The drafting assistant is busy. Please try again in a minute.')
      }
      if (error instanceof Anthropic.APIError) {
        console.error(`Anthropic API error ${error.status}: ${error.message}`)
        throw new DraftError('model_failed', 'The drafting assistant had a problem. Please try again.')
      }
      throw error
    }
  }
}
