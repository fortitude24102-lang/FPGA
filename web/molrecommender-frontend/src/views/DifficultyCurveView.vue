<script setup lang="ts">
import * as echarts from 'echarts'
import { onBeforeUnmount, onMounted, ref } from 'vue'
import { getDifficultyCurve } from '../utils/api'

const chartRef = ref<HTMLElement | null>(null)
const userId = ref('anonymous')
let chart: echarts.ECharts | null = null
const trend = ref('上升')
const data = ref({ labels: ['第1次', '第2次', '第3次', '第4次', '第5次'], recommended: [45, 55, 64, 72, 80], actual: [42, 52, 60, 68, 76] })

function draw() {
  if (!chartRef.value) return
  chart = chart || echarts.init(chartRef.value)
  chart.setOption({
    tooltip: { trigger: 'axis' },
    legend: { data: ['推荐难度', '实际正确率'] },
    grid: { left: 38, right: 22, top: 48, bottom: 32 },
    xAxis: { type: 'category', data: data.value.labels },
    yAxis: { type: 'value', min: 0, max: 100 },
    series: [
      { name: '推荐难度', type: 'line', smooth: true, data: data.value.recommended, areaStyle: {} },
      { name: '实际正确率', type: 'line', smooth: true, data: data.value.actual },
    ],
  })
}

async function load() {
  try {
    const remote = await getDifficultyCurve(userId.value) as any
    if (Array.isArray(remote.recommended) && Array.isArray(remote.actual)) data.value = remote
    trend.value = remote.trend || trend.value
  } catch {}
  draw()
}

onMounted(load)
onBeforeUnmount(() => chart?.dispose())
</script>

<template>
  <section class="stacked-page">
    <el-card shadow="never">
      <template #header><div class="section-title"><span>难度匹配曲线</span><el-tag type="success">{{ trend }}</el-tag></div></template>
      <div ref="chartRef" class="chart-box" aria-label="推荐难度与实际正确率双折线图"></div>
    </el-card>
  </section>
</template>
