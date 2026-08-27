<script setup lang="ts">
import { ref } from 'vue'
import { RecycleScroller } from 'vue-virtual-scroller'
import { wsManager } from '../utils/websocket'

const logs = ref(Array.from({ length: 80 }, (_, index) => ({ id: `thought_${index}`, agent: ['Analyzer', 'Planner', 'Generator', 'Reviewer', 'Learner', 'KG Agent'][index % 6], thought: `第 ${index + 1} 条思维链：记录输入、推理依据、置信度和下一步动作。`, confidence: 70 + (index % 25) })))
wsManager.on('agent_thought', (payload) => logs.value.unshift({ id: `ws_${Date.now()}`, agent: String(payload.agent || 'Agent'), thought: JSON.stringify(payload), confidence: Number(payload.confidence || 80) }))
wsManager.connect()
</script>

<template>
  <section class="stacked-page">
    <el-card shadow="never">
      <template #header><div class="section-title"><span>Agent 思维链监控</span><el-tag>6 Agents</el-tag></div></template>
      <RecycleScroller class="virtual-list" :items="logs" :item-size="72" key-field="id" v-slot="{ item }">
        <div class="virtual-row agent-thought-row"><strong>{{ item.agent }}</strong><span>{{ item.thought }}</span><el-progress :percentage="item.confidence" /></div>
      </RecycleScroller>
    </el-card>
  </section>
</template>
