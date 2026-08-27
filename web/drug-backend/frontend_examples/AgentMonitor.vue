<!-- AgentMonitor.vue - Agent监控页面组件 -->
<template>
  <div class="agent-monitor">
    <h2>🤖 5-Agent 协同监控</h2>

    <!-- Agent状态卡片 -->
    <el-row :gutter="20">
      <el-col :span="4" v-for="agent in agents" :key="agent.id">
        <el-card :class="['agent-card', agent.status]">
          <div class="agent-icon">{{ agent.icon }}</div>
          <div class="agent-name">{{ agent.name }}</div>
          <el-tag :type="agent.status === 'active' ? 'success' : 'danger'">
            {{ agent.status === 'active' ? '运行中' : '离线' }}
          </el-tag>
          <div class="agent-desc">{{ agent.description }}</div>
        </el-card>
      </el-col>
    </el-row>

    <!-- Pipeline执行控制台 -->
    <el-card class="pipeline-console">
      <template #header>
        <span>🚀 Pipeline 执行控制台</span>
      </template>

      <el-form :model="profile" label-width="120px">
        <el-form-item label="研究员姓名">
          <el-input v-model="profile.name" />
        </el-form-item>
        <el-form-item label="所属机构">
          <el-input v-model="profile.institution" />
        </el-form-item>
        <el-form-item label="研究领域">
          <el-select v-model="profile.research_field">
            <el-option label="抗肿瘤药物" value="抗肿瘤药物" />
            <el-option label="抗病毒药物" value="抗病毒药物" />
            <el-option label="抗菌药物" value="抗菌药物" />
            <el-option label="抗炎药物" value="抗炎药物" />
          </el-select>
        </el-form-item>
        <el-form-item label="目标蛋白">
          <el-input v-model="profile.target_protein" />
        </el-form-item>
        <el-form-item label="经验等级">
          <el-radio-group v-model="profile.experience_level">
            <el-radio-button label="初级" />
            <el-radio-button label="中级" />
            <el-radio-button label="高级" />
          </el-radio-group>
        </el-form-item>
        <el-form-item>
          <el-button type="primary" @click="runPipeline" :loading="loading">
            执行 Pipeline
          </el-button>
        </el-form-item>
      </el-form>

      <!-- 执行进度 -->
      <div v-if="pipelineResult" class="pipeline-result">
        <el-divider />
        <h3>执行结果</h3>
        <el-timeline>
          <el-timeline-item
            v-for="(step, key) in pipelineResult.steps"
            :key="key"
            :type="step.status === 'success' ? 'success' : 'danger'"
            :icon="step.status === 'success' ? 'Check' : 'Close'"
          >
            <h4>{{ getAgentName(key) }}</h4>
            <p>状态: {{ step.status }}</p>
            <p v-if="step.status === 'success' && key === 'analyzer'">
              领域: {{ step.result.extracted_needs?.research_domain }}
            </p>
            <p v-if="step.status === 'success' && key === 'generator'">
              生成分子: {{ step.result.total_generated }} 个
            </p>
            <p v-if="step.status === 'success' && key === 'reviewer'">
              通过审核: {{ step.result.statistics?.pass_rate?.toFixed(1) }}%
            </p>
          </el-timeline-item>
        </el-timeline>

        <!-- 摘要 -->
        <el-alert
          v-if="pipelineResult.summary"
          :title="`Pipeline 完成 | 耗时: ${pipelineResult.elapsed_time}s`"
          :type="pipelineResult.pipeline_status === 'completed' ? 'success' : 'warning'"
          :closable="false"
        >
          <p>研究员: {{ pipelineResult.summary.researcher }}</p>
          <p>靶点: {{ pipelineResult.summary.target }}</p>
          <p>策略: {{ pipelineResult.summary.strategy }}</p>
          <p>生成分子: {{ pipelineResult.summary.total_molecules }} | 通过: {{ pipelineResult.summary.passed_molecules }}</p>
        </el-alert>
      </div>
    </el-card>
  </div>
</template>

<script setup>
import { ref, onMounted } from 'vue';

const API_BASE = 'http://localhost:8000';

const agents = ref([]);
const loading = ref(false);
const pipelineResult = ref(null);

const profile = ref({
  name: '张三',
  institution: '某某大学',
  research_field: '抗肿瘤药物',
  target_protein: 'EGFR',
  experience_level: '中级'
});

const agentNames = {
  analyzer: '需求分析Agent',
  planner: '策略规划Agent',
  generator: '分子生成Agent',
  reviewer: '审核裁判Agent',
  learner: '反馈学习Agent'
};

function getAgentName(key) {
  return agentNames[key] || key;
}

async function fetchAgents() {
  try {
    const res = await fetch(`${API_BASE}/api/v1/agents/status`);
    const data = await res.json();
    agents.value = data.data?.agents || [];
  } catch (e) {
    console.error('获取Agent状态失败:', e);
  }
}

async function runPipeline() {
  loading.value = true;
  pipelineResult.value = null;
  try {
    const res = await fetch(`${API_BASE}/api/v1/pipeline`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(profile.value)
    });
    const data = await res.json();
    pipelineResult.value = data.data;
  } catch (e) {
    console.error('Pipeline执行失败:', e);
  } finally {
    loading.value = false;
  }
}

onMounted(fetchAgents);
</script>

<style scoped>
.agent-card {
  text-align: center;
  margin-bottom: 20px;
}
.agent-icon {
  font-size: 48px;
  margin-bottom: 10px;
}
.agent-name {
  font-weight: bold;
  margin-bottom: 10px;
}
.agent-desc {
  font-size: 12px;
  color: #666;
  margin-top: 10px;
}
.pipeline-console {
  margin-top: 30px;
}
.pipeline-result {
  margin-top: 20px;
}
</style>
