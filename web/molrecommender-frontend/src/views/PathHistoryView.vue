<script setup lang="ts">
import { ref } from 'vue'
import { getLearningPathHistory } from '../utils/api'

const versions = ref([
  { version_id: 'v3', created_at: '2026-08-19', trigger: 'assessment_003', nodes: ['核心技能训练', '综合项目阶段', 'FPGA 实验'] },
  { version_id: 'v2', created_at: '2026-08-17', trigger: 'assessment_002', nodes: ['基础补强', '核心技能训练'] },
])
async function load() {
  try { const data = await getLearningPathHistory('anonymous') as any; if (Array.isArray(data.versions)) versions.value = data.versions } catch {}
}
load()
</script>

<template>
  <section class="stacked-page">
    <el-card shadow="never">
      <template #header><div class="section-title"><span>学习路径历史版本</span><el-tag>版本对比</el-tag></div></template>
      <el-timeline>
        <el-timeline-item v-for="version in versions" :key="version.version_id" :timestamp="`${version.created_at} · ${version.trigger}`">
          <strong>{{ version.version_id }}</strong>
          <p>{{ version.nodes.join(' -> ') }}</p>
        </el-timeline-item>
      </el-timeline>
      <section class="compare-panel"><article><h3>v2</h3><p>基础补强 -> 核心技能训练</p></article><article><h3>v3</h3><p>核心技能训练 -> 综合项目阶段 -> FPGA 实验</p></article></section>
    </el-card>
  </section>
</template>
