import { expect, test } from '@playwright/test'

const pages = ['/startup', '/knowledge-graph', '/profile/credentials', '/privacy/statement']

for (const path of pages) {
  test(`visual snapshot ${path}`, async ({ page }) => {
    await page.goto(path)
    await page.waitForLoadState('networkidle')
    await expect(page).toHaveScreenshot(`${path.replaceAll('/', '_') || 'home'}.png`, { fullPage: true, maxDiffPixelRatio: 0.08 })
  })
}
