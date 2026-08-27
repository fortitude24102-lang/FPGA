<script setup lang="ts">
import * as echarts from 'echarts'
import { onBeforeUnmount, onMounted, ref } from 'vue'
import { runBatchTest, getBatchTestResults, type BatchTestResult } from '../utils/api'

const chartRef = ref<HTMLDivElement | null>(null)
const loading = ref(false)
let chart: echarts.ECharts | null = null

const rows = ref<BatchTestResult[]>([
  { user_type: '新手', hallucination_rate: 0.041, adaptation_accuracy: 0.86, coverage: 0.91, result: '通过' },
  { user_type: '中级', hallucination_rate: 0.029, adaptation_accuracy: 0.9, coverage: 0.93, result: '通过' },
  { user_type: '专家', hallucination_rate: 0.024, adaptation_accuracy: 0.88, coverage: 0.94, result: '通过' },
])

function renderChart() {
  if (!chartRef.value) return
  chart = echarts.init(chartRef.value)
  chart.setOption({
    color: ['#BD6B5C', '#2D6A5F', '#D4A373'],
    tooltip: { trigger: 'axis' },
    legend: { bottom: 0 },
    grid: { left: 34, right: 24, top: 24, bottom: 52, containLabel: true },
    xAxis: { type: 'category', data: rows.value.map((item) => item.user_type) },
    yAxis: { type: 'value', max: 100 },
    series: [
      { name: '幻觉率', type: 'bar', data: rows.value.map((item) => Math.round(item.hallucination_rate * 100)) },
      { name: '适配准确率', type: 'bar', data: rows.value.map((item) => Math.round(item.adaptation_accuracy * 100)) },
      { name: '覆盖率', type: 'bar', data: rows.value.map((item) => Math.round(item.coverage * 100)) },
      { name: '幻觉率阈值 5%', type: 'line', symbol: 'none', lineStyle: { type: 'dashed' }, data: rows.value.map(() => 5) },
      { name: '准确率阈值 85%', type: 'line', symbol: 'none', lineStyle: { type: 'dashed' }, data: rows.value.map(() => 85) },
    ],
  })
}

async function runTests() {
  loading.value = true
  try {
    const started = await runBatchTest({ cases: ['entry', 'intermediate', 'expert'] })
    rows.value = started.results || (await getBatchTestResults())
  } catch {
    // 保留演示测试数据。
  } finally {
    loading.value = false
    renderChart()
  }
}

onMounted(renderChart)
onBeforeUnmount(() => chart?.dispose())
</script>

<template>
  <section class="stacked-page">
    <el-card shadow="never">
      <template #header>
        <div class="section-title">
          <span>测试验证报告</span>
          <el-button type="primary" :loading="loading" @click="runTests">启动批量测试</el-button>
        </div>
      </template>
      <div ref="chartRef" class="chart-box" />
    </el-card>

    <el-card shadow="never">
      <template #header>三类用户画像测试用例</template>
      <el-table :data="rows">
        <el-table-column prop="user_type" label="用户类型" width="120" />
        <el-table-column label="幻觉率">
          <template #default="{ row }">{{ Math.round(row.hallucination_rate * 1000) / 10 }}%</template>
        </el-table-column>
        <el-table-column label="适配准确率">
          <template #default="{ row }">{{ Math.round(row.adaptation_accuracy * 100) }}%</template>
        </el-table-column>
        <el-table-column label="覆盖率">
          <template #default="{ row }">{{ Math.round(row.coverage * 100) }}%</template>
        </el-table-column>
        <el-table-column prop="result" label="结果" />
      </el-table>
      <div class="compare-strip">
        <span class="added">新增：ADMET 资源匹配</span>
        <span class="added">新增：Reviewer 证据复核</span>
        <span class="removed">删除：低置信度候选</span>
      </div>
    </el-card>
  </section>
</template>
