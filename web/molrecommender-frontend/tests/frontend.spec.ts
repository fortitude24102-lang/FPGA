import { expect, test } from '@playwright/test'

test('student can complete core navigation', async ({ page }) => {
  await page.goto('/startup')
  await expect(page.getByRole('heading', { name: /启动检查/ })).toBeVisible()
  await page.getByText('学情测评').click()
  await expect(page.getByText('学情测评配置')).toBeVisible()
  await page.getByText('开始测评').click()
  await expect(page.getByText(/第 1\//)).toBeVisible()
})

test('rbac sends student to 403 for admin page', async ({ page }) => {
  await page.goto('/admin')
  await expect(page.getByText('当前角色无法访问该资源')).toBeVisible()
})

test('global search opens with shortcut', async ({ page }) => {
  await page.goto('/startup')
  await page.keyboard.press('Control+K')
  await expect(page.getByPlaceholder('搜索靶点、药物、知识点或页面')).toBeVisible()
})
