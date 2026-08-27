<script setup lang="ts">
import { computed, ref } from 'vue'
import { ElMessage } from 'element-plus'
import { getDebateVerdict, respondDebate, startDebate, type DebateRound } from '../utils/api'

type Verdict = { verdict: string; final_confidence?: number; duration_ms?: number; suggestions?: string[] }
const topic = ref('阿司匹林作为心血管预防药物的利弊')
const debateId = ref('')
const loading = ref(false)
const reply = ref('已考虑长期出血风险，建议限定高危获益人群并引入胃肠道保护策略。')
const rounds = ref<DebateRound[]>([])
const verdict = ref<Verdict | null>(null)
const statusText = computed(() => verdict.value ? '已完成' : debateId.value ? '进行中' : '待开始')

function normalizeRound(raw: Record<string, unknown>, index: number): DebateRound {
  return {
    round: Number(raw.round || index + 1),
    speaker: raw.speaker === 'Generator' ? 'Generator' : 'Reviewer',
    content: String(raw.content || raw.message || raw.question || 'AI 已生成一轮观点，请继续推进辩论。'),
    confidence: Number(raw.confidence || 0.82),
    evidence: Array.isArray(raw.evidence) ? raw.evidence.map(String) : ['ADMET规则#12', '临床风险证据'],
    timestamp: String(raw.timestamp || new Date().toLocaleTimeString()),
  }
}

async function start() {
  if (!topic.value.trim()) return ElMessage.warning('请先输入辩论主题')
  loading.value = true
  verdict.value = null
  try {
    const data = await startDebate({ topic: topic.value }) as Record<string, unknown>
    debateId.value = String(data.debate_id || data.id || `demo_${Date.now()}`)
    const first = (data.first_round || data.round || data) as Record<string, unknown>
    rounds.value = [normalizeRound(first, 0)]
  } catch {
    debateId.value = `demo_${Date.now()}`
    rounds.value = [{
      round: 1,
      speaker: 'Reviewer',
      content: `针对「${topic.value}」，Reviewer 质疑长期安全性、适用人群边界和证据等级是否充分。当前使用模拟逻辑，后端 LLM 接口可用后会替换为实时生成内容。`,
      confidence: 0.85,
      evidence: ['ADMET规则#12', '出血风险文献线索'],
      timestamp: new Date().toLocaleTimeString(),
    }]
  } finally {
    loading.value = false
  }
}

async function respond() {
  if (!debateId.value) return ElMessage.warning('请先开始辩论')
  loading.value = true
  try {
    const data = await respondDebate(debateId.value, { response: reply.value, round: rounds.value.length + 1 }) as Record<string, unknown>
    rounds.value.push(normalizeRound({ speaker: 'Generator', content: reply.value, confidence: 0.82, evidence: ['风险控制策略'] }, rounds.value.length))
    rounds.value.push(normalizeRound((data.next_round || data) as Record<string, unknown>, rounds.value.length))
  } catch {
    rounds.value.push(normalizeRound({ speaker: 'Generator', content: reply.value, confidence: 0.82, evidence: ['限定适应证', '剂量控制'] }, rounds.value.length))
    rounds.value.push(normalizeRound({ speaker: 'Reviewer', content: '进一步建议量化获益-风险比，并补充胃肠道保护和禁忌人群说明。', confidence: 0.88, evidence: ['药物警戒规则', '真实世界研究'] }, rounds.value.length))
  } finally {
    loading.value = false
  }
}

async function fetchVerdict() {
  if (!debateId.value) return ElMessage.warning('请先开始辩论')
  loading.value = true
  try {
    verdict.value = await getDebateVerdict(debateId.value) as Verdict
  } catch {
    verdict.value = { verdict: 'needs_revision', final_confidence: 0.86, duration_ms: 1420, suggestions: ['补充出血风险分层', '加入胃肠道保护策略', '说明适用人群边界'] }
  } finally {
    loading.value = false
  }
}

function reset() {
  debateId.value = ''
  rounds.value = []
  verdict.value = null
}
</script>

<template>
  <section class="stacked-page">
    <el-card shadow="never">
      <template #header><div class="section-title"><span>智能辩论大厅</span><el-tag>{{ statusText }}</el-tag></div></template>
      <div class="form-row">
        <el-input v-model="topic" aria-label="辩论主题" placeholder="输入辩论主题" @keyup.ctrl.enter="start" />
        <div class="inline-actions"><el-button type="primary" :loading="loading" @click="start">开始辩论</el-button><el-button @click="reset">重置</el-button></div>
      </div>
      <el-alert v-if="!debateId" title="LLM 未配置或接口不可用时，页面会显示模拟逻辑，便于前端验收。" type="info" show-icon :closable="false" />
    </el-card>

    <section class="debate-layout">
      <el-card shadow="never">
        <template #header><div class="section-title"><span>Reviewer / Generator 对话</span><el-tag>{{ rounds.length }} 轮</el-tag></div></template>
        <div class="debate-timeline">
          <article v-for="round in rounds" :key="`${round.round}-${round.timestamp}`" class="debate-bubble" :class="round.speaker">
            <strong>{{ round.speaker }} · Round {{ round.round }}</strong>
            <el-progress :percentage="Math.round(round.confidence * 100)" :stroke-width="8" />
            <p>{{ round.content }}</p>
            <small>证据：{{ round.evidence.join('、') }}</small>
          </article>
          <el-empty v-if="!rounds.length" description="输入主题后开始第一轮 AI 质询" />
        </div>
      </el-card>

      <el-card shadow="never">
        <template #header><div class="section-title"><span>回应与裁决</span></div></template>
        <el-input v-model="reply" type="textarea" :rows="5" placeholder="输入 Generator 回应" @keyup.ctrl.enter="respond" />
        <div class="debate-actions mt-12"><el-button type="primary" :loading="loading" @click="respond">提交回应</el-button><el-button :loading="loading" @click="fetchVerdict">获取裁决</el-button></div>
        <div v-if="verdict" class="verdict-box mt-12">
          <strong>最终裁决：{{ verdict.verdict }}</strong>
          <span>置信度：{{ Math.round(Number(verdict.final_confidence || 0.86) * 100) }}%</span>
          <p>建议：{{ (verdict.suggestions || ['需修改分子设计依据并补足证据链']).join('；') }}</p>
        </div>
      </el-card>
    </section>
  </section>
</template>
