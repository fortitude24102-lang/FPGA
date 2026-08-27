<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { CircleCheck, Warning, CircleClose } from '@element-plus/icons-vue'
import { ElMessage } from 'element-plus'
import { getDebateRounds, getDebateVerdict, respondDebate, startDebate, type DebateRound } from '../utils/api'

const debateId = ref('demo-debate-001')
const verdict = ref<'approved' | 'rejected' | 'needs_revision'>('needs_revision')
const finalConfidence = ref(0.84)
const selectedRound = ref(0)
const starting = ref(false)
const responding = ref(false)
const verdicting = ref(false)
const canRespond = ref(true)
const canVerdict = ref(true)

const rounds = ref<DebateRound[]>([
  {
    round: 1,
    speaker: 'Reviewer',
    content: '候选 2 的 logP 偏高，可能带来溶解度和成药性风险。',
    confidence: 0.76,
    evidence: ['logP = 5.4，高于约束阈值 5', 'ADMET 规则提示疏水性偏强'],
    timestamp: '00:08',
  },
  {
    round: 2,
    speaker: 'Generator',
    content: '已替换疏水片段，保留核心药效团并降低疏水性。',
    confidence: 0.71,
    evidence: ['核心片段未改变', '替换片段预计降低 logP 约 0.9'],
    timestamp: '00:16',
  },
  {
    round: 3,
    speaker: 'Reviewer',
    content: '活性保持，ADMET 风险降低，但仍建议补充 hERG 检查。',
    confidence: 0.84,
    evidence: ['pKi 预测保持在 8.1 以上', 'hERG 证据不足，标记为需复核'],
    timestamp: '00:24',
  },
])

const current = computed(() => rounds.value[selectedRound.value] || rounds.value[0])
const verdictLabel = computed(() => {
  if (verdict.value === 'approved') return '通过'
  if (verdict.value === 'rejected') return '拒绝'
  return '需要修订'
})

function unwrapData<T>(raw: unknown): T {
  const wrapped = raw as { data?: T }
  return (wrapped && wrapped.data ? wrapped.data : raw) as T
}

function normalizeRounds(raw: unknown) {
  const data = unwrapData<{ rounds?: DebateRound[] } | DebateRound[]>(raw)
  if (Array.isArray(data)) return data
  return data.rounds || []
}

async function startAiDebate() {
  starting.value = true
  try {
    const started = unwrapData<{ debate_id: string; rounds?: DebateRound[] }>(
      await startDebate({ topic: '候选分子审核辩论', molecule_id: 'mol-egfr-002' }),
    )
    debateId.value = started.debate_id
    if (started.rounds?.length) {
      rounds.value = started.rounds
    } else {
      const remoteRounds = normalizeRounds(await getDebateRounds(started.debate_id))
      if (remoteRounds.length) rounds.value = remoteRounds
    }
    selectedRound.value = 0
    canRespond.value = true
    canVerdict.value = rounds.value.length >= 2
    ElMessage.success('AI Reviewer 首轮质疑已生成')
  } catch {
    //Message.warning('辩论接口暂不可用，继续使用演示辩论数据')
  } finally {
    starting.value = false
  }
}

async function submitAiResponse() {
  responding.value = true
  try {
    const response = await respondDebate(debateId.value, {
      speaker: 'Generator',
      content: '我的分子设计考虑了 Lipinski 五规则、logP 约束和 hERG 安全性。',
      confidence: 0.82,
      evidence: ['Lipinski 五规则', 'hERG 风险阈值', 'EGFR SAR 片段证据'],
    })
    const nextRounds = normalizeRounds(response)
    if (nextRounds.length) {
      rounds.value = nextRounds
    } else {
      rounds.value = [
        ...rounds.value,
        {
          round: rounds.value.length + 1,
          speaker: 'Generator',
          content: '已提交 Generator 回应，等待 Reviewer 下一轮 LLM 质疑。',
          confidence: 0.82,
          evidence: ['Lipinski 五规则', 'hERG 风险阈值'],
          timestamp: 'AI',
        },
      ]
    }
    selectedRound.value = Math.max(rounds.value.length - 1, 0)
    canVerdict.value = rounds.value.length >= 3
    ElMessage.success('AI 已生成下一轮辩论内容')
  } catch {
    ElMessage.warning('回应接口暂不可用，已保留当前辩论轮次')
  } finally {
    responding.value = false
  }
}

async function requestAiVerdict() {
  verdicting.value = true
  try {
    const result = unwrapData<{ verdict: 'approved' | 'rejected' | 'needs_revision'; final_confidence: number }>(
      await getDebateVerdict(debateId.value),
    )
    verdict.value = result.verdict
    finalConfidence.value = result.final_confidence
    canRespond.value = false
    canVerdict.value = false
    ElMessage.success(`裁决：${verdictLabel.value}`)
  } catch {
    ElMessage.warning('裁决接口暂不可用，保留演示裁决结果')
  } finally {
    verdicting.value = false
  }
}

onMounted(async () => {
  await startAiDebate()
})
</script>

<template>
  <div class="debate-system">
    <div class="debate-actions">
      <el-button type="primary" :loading="starting" :disabled="starting" @click="startAiDebate">
        {{ starting ? 'AI Reviewer 正在思考...' : '发起辩论' }}
      </el-button>
      <el-button :loading="responding" :disabled="!canRespond || starting || responding" @click="submitAiResponse">
        {{ responding ? 'AI 正在生成回应...' : '提交回应' }}
      </el-button>
      <el-button type="success" :loading="verdicting" :disabled="!canVerdict || starting || verdicting" @click="requestAiVerdict">
        {{ verdicting ? 'AI 评审中...' : '获取裁决' }}
      </el-button>
    </div>

    <div class="verdict-banner" :class="verdict">
      <el-icon v-if="verdict === 'approved'"><CircleCheck /></el-icon>
      <el-icon v-else-if="verdict === 'rejected'"><CircleClose /></el-icon>
      <el-icon v-else><Warning /></el-icon>
      <div>
        <strong>裁决结果：{{ verdictLabel }}</strong>
        <span>final_confidence：{{ Math.round(finalConfidence * 100) }}% · {{ debateId }}</span>
      </div>
    </div>

    <div class="debate-layout">
      <div class="debate-timeline">
        <button
          v-for="(item, index) in rounds"
          :key="`${item.round}-${item.speaker}`"
          class="debate-bubble"
          :class="[item.speaker, { active: selectedRound === index }]"
          @click="selectedRound = index"
        >
          <small>{{ item.timestamp }} · Round {{ item.round }}</small>
          <strong>{{ item.speaker }}</strong>
          <span class="typewriter">{{ item.content }}</span>
          <el-progress :percentage="Math.round(item.confidence * 100)" :stroke-width="7" />
        </button>
      </div>

      <aside class="evidence-panel">
        <p class="eyebrow">当前轮次详情</p>
        <h3>{{ current?.speaker }}</h3>
        <p>{{ current?.content }}</p>
        <div class="evidence-list">
          <article v-for="item in current?.evidence" :key="item">
            <strong>Evidence</strong>
            <span>{{ item }}</span>
          </article>
        </div>
      </aside>
    </div>
  </div>
</template>
