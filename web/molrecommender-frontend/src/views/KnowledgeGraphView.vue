<script setup lang="ts">
import { nextTick, onBeforeUnmount, ref } from 'vue'
import { getKnowledgeGraph, getPropagationRecommend, inferKnowledgeGraph } from '../utils/api'
import { throttle } from '../utils/performance'

const userId = ref('anonymous')
const selected = ref('Lipinski五规则')
const graphRef = ref<HTMLElement | null>(null)
let graph: { destroy?: () => void; render?: () => void } | null = null
const nodes = ref([
  { label: 'SMILES', mastered: true, score: 92 },
  { label: '分子描述符', mastered: true, score: 84 },
  { label: 'Lipinski五规则', mastered: false, score: 55 },
  { label: 'ADMET', mastered: false, score: 58 },
  { label: '分子对接', mastered: false, score: 60 },
  { label: '靶点生物学', mastered: true, score: 78 },
  { label: '合成路线', mastered: false, score: 45 },
  { label: '专利法规', mastered: true, score: 90 },
  { label: '知识传播', mastered: false, score: 52 },
])
const recommendations = ref([
  { label: 'Lipinski五规则', category: 'ADMET', activation_score: 1.25, propagation_path: 'SMILES --[用于计算]--> 分子描述符 --[支撑评估]--> Lipinski五规则' },
  { label: '分子对接', category: '结构生物学', activation_score: 0.8, propagation_path: '分子描述符 --[直接输入]--> 分子对接' },
])
const inference = ref<Record<string, unknown> | null>(null)
async function renderG6Graph() {
  if (!graphRef.value) return
  try {
    const mod = await import('@antv/g6') as any
    graph?.destroy?.()
    const nextGraph = new mod.Graph({
      container: graphRef.value,
      width: graphRef.value.clientWidth || 720,
      height: 420,
      data: {
        nodes: nodes.value.map((node, index) => ({ id: String(index), data: node, style: { labelText: node.label, size: 34 + node.score / 3, fill: node.mastered ? '#DDEFE4' : '#EEF1EF', stroke: node.mastered ? '#5B9A6D' : '#AAB5B1' } })),
        edges: nodes.value.slice(1).map((node, index) => ({ source: String(index), target: String(index + 1), style: { labelText: index % 2 ? '支撑' : '传播' } })),
      },
      layout: { type: 'force', preventOverlap: true, linkDistance: 110 },
      behaviors: ['drag-canvas', 'zoom-canvas', 'drag-element'],
    })
    nextGraph.render?.()
    graph = nextGraph
  } catch {
    graph = null
  }
}

const resizeGraph = throttle(() => renderG6Graph(), 200)

async function loadRemote() {
  try {
    const graph = await getKnowledgeGraph(userId.value) as any
    if (Array.isArray(graph.nodes)) nodes.value = graph.nodes
  } catch {}
  try {
    const data = await getPropagationRecommend(userId.value) as any
    if (Array.isArray(data.recommendations)) recommendations.value = data.recommendations
  } catch {}
}

async function infer() {
  try {
    inference.value = await inferKnowledgeGraph(userId.value)
  } catch {
    inference.value = { inferred_relations: ['SMILES -> ADMET', '描述符 -> 对接风险'], knowledge_gaps: ['ADMET', '合成路线'], propagation_recommendations: recommendations.value.map((item) => item.label) }
  }
}

loadRemote().then(() => nextTick(renderG6Graph))
window.addEventListener('resize', resizeGraph)
onBeforeUnmount(() => {
  window.removeEventListener('resize', resizeGraph)
  graph?.destroy?.()
})
</script>

<template>
  <section class="graph-layout">
    <el-card shadow="never">
      <template #header><div class="section-title"><span>知识图谱</span><el-button type="primary" @click="infer">图谱推理</el-button></div></template>
      <div ref="graphRef" class="g6-graph" aria-label="G6 力导向知识图谱"></div>
      <div class="graph-canvas mobile-graph" aria-label="9个知识点节点图">
        <button v-for="node in nodes" :key="node.label" :class="{ mastered: node.mastered }" :style="{ width: `${70 + node.score / 2}px`, height: `${70 + node.score / 2}px` }" @click="selected = node.label">
          <strong>{{ node.mastered ? '✓' : '!' }}</strong><span>{{ node.label }}</span>
        </button>
      </div>
      <p>当前节点：{{ selected }}。绿色表示已掌握，灰色表示待补强，节点大小随得分变化。</p>
    </el-card>
    <el-card shadow="never">
      <template #header><div class="section-title"><span>传播推荐</span><el-tag>{{ recommendations.length }} 条</el-tag></div></template>
      <article v-for="item in recommendations" :key="item.label" class="recommend-card">
        <strong>{{ item.label }} · {{ item.category }}</strong>
        <el-progress :percentage="Math.round(item.activation_score * 60)" />
        <p>{{ item.propagation_path }}</p>
      </article>
      <div v-if="inference" class="verdict-box mt-12"><strong>推理结果</strong><pre>{{ inference }}</pre></div>
    </el-card>
  </section>
</template>



