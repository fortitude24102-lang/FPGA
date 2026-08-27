<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { Connection, DocumentChecked, Files } from '@element-plus/icons-vue'
import { getResourceProvenance, type Provenance } from '../utils/api'

const props = defineProps<{ resourceId: string }>()

const provenance = ref<Provenance>({
  knowledge_sources: [
    { type: '靶点库', name: 'EGFR 活性片段库', confidence: 0.92 },
    { type: 'ADMET规则', name: 'logP / hERG 风险规则', confidence: 0.86 },
    { type: '文献', name: '公开 SAR 综述', confidence: 0.79 },
  ],
  generation_path: ['Analyzer', 'Planner', 'Generator', 'Reviewer'],
  validation_chain: [
    { name: 'RDKit 结构校验', status: 'passed', detail: 'SMILES 可解析，结构合法' },
    { name: 'ADMET 规则复核', status: 'warning', detail: 'logP 接近阈值，需要二轮优化' },
    { name: 'Reviewer 交叉验证', status: 'passed', detail: '候选分子证据链完整' },
  ],
  generated_at: new Date().toISOString(),
})

onMounted(async () => {
  try {
    provenance.value = await getResourceProvenance(props.resourceId)
  } catch {
    // 使用本地演示溯源链，避免后端未实现时页面断层。
  }
})
</script>

<template>
  <el-card shadow="never">
    <template #header>
      <div class="section-title">
        <span>知识溯源</span>
        <el-tag>{{ resourceId }}</el-tag>
      </div>
    </template>

    <div class="provenance-grid">
      <section>
        <h3><el-icon><Files /></el-icon>知识来源</h3>
        <article v-for="item in provenance.knowledge_sources" :key="item.name" class="source-row">
          <strong>{{ item.type }}</strong>
          <span>{{ item.name }}</span>
          <el-progress :percentage="Math.round(item.confidence * 100)" :stroke-width="8" />
        </article>
      </section>

      <section>
        <h3><el-icon><Connection /></el-icon>生成路径</h3>
        <div class="path-chips">
          <span v-for="item in provenance.generation_path" :key="item">{{ item }}</span>
        </div>
      </section>

      <section>
        <h3><el-icon><DocumentChecked /></el-icon>验证链</h3>
        <el-timeline>
          <el-timeline-item
            v-for="item in provenance.validation_chain"
            :key="item.name"
            :type="item.status === 'passed' ? 'success' : item.status === 'warning' ? 'warning' : 'danger'"
          >
            <strong>{{ item.name }}</strong>
            <p>{{ item.detail }}</p>
          </el-timeline-item>
        </el-timeline>
      </section>
    </div>
  </el-card>
</template>
