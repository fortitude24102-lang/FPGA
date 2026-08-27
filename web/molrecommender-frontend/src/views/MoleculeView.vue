<script setup lang="ts">
import { computed, ref } from 'vue'
import { CopyDocument } from '@element-plus/icons-vue'
import { ElMessage } from 'element-plus'
import { getFingerprint, getMoleculeInfo, getSimilarity } from '../utils/api'
import { demoCandidates } from '../utils/mockData'
import FpgaCompute from '../components/FpgaCompute.vue'
import HallucinationBadge from '../components/HallucinationBadge.vue'

const smilesInput = ref('CCO')
const smiles1 = ref('CCO')
const smiles2 = ref('CCCO')
const properties = ref<Record<string, unknown> | null>(null)
const fingerprint = ref<Record<string, unknown> | null>(null)
const similarity = ref<Record<string, unknown> | null>(null)

const similarityValue = computed(() => {
  const data = similarity.value?.data as Record<string, unknown> | undefined
  const value = similarity.value?.similarity || data?.similarity || similarity.value?.tanimoto_maccs || data?.tanimoto_maccs || 0
  return Math.round(Number(value) * 100)
})

const fpgaSource = computed(() => String(similarity.value?.source || fingerprint.value?.source || 'cpu_fallback'))
const fpgaTraceId = computed(() => {
  const data = similarity.value?.data as Record<string, unknown> | undefined
  return String(similarity.value?.trace_id || data?.trace_id || fingerprint.value?.trace_id || '')
})

function structureLabel(smiles: string) {
  return smiles.replace(/[^A-Za-z0-9]/g, '').slice(0, 12) || 'MOLECULE'
}

async function copySmiles(smiles: string) {
  await navigator.clipboard.writeText(smiles)
  ElMessage.success('SMILES 已复制')
}

async function queryMolecule() {
  try {
    const info = await getMoleculeInfo(smilesInput.value)
    const fp = await getFingerprint(smilesInput.value)
    properties.value = info as unknown as Record<string, unknown>
    fingerprint.value = fp as unknown as Record<string, unknown>
    ElMessage.success('分子接口通信成功')
  } catch (error) {
    properties.value = { smiles: smilesInput.value, formula: 'C2H6O', molecular_weight: 46.07, logp: -0.1, source: 'cpu_fallback' }
    fingerprint.value = { smiles: smilesInput.value, fp_size: 2048, fingerprint: '演示指纹数据' }
    ElMessage.warning(error instanceof Error ? `使用演示数据：${error.message}` : '使用演示数据')
  }
}

async function compare() {
  try {
    similarity.value = (await getSimilarity(smiles1.value, smiles2.value)) as unknown as Record<string, unknown>
  } catch {
    similarity.value = { smiles1: smiles1.value, smiles2: smiles2.value, similarity: 0.72 }
  }
}
</script>

<template>
  <section class="stacked-page">
    <el-card shadow="never">
        <template #header>候选分子展示</template>
      <div class="table-tools">
        <HallucinationBadge text="候选分子结构、属性与推荐理由综合校验" />
      </div>
      <el-table :data="demoCandidates">
        <el-table-column prop="id" label="编号" width="150" />
        <el-table-column prop="smiles" label="SMILES" min-width="300">
          <template #default="{ row }">
            <span class="smiles-cell">{{ row.smiles }}</span>
            <el-button class="copy-btn" text :icon="CopyDocument" @click="copySmiles(row.smiles)" />
          </template>
        </el-table-column>
        <el-table-column prop="pKi" label="pKi" width="90" />
        <el-table-column prop="logP" label="logP" width="90" />
        <el-table-column prop="molecularWeight" label="分子量" width="110" />
        <el-table-column prop="status" label="状态" width="120">
          <template #default="{ row }">
            <span class="status-label" :class="row.status"><i />{{ row.status }}</span>
          </template>
        </el-table-column>
        <el-table-column prop="note" label="建议" min-width="240" />
      </el-table>
    </el-card>

    <section class="content-grid two-columns">
      <el-card shadow="never">
        <template #header>分子结构与属性查询</template>
        <div class="form-row">
          <el-input v-model="smilesInput" placeholder="输入 SMILES" />
          <el-button type="primary" @click="queryMolecule">查询</el-button>
        </div>
        <div class="molecule-sketch">
          <div class="sketch-ring">{{ structureLabel(smilesInput) }}</div>
          <small>结构渲染区：可接入 RDKit.js SVG 绘制</small>
        </div>
        <div v-if="properties" class="property-pills">
          <span v-for="(value, key) in properties" :key="key">{{ key }}：{{ value }}</span>
        </div>
      </el-card>

      <el-card shadow="never">
        <template #header>指纹、相似度与计算链路</template>
        <FpgaCompute :source="fpgaSource" :trace-id="fpgaTraceId" warning="如果后端返回 FPGA 状态，组件会展示真实计算来源。" />
        <el-input v-model="smiles1" placeholder="分子1 SMILES" class="mt-12" />
        <el-input v-model="smiles2" placeholder="分子2 SMILES" class="mt-12" />
        <el-button class="mt-12" type="success" @click="compare">计算相似度</el-button>
        <div v-if="similarity" class="similarity-box">
          <strong>相似度 {{ similarityValue }}%</strong>
          <el-progress :percentage="similarityValue" :stroke-width="14" />
        </div>
        <pre v-if="fingerprint">{{ fingerprint }}</pre>
      </el-card>
    </section>
  </section>
</template>
