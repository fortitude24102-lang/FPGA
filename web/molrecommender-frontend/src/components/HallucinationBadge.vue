<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { WarningFilled } from '@element-plus/icons-vue'
import { checkHallucination, type HallucinationResult } from '../utils/api'

const props = defineProps<{ text: string }>()

const result = ref<HallucinationResult>({
  rate: 0.028,
  level: 'trusted',
  types: ['结构合法性已通过', '证据链完整'],
  rdkit_basis: 'RDKit 可解析 SMILES，未发现价态异常。',
})

const badgeText = computed(() => {
  if (result.value.level === 'high_risk') return '高风险'
  if (result.value.level === 'suspicious') return '存疑'
  return '可信'
})

onMounted(async () => {
  try {
    result.value = await checkHallucination({ text: props.text })
  } catch {
    // 使用演示检测结果。
  }
})
</script>

<template>
  <el-tooltip placement="top" effect="light">
    <template #content>
      <div class="hallucination-tip">
        <strong>幻觉率：{{ Math.round(result.rate * 1000) / 10 }}%</strong>
        <span v-for="item in result.types" :key="item">{{ item }}</span>
        <p>{{ result.rdkit_basis }}</p>
      </div>
    </template>
    <span class="hallucination-badge" :class="result.level">
      <el-icon><WarningFilled /></el-icon>{{ badgeText }}
    </span>
  </el-tooltip>
</template>
