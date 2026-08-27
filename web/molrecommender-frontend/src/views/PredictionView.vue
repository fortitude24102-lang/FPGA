<script setup lang="ts">
import { computed, ref } from 'vue'
import { getPrediction } from '../utils/api'

const historyCount = ref(5)
const prediction = ref({ predicted_next_score: 78.5, low: 72.3, high: 84.7, trend: '上升', at_risk: false, recommended_intervention: '学习状态良好，建议推送进阶挑战任务' })
const riskType = computed(() => prediction.value.at_risk ? 'danger' : prediction.value.predicted_next_score < 70 ? 'warning' : 'success')
async function load() {
  try {
    const data = await getPrediction('anonymous') as any
    prediction.value = { ...prediction.value, ...data }
  } catch {}
}
load()
</script>

<template>
  <section class="stacked-page">
    <el-alert v-if="historyCount < 2" title="完成更多测试以生成预测" type="info" show-icon />
    <el-card shadow="never" class="prediction-card" :class="{ risk: prediction.at_risk }">
      <template #header><div class="section-title"><span>学习效果预测</span><el-tag :type="riskType">{{ prediction.trend }}</el-tag></div></template>
      <strong class="hero-number">{{ prediction.predicted_next_score }}</strong>
      <p>置信区间：[{{ prediction.low }}, {{ prediction.high }}]</p>
      <p>干预建议：{{ prediction.recommended_intervention }}</p>
      <div class="score-line"><span v-for="score in [45, 52, 60, 68, 72, prediction.predicted_next_score]" :key="score" :style="{ height: `${Number(score) * 2}px` }">{{ score }}</span></div>
    </el-card>
  </section>
</template>
