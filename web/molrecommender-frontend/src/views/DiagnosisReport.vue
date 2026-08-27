<script setup lang="ts">
import * as echarts from 'echarts'
import { onBeforeUnmount, onMounted, ref } from 'vue'
import { ChatDotRound } from '@element-plus/icons-vue'
import { skillDimensions } from '../utils/mockData'
import { getProfileRadar, type LlmAnalysis, type ProfileRadarData, type RadarDimension } from '../utils/api'

const chartRef = ref<HTMLDivElement | null>(null)
let chart: echarts.ECharts | null = null

const loading = ref(false)
const scores = ref([68, 62, 45, 58, 38, 52])
const llmAnalysis = ref<LlmAnalysis | null>(null)
const blindSpots = [
  { name: 'GNN/机器学习', level: '高', advice: '先掌握分子图表示、训练/验证集划分和过拟合识别。' },
  { name: 'ADMET预测', level: '中', advice: '重点补齐 logP、hERG、溶解度和口服利用度规则。' },
  { name: '合成可及性', level: '中', advice: '学习常见保护基、反应可行性和片段替换策略。' },
]
const researchPath = [
  { title: '补齐 ADMET 基础规则', tag: '今天', detail: '建立 logP、TPSA、hERG 的判断框架。' },
  { title: '完成 EGFR 对接案例', tag: '本周', detail: '用一个标准案例贯通准备、对接和复核。' },
  { title: '学习 GNN 评分解释', tag: '下周', detail: '理解图特征、置信度和可解释性证据。' },
  { title: '复核合成风险', tag: '持续', detail: '把高风险片段放入 Reviewer 检查清单。' },
]

function unwrapRadar(raw: ProfileRadarData | RadarDimension[] | { status?: string; data?: ProfileRadarData }) {
  if (Array.isArray(raw)) return { dimensions: raw, llm_analysis: null }
  if ('data' in raw && raw.data) return raw.data
  return raw as ProfileRadarData
}

function applyRadarData(data: ProfileRadarData) {
  if (Array.isArray(data.dimensions) && data.dimensions.length) {
    scores.value = skillDimensions.map((name) => data.dimensions.find((item) => item.name === name)?.score ?? 0)
  }
  llmAnalysis.value = data.llm_analysis ?? null
}

function renderChart() {
  if (!chartRef.value) return
  chart?.dispose()
  chart = echarts.init(chartRef.value)
  chart.setOption({
    color: ['#2D6A5F'],
    tooltip: {},
    radar: {
      indicator: skillDimensions.map((name) => ({ name, max: 100 })),
      radius: 128,
      splitLine: { lineStyle: { color: '#DDE8E5' } },
      splitArea: { areaStyle: { color: ['#F8FAF9', '#EEF6F4'] } },
      axisLine: { lineStyle: { color: '#C8DAD5' } },
    },
    series: [
      {
        type: 'radar',
        animationDuration: 900,
        animationEasing: 'cubicOut',
        data: [
          {
            value: scores.value,
            name: '能力评分',
            areaStyle: { color: 'rgba(74, 144, 133, 0.24)' },
            lineStyle: { width: 3 },
          },
        ],
      },
    ],
  })
}

async function fetchRadar() {
  loading.value = true
  try {
    const raw = await getProfileRadar('researcher-demo-001')
    applyRadarData(unwrapRadar(raw) as ProfileRadarData)
  } catch {
    llmAnalysis.value = null
  } finally {
    loading.value = false
    renderChart()
  }
}

onMounted(fetchRadar)
onBeforeUnmount(() => chart?.dispose())
</script>

<template>
  <section class="content-grid two-columns">
    <el-card shadow="never">
      <template #header>药物研发能力雷达图</template>
      <el-skeleton v-if="loading" :rows="6" animated />
      <div v-show="!loading" ref="chartRef" class="chart-box radar-large" />

      <el-card v-if="llmAnalysis" class="llm-analysis-card" shadow="never">
        <template #header>
          <div class="card-header">
            <el-icon><ChatDotRound /></el-icon>
            <span>AI 智能学情分析</span>
            <el-tag size="small" type="success">LLM 生成</el-tag>
          </div>
        </template>

        <div class="analysis-content">
          <p class="analysis-text">{{ llmAnalysis.analysis }}</p>

          <div v-if="llmAnalysis.knowledge_gaps?.length" class="gaps-section">
            <h4>知识盲区</h4>
            <el-tag v-for="gap in llmAnalysis.knowledge_gaps" :key="gap" type="danger" effect="dark" class="gap-tag">
              {{ gap }}
            </el-tag>
          </div>

          <div v-if="llmAnalysis.recommendations?.length" class="recommend-section">
            <h4>AI 推荐</h4>
            <el-timeline>
              <el-timeline-item
                v-for="(rec, idx) in llmAnalysis.recommendations"
                :key="rec"
                :type="idx === 0 ? 'primary' : 'info'"
              >
                {{ rec }}
              </el-timeline-item>
            </el-timeline>
          </div>
        </div>
      </el-card>

      <el-alert
        v-else-if="!loading"
        class="mt-12"
        title="AI 分析未启用"
        type="info"
        :closable="false"
        description="后端未配置 LLM_API_KEY，学情分析使用基础规则生成。"
      />
    </el-card>

    <el-card shadow="never">
      <template #header>知识盲区诊断</template>
      <div class="risk-stack">
        <article class="blind-card risk-card" v-for="item in blindSpots" :key="item.name">
          <div>
            <strong>{{ item.name }}</strong>
            <p>{{ item.advice }}</p>
          </div>
          <el-tag :type="item.level === '高' ? 'danger' : 'warning'">{{ item.level }}风险</el-tag>
        </article>
      </div>
    </el-card>

    <el-card class="full-span" shadow="never">
      <template #header>研究路径规划</template>
      <div class="learning-path">
        <article v-for="item in researchPath" :key="item.title">
          <em>{{ item.tag }}</em>
          <strong>{{ item.title }}</strong>
          <p>{{ item.detail }}</p>
        </article>
      </div>
    </el-card>
  </section>
</template>
