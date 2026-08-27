<script setup lang="ts">
import { ref } from 'vue'
import { getPropagationRecommend } from '../utils/api'

const recommendations = ref([
  { label: 'Lipinski五规则', category: 'ADMET', activation_score: 1.25, propagation_path: 'SMILES --[用于计算]--> 分子描述符 --[支撑评估]--> Lipinski五规则' },
  { label: '分子对接', category: '结构生物学', activation_score: 0.8, propagation_path: '分子描述符 --[直接输入]--> 分子对接' },
])
async function load() { try { const data = await getPropagationRecommend('anonymous') as any; if (Array.isArray(data.recommendations)) recommendations.value = data.recommendations } catch {} }
load()
</script>

<template>
  <section class="stacked-page">
    <el-card shadow="never">
      <template #header><div class="section-title"><span>知识传播推荐</span><el-tag>activation propagation</el-tag></div></template>
      <article v-for="(item, index) in recommendations" :key="item.label" class="recommend-card">
        <strong>TOP {{ index + 1 }}：{{ item.label }} · {{ item.category }}</strong>
        <el-progress :percentage="Math.min(100, Math.round(item.activation_score * 60))" />
        <p>传播路径：{{ item.propagation_path }}</p>
        <div class="inline-actions"><el-button type="primary">开始学习</el-button><el-button>加入学习计划</el-button></div>
      </article>
    </el-card>
  </section>
</template>
