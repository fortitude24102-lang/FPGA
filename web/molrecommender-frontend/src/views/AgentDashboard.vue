<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { Check, Connection, Cpu } from '@element-plus/icons-vue'
import { getAgentStatus } from '../utils/api'
import { wsManager, type WsStatus } from '../utils/websocket'
import DebatePanel from '../components/DebatePanel.vue'
import ConfidenceGauge from '../components/ConfidenceGauge.vue'
import SystemStats from '../components/SystemStats.vue'

const progress = ref(0)
const activeStep = ref(0)
const summaryVisible = ref(false)
const wsStatus = ref<WsStatus>('closed')
const historyVisible = ref(false)
let timer: number | undefined
let offStatus: (() => void) | undefined

const agents = ref([
  { name: 'Analyzer', role: '画像与知识盲区分析', status: '等待', progress: 0, color: '#4A9085', confidence: 82 },
  { name: 'Planner', role: '研究策略规划', status: '等待', progress: 0, color: '#7B6B9E', confidence: 78 },
  { name: 'Generator', role: '候选分子生成', status: '等待', progress: 0, color: '#6B8E9F', confidence: 74 },
  { name: 'Reviewer', role: '交叉验证与审核', status: '等待', progress: 0, color: '#D4A373', confidence: 88 },
  { name: 'Learner', role: '反馈学习与更新', status: '等待', progress: 0, color: '#5B9A6D', confidence: 81 },
  { name: 'KG Agent', role: '知识图谱与关系推理', status: '等待', progress: 0, color: '#8A7D3B', confidence: 83 },
])

const logs = ref([{ time: '00:00', from: 'System', text: '等待研究员画像输入。' }])
const debateSteps = ['Reviewer 初审发现风险', 'Generator 生成替代结构', 'Planner 汇总证据', 'Learner 记录偏好']
const debateHistory = [
  { topic: '候选 2 logP 偏高', result: 'needs_revision', confidence: 0.84 },
  { topic: '候选 1 选择性证据', result: 'approved', confidence: 0.91 },
  { topic: '候选 3 活性不足', result: 'rejected', confidence: 0.77 },
]

const summary = computed(() => ({
  blindSpots: 'ADMET预测、GNN/机器学习、合成可及性',
  strategy: '规则模板 + 分子生成 + 交叉验证',
  molecules: 12,
  resources: 3,
}))

function tickSimulation() {
  const current = agents.value[activeStep.value]
  if (!current) {
    summaryVisible.value = true
    return
  }
  current.status = '执行'
  current.progress = Math.min(current.progress + 25, 100)
  progress.value = Math.min(progress.value + 5, 100)
  if (current.progress >= 100) {
    current.status = '完成'
    logs.value.push({
      time: `00:${String((activeStep.value + 1) * 8).padStart(2, '0')}`,
      from: current.name,
      text: `${current.role}完成，并将结果传递给下一个 Agent。`,
    })
    activeStep.value += 1
  }
}

onMounted(async () => {
  offStatus = wsManager.onStatus((status) => (wsStatus.value = status))
  wsManager.connect()
  wsManager.on('agent_thought', (payload) => logs.value.push({ time: 'WS', from: 'Agent', text: JSON.stringify(payload) }))
  wsManager.on('debate_update', (payload) => logs.value.push({ time: 'WS', from: 'Debate', text: JSON.stringify(payload) }))
  wsManager.on('adaptation_notice', (payload) => logs.value.push({ time: 'WS', from: 'Learner', text: JSON.stringify(payload) }))

  try {
    await getAgentStatus()
    logs.value.push({ time: '00:01', from: 'Backend', text: '已读取后端 Agent 状态。' })
  } catch {
    logs.value.push({ time: '00:01', from: 'Demo', text: '使用前端模拟状态展示协同调度过程。' })
  }

  timer = window.setInterval(() => {
    tickSimulation()
    if (summaryVisible.value && timer) window.clearInterval(timer)
  }, 700)
})

onBeforeUnmount(() => {
  if (timer) window.clearInterval(timer)
  offStatus?.()
})
</script>

<template>
  <section class="stacked-page">
    <el-card shadow="never">
      <template #header>
        <div class="section-title">
          <span>多智能体协同调度过程</span>
          <el-tag :icon="Connection" type="info">WS：{{ wsStatus }}</el-tag>
        </div>
      </template>
      <el-progress class="flow-progress" :percentage="progress" :stroke-width="14" />
      <div class="agent-pipeline">
        <svg class="message-bus" viewBox="0 0 100 12" preserveAspectRatio="none">
          <line x1="2" y1="6" x2="98" y2="6" />
          <circle r="2" cy="6">
            <animate attributeName="cx" values="4;96;4" dur="4s" repeatCount="indefinite" />
          </circle>
        </svg>
        <template v-for="(agent, index) in agents" :key="agent.name">
          <article class="agent-card pipeline-node" :class="{ running: agent.status === '执行' }" :style="{ '--agent-color': agent.color }">
            <el-icon class="agent-icon"><Cpu /></el-icon>
            <strong>{{ agent.name }}</strong>
            <span>{{ agent.role }}</span>
            <el-tag :type="agent.status === '完成' ? 'success' : agent.status === '执行' ? 'warning' : 'info'">{{ agent.status }}</el-tag>
            <el-progress :percentage="agent.progress" />
            <ConfidenceGauge :label="`${agent.name} 置信度`" :value="agent.confidence" :color="agent.color" />
            <span v-if="agent.status === '完成'" class="done-badge"><el-icon><Check /></el-icon></span>
          </article>
          <span v-if="index < agents.length - 1" class="pipeline-arrow">→</span>
        </template>
      </div>
    </el-card>

    <el-card shadow="never">
      <template #header>
        <div class="section-title">
          <span>系统 KPI</span>
          <el-button @click="historyVisible = true">查看历史辩论</el-button>
        </div>
      </template>
      <SystemStats />
    </el-card>

    <section class="content-grid two-columns">
      <el-card shadow="never">
        <template #header>Agent 通信日志</template>
        <div class="chat-log">
          <div v-for="item in logs" :key="`${item.time}-${item.from}-${item.text}`" class="chat-bubble">
            <small>{{ item.time }} · {{ item.from }}</small>
            <p>{{ item.text }}</p>
          </div>
        </div>
      </el-card>

      <el-card shadow="never">
        <template #header>审核辩论过程</template>
        <div class="debate-steps">
          <span v-for="(step, index) in debateSteps" :key="step" :class="{ active: index <= activeStep }">{{ step }}</span>
        </div>
        <DebatePanel />
      </el-card>
    </section>

    <el-card v-if="summaryVisible" shadow="never">
      <template #header>协同决策结果汇总</template>
      <div class="metric-grid">
        <div><span>知识盲区</span><strong>{{ summary.blindSpots }}</strong></div>
        <div><span>推荐策略</span><strong>{{ summary.strategy }}</strong></div>
        <div><span>候选分子数</span><strong>{{ summary.molecules }}</strong></div>
        <div><span>资源数</span><strong>{{ summary.resources }}</strong></div>
      </div>
    </el-card>

    <el-drawer v-model="historyVisible" title="Debate History" size="360px">
      <div class="history-list">
        <article v-for="item in debateHistory" :key="item.topic">
          <strong>{{ item.topic }}</strong>
          <span>{{ item.result }} · {{ Math.round(item.confidence * 100) }}%</span>
        </article>
      </div>
    </el-drawer>
  </section>
</template>

