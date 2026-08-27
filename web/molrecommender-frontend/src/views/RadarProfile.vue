<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { getProfileRadar, type RadarDimension } from '../utils/api'

const userId = ref('anonymous')
const dimensions = ref<RadarDimension[]>([
  { name: '药物化学基础', score: 85 },
  { name: '分子对接知识', score: 60 },
  { name: 'ADMET理解', score: 55 },
  { name: '靶点生物学', score: 78 },
  { name: '合成路线设计', score: 45 },
  { name: '专利与法规', score: 90 },
])
const analysis = ref({
  knowledge_gaps: ['合成路线设计', 'ADMET理解'],
  analysis: '该学生基础概念较稳，但在成药性预测和合成路线判断上存在短板，建议优先使用案例式练习补强。',
  recommendations: ['完成 ADMET 五规则练习', '阅读逆合成分析入门', '对照真实候选分子做复盘'],
})

async function load() {
  try {
    const data = await getProfileRadar(userId.value) as any
    const payload = Array.isArray(data) ? { dimensions: data } : data.data || data
    if (Array.isArray(payload.dimensions)) dimensions.value = payload.dimensions
    if (payload.llm_analysis) analysis.value = payload.llm_analysis
  } catch {}
}

onMounted(load)
</script>

<template>
  <section class="content-grid two-columns">
    <el-card shadow="never">
      <template #header><div class="section-title"><span>六维能力雷达</span><el-tag>总分 {{ Math.round(dimensions.reduce((s, d) => s + d.score, 0) / dimensions.length) }}</el-tag></div></template>
      <div class="radar-bars" aria-label="六维学情雷达图">
        <article v-for="item in dimensions" :key="item.name">
          <span>{{ item.name }}</span>
          <el-progress :percentage="item.score" :stroke-width="14" />
        </article>
      </div>
    </el-card>
    <el-card shadow="never">
      <template #header><div class="section-title"><span>AI 深度分析</span><el-tag type="success">DeepSeek ready</el-tag></div></template>
      <h3>知识盲区</h3>
      <div class="tag-cloud"><el-tag v-for="gap in analysis.knowledge_gaps" :key="gap" type="danger">{{ gap }}</el-tag></div>
      <p>{{ analysis.analysis }}</p>
      <el-timeline>
        <el-timeline-item v-for="item in analysis.recommendations" :key="item" type="primary">{{ item }}</el-timeline-item>
      </el-timeline>
    </el-card>
  </section>
</template>
