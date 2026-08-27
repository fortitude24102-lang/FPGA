<script setup lang="ts">
import { ref } from 'vue'
import { getLearningPathHistory } from '../utils/api'

const activeTab = ref('cards')
const versions = ref([
  { version_id: 'v3', created_at: '2026-08-19', trigger: 'assessment_003', path: ['核心技能训练', '综合项目阶段'] },
  { version_id: 'v2', created_at: '2026-08-17', trigger: 'assessment_002', path: ['基础补强', '核心技能训练'] },
  { version_id: 'v1', created_at: '2026-08-15', trigger: 'assessment_001', path: ['基础补强', '入门练习'] },
])
const resources = {
  cards: ['【化学视角】Lipinski 五规则知识卡片', '【CS视角】分子描述符计算卡片'],
  labs: ['FPGA 分子指纹计算实操', 'EGFR 对接结果解读实验'],
  tests: ['ADMET 分阶测试题', '合成路线判断题'],
}

async function loadHistory() {
  try {
    const data = await getLearningPathHistory('anonymous') as any
    if (Array.isArray(data.versions)) versions.value = data.versions
  } catch {}
}
loadHistory()
</script>

<template>
  <section class="stacked-page">
    <el-card shadow="never">
      <template #header><div class="section-title"><span>三种资源形态</span><el-tag>背景前缀适配</el-tag></div></template>
      <el-tabs v-model="activeTab">
        <el-tab-pane label="知识卡片" name="cards" />
        <el-tab-pane label="实操指南" name="labs" />
        <el-tab-pane label="分阶测试题" name="tests" />
      </el-tabs>
      <div class="resource-grid"><article v-for="item in resources[activeTab as keyof typeof resources]" :key="item" class="resource-card"><div class="resource-body"><strong>{{ item }}</strong><p>根据学习者背景自动调整讲解视角和资源顺序。</p></div></article></div>
    </el-card>
    <el-card shadow="never">
      <template #header><div class="section-title"><span>历史版本</span><el-tag>路径回溯</el-tag></div></template>
      <el-timeline>
        <el-timeline-item v-for="version in versions" :key="version.version_id" :timestamp="`${version.created_at} · ${version.trigger}`" placement="top">
          <strong>{{ version.version_id }}</strong>
          <p>{{ version.path.join(' -> ') }}</p>
        </el-timeline-item>
      </el-timeline>
      <div class="compare-strip"><span class="removed">移除：基础补强阶段</span><span class="added">新增：综合项目阶段</span><span class="added">增加：FPGA 分子指纹实验</span></div>
    </el-card>
  </section>
</template>
