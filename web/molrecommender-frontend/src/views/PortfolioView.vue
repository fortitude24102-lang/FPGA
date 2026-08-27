<script setup lang="ts">
import { ref } from 'vue'
import { ElMessage } from 'element-plus'
import { getPortfolio } from '../utils/api'

const month = ref('all')
const portfolioRef = ref<HTMLElement | null>(null)
const portfolio = ref({ total_study_hours: 12.5, total_assessments: 8, credentials: 3, updated_at: '2026-08-19', scores: [45, 52, 60, 68, 72, 75, 78, 82] })
async function load() {
  try {
    const data = await getPortfolio('anonymous') as Record<string, unknown>
    portfolio.value = { ...portfolio.value, ...data }
  } catch {}
}
async function exportImage() {
  if (!portfolioRef.value) return
  const html2canvas = (await import('html2canvas')).default
  const canvas = await html2canvas(portfolioRef.value, { backgroundColor: '#f4f6f3', scale: 2 })
  const link = document.createElement('a')
  link.href = canvas.toDataURL('image/png')
  link.download = `portfolio_${new Date().toISOString().slice(0, 10)}.png`
  link.click()
  ElMessage.success('学习档案图片已导出')
}
load()
</script>

<template>
  <section ref="portfolioRef" class="stacked-page">
    <el-card shadow="never">
      <template #header><div class="section-title"><span>学习档案</span><el-button @click="exportImage">导出图片</el-button></div></template>
      <p>用户 anonymous · 最后更新 {{ portfolio.updated_at }}</p>
      <div class="metric-grid">
        <div><span>总学习时长</span><strong>{{ portfolio.total_study_hours }} 小时</strong></div>
        <div><span>测评次数</span><strong>{{ portfolio.total_assessments }} 次</strong></div>
        <div><span>获得证书</span><strong>{{ portfolio.credentials }} 个</strong></div>
      </div>
      <el-select v-model="month" class="mt-12"><el-option label="全部月份" value="all" /><el-option label="最近三个月" value="quarter" /></el-select>
    </el-card>
    <el-card shadow="never">
      <template #header><div class="section-title"><span>技能演进时间轴</span><el-tag type="success">持续上升</el-tag></div></template>
      <div class="score-line" aria-label="overall_score 变化折线图">
        <span v-for="score in portfolio.scores" :key="score" :style="{ height: `${score * 2}px` }">{{ score }}</span>
      </div>
    </el-card>
  </section>
</template>
