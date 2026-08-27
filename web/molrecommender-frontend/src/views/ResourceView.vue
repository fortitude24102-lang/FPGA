<script setup lang="ts">
import * as echarts from 'echarts'
import { nextTick, onBeforeUnmount, onMounted, ref } from 'vue'
import { resources } from '../utils/mockData'
import ProvenanceCard from '../components/ProvenanceCard.vue'
import { bindLazyImages } from '../utils/performance'

const chartRef = ref<HTMLDivElement | null>(null)
let chart: echarts.ECharts | null = null

function coverUrl(type: string) {
  return `https://dummyimage.com/640x320/2d6a5f/ffffff.png&text=${encodeURIComponent(type)}`
}

onMounted(async () => {
  await nextTick()
  bindLazyImages()
  if (!chartRef.value) return
  chart = echarts.init(chartRef.value)
  chart.setOption({
    color: ['#2D6A5F', '#D4A373'],
    tooltip: { trigger: 'axis' },
    grid: { left: 24, right: 20, top: 26, bottom: 26, containLabel: true },
    xAxis: { type: 'category', data: resources.map((item) => item.type), boundaryGap: false, axisTick: { show: false } },
    yAxis: { type: 'value', max: 100, splitLine: { show: false } },
    series: [
      { name: '难度', type: 'line', smooth: true, areaStyle: { opacity: 0.16 }, data: resources.map((item) => item.difficulty) },
      { name: '匹配度', type: 'line', smooth: true, areaStyle: { opacity: 0.18 }, data: resources.map((item) => item.match) },
    ],
  })
})

onBeforeUnmount(() => chart?.dispose())
</script>

<template>
  <section class="stacked-page">
    <el-card shadow="never">
      <template #header>难度匹配曲线</template>
      <div ref="chartRef" class="chart-box small" />
    </el-card>

    <div class="resource-grid">
      <article v-for="(item, index) in resources" :key="item.id" class="resource-card">
        <div class="resource-cover">
          <img class="lazy-resource-image" alt="资源封面" src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='320'%3E%3Crect width='640' height='320' fill='%23e8f3f1'/%3E%3C/svg%3E" :data-src="coverUrl(item.type)" />
          <span>{{ item.type.slice(0, 2) }}</span>
          <em v-if="index === 0">推荐</em>
        </div>
        <div class="resource-body">
          <div class="section-title">
            <el-tag>{{ item.blindSpot }}</el-tag>
            <strong>{{ item.match }}%</strong>
          </div>
          <h3>{{ item.title }}</h3>
          <p>{{ item.summary }}</p>
          <div class="resource-tags">
            <span>难度 {{ item.difficulty }}</span>
            <span>匹配 {{ item.match }}</span>
          </div>
          <el-progress :percentage="item.match" :stroke-width="12" />
        </div>
      </article>
    </div>

    <ProvenanceCard :resource-id="resources[0]!.id" />
  </section>
</template>
