import lighthouse from 'lighthouse'
import * as chromeLauncher from 'chrome-launcher'
import fs from 'node:fs'

const url = process.env.LH_URL || 'http://127.0.0.1:5173/startup'
const minPerformance = Number(process.env.LH_MIN_PERFORMANCE || 70)
const minAccessibility = Number(process.env.LH_MIN_ACCESSIBILITY || 90)
const chrome = await chromeLauncher.launch({ chromeFlags: ['--headless', '--no-sandbox'] })
try {
  const result = await lighthouse(url, {
    port: chrome.port,
    output: 'json',
    onlyCategories: ['performance', 'accessibility', 'best-practices'],
  })
  fs.mkdirSync('reports', { recursive: true })
  fs.writeFileSync('reports/lighthouse.json', result.report)
  const categories = result.lhr.categories
  const performance = Math.round(categories.performance.score * 100)
  const accessibility = Math.round(categories.accessibility.score * 100)
  const bestPractices = Math.round(categories['best-practices'].score * 100)
  fs.writeFileSync('reports/lighthouse-summary.json', JSON.stringify({ url, performance, accessibility, bestPractices, minPerformance, minAccessibility }, null, 2))
  console.log(`Lighthouse performance=${performance}, accessibility=${accessibility}, best-practices=${bestPractices}`)
  if (performance < minPerformance || accessibility < minAccessibility) process.exitCode = 1
} finally {
  try {
    await chrome.kill()
  } catch (error) {
    console.warn(`Chrome cleanup warning: ${error.message}`)
  }
}
