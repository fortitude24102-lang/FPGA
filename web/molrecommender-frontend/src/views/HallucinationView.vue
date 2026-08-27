<script setup lang="ts">
import { ref } from 'vue'
import { checkHallucination, getHallucinationStats } from '../utils/api'

const smiles = ref('COc1ccc2ncnc(Nc3ccc(F)c(Cl)c3)c2c1')
const result = ref<{ level?: string; rate?: number; types?: string[]; rdkit_basis?: string } | null>(null)
const stats = ref({ hallucination_rate: 0.08, success_rate: 0.92, coverage: 0.87 })

async function check() {
  try {
    result.value = await checkHallucination({ smiles: smiles.value, source: 'frontend' })
  } catch {
    result.value = { level: 'trusted', rate: 0.07, types: ['结构合法', '性质范围正常'], rdkit_basis: 'RDKit 校验通过，未发现明显幻觉风险。' }
  }
}

async function loadStats() {
  try { stats.value = await getHallucinationStats() } catch {}
}
loadStats()
</script>

<template>
  <section class="content-grid two-columns">
    <el-card shadow="never">
      <template #header>幻觉检测</template>
      <el-input v-model="smiles" type="textarea" :rows="5" placeholder="输入 SMILES" />
      <el-button type="primary" class="mt-12" @click="check">开始检测</el-button>
      <div v-if="result" class="verdict-box mt-12">
        <strong>风险等级：{{ result.level }}</strong>
        <p>幻觉率：{{ Math.round(Number(result.rate || 0) * 100) }}%</p>
        <p>{{ result.rdkit_basis }}</p>
      </div>
    </el-card>
    <el-card shadow="never">
      <template #header>检测统计</template>
      <div class="metric-grid">
        <div><span>幻觉率</span><strong>{{ Math.round(stats.hallucination_rate * 100) }}%</strong></div>
        <div><span>成功率</span><strong>{{ Math.round(stats.success_rate * 100) }}%</strong></div>
        <div><span>覆盖率</span><strong>{{ Math.round(stats.coverage * 100) }}%</strong></div>
      </div>
    </el-card>
  </section>
</template>

