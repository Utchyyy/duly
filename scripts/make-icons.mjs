// Renders the Duly Crew install icons (PNG) from the logo mark, using the Chromium that Playwright ships.
//   node scripts/make-icons.mjs
// Re-run after changing the mark. The PNGs are committed; this is not part of the build.
import { writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'

// Playwright is a developer tool, not a dependency of the app, so it is loaded when this script runs.
const { chromium } = createRequire(import.meta.url)('playwright')

const GREEN = '#1F5C45'
const CREAM = '#F6F3EC'
const MARK = 'M20 16h11c11 0 18 6.5 18 16s-7 16-18 16H20zm8 7v18h3c6.3 0 10-3.4 10-9s-3.7-9-10-9z'

// "any": the rounded tile, as in icon.svg. "full": a full-bleed square with the mark inside the maskable safe zone
// (the middle 80%), for Android's adaptive masks and Apple's home screen, which round the corners themselves.
const svg = (kind) =>
  kind === 'any'
    ? `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="${GREEN}"/><path d="${MARK}" fill="${CREAM}"/></svg>`
    : `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" fill="${GREEN}"/><g transform="translate(32 32) scale(0.78) translate(-32 -32)"><path d="${MARK}" fill="${CREAM}"/></g></svg>`

const jobs = [
  ['public/icons/icon-192.png', 192, 'any'],
  ['public/icons/icon-512.png', 512, 'any'],
  ['public/icons/icon-maskable-512.png', 512, 'full'],
  ['public/icons/apple-touch-icon.png', 180, 'full'],
]

const browser = await chromium.launch()
const page = await browser.newPage()
for (const [file, size, kind] of jobs) {
  await page.setViewportSize({ width: size, height: size })
  await page.setContent(`<body style="margin:0;background:transparent">${svg(kind).replace('<svg ', `<svg width="${size}" height="${size}" `)}</body>`)
  writeFileSync(file, await page.screenshot({ type: 'png', omitBackground: true, clip: { x: 0, y: 0, width: size, height: size } }))
  console.log('wrote', file)
}
await browser.close()
