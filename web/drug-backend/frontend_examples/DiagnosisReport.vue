<!-- DiagnosisReport.vue - 诊断报告页面组件 -->
<template>
  <div class="diagnosis-report">
    <h2>📋 药物设计诊断报告</h2>

    <!-- 策略概览 -->
    <el-card v-if="strategy" class="strategy-card">
      <template #header>
        <span>🎯 设计策略概览</span>
      </template>
      <el-descriptions :column="2" border>
        <el-descriptions-item label="设计方法">{{ strategy.approach }}</el-descriptions-item>
        <el-descriptions-item label="目标靶点">{{ strategy.target_focus }}</el-descriptions-item>
        <el-descriptions-item label="复杂度">{{ strategy.complexity_level }}</el-descriptions-item>
        <el-descriptions-item label="预计时间">{{ strategy.estimated_duration }}</el-descriptions-item>
      </el-descriptions>
    </el-card>

    <!-- 设计步骤时间线 -->
    <el-card v-if="designSteps.length" class="steps-card">
      <template #header>
        <span>📌 设计步骤</span>
      </template>
      <el-timeline>
        <el-timeline-item
          v-for="step in designSteps"
          :key="step.step_id"
          :type="step.step_id <= completedStep ? 'success' : ''"
          :icon="step.step_id <= completedStep ? 'Check' : ''"
        >
          <el-card :class="['step-card', step.step_id <= completedStep ? 'completed' : '']">
            <template #header>
              <div class="step-header">
                <span class="step-number">Step {{ step.step_id }}</span>
                <span class="step-name">{{ step.name }}</span>
                <el-tag size="small">{{ step.duration }}</el-tag>
              </div>
            </template>
            <p>{{ step.description }}</p>
            <div class="step-tools">
              <el-tag v-for="tool in step.tools" :key="tool" size="small" type="info">
                {{ tool }}
              </el-tag>
            </div>
            <p class="step-output"><strong>输出:</strong> {{ step.output }}</p>
            <p v-if="step.field_notes" class="field-notes">
              <el-icon><Info-Filled /></el-icon>
              {{ step.field_notes }}
            </p>
          </el-card>
        </el-timeline-item>
      </el-timeline>
    </el-card>

    <!-- 时间线概览 -->
    <el-card v-if="timeline" class="timeline-card">
      <template #header>
        <span>⏱️ 项目时间线</span>
      </template>
      <el-steps :active="completedPhase" finish-status="success">
        <el-step 
          v-for="phase in timeline.milestones" 
          :key="phase.phase"
          :title="phase.phase"
          :description="phase.duration"
        />
      </el-steps>
      <div class="timeline-summary">
        <p><strong>总步骤:</strong> {{ timeline.total_steps }}</p>
        <p><strong>预计总时长:</strong> {{ timeline.estimated_days }}</p>
      </div>
    </el-card>

    <!-- 资源需求 -->
    <el-card v-if="resources" class="resources-card">
      <template #header>
        <span>🔧 资源需求</span>
      </template>
      <el-row :gutter="20">
        <el-col :span="8">
          <h4>💻 计算资源</h4>
          <el-tag v-for="item in resources.computational" :key="item" class="resource-tag">
            {{ item }}
          </el-tag>
        </el-col>
        <el-col :span="8">
          <h4>🗄️ 数据库</h4>
          <el-tag v-for="item in resources.databases" :key="item" class="resource-tag" type="success">
            {{ item }}
          </el-tag>
        </el-col>
        <el-col :span="8">
          <h4>⚡ 硬件</h4>
          <el-tag v-for="item in resources.hardware" :key="item" class="resource-tag" type="warning">
            {{ item }}
          </el-tag>
        </el-col>
      </el-row>
    </el-card>

    <!-- 推荐库和方法 -->
    <el-card v-if="recommendations" class="recommendations-card">
      <template #header>
        <span>💡 智能推荐</span>
      </template>
      <el-row :gutter="20">
        <el-col :span="12">
          <h4>📚 推荐化合物库</h4>
          <el-list>
            <el-list-item v-for="lib in recommendations.suggested_libraries" :key="lib">
              <el-icon><Collection /></el-icon>
              {{ lib }}
            </el-list-item>
          </el-list>
        </el-col>
        <el-col :span="12">
          <h4>🔬 推荐设计方法</h4>
          <el-list>
            <el-list-item v-for="method in recommendations.suggested_methods" :key="method">
              <el-icon><Set-Up /></el-icon>
              {{ method }}
            </el-list-item>
          </el-list>
        </el-col>
      </el-row>
    </el-card>
  </div>
</template>

<script setup>
import { computed } from 'vue';

const props = defineProps({
  plannerResult: {
    type: Object,
    default: () => ({})
  },
  analyzerResult: {
    type: Object,
    default: () => ({})
  }
});

const strategy = computed(() => props.plannerResult?.strategy_overview || {});
const designSteps = computed(() => props.plannerResult?.design_steps || []);
const timeline = computed(() => props.plannerResult?.timeline || {});
const resources = computed(() => props.plannerResult?.resources || {});
const recommendations = computed(() => props.analyzerResult?.recommendations || {});

const completedStep = computed(() => {
  // 模拟已完成步骤，实际应从后端状态获取
  return 2;
});

const completedPhase = computed(() => {
  return 1;
});
</script>

<style scoped>
.strategy-card, .steps-card, .timeline-card, .resources-card, .recommendations-card {
  margin-bottom: 20px;
}
.step-card {
  margin-bottom: 10px;
}
.step-card.completed {
  border-left: 4px solid #67c23a;
}
.step-header {
  display: flex;
  align-items: center;
  gap: 15px;
}
.step-number {
  background: #409eff;
  color: white;
  padding: 2px 10px;
  border-radius: 12px;
  font-size: 12px;
}
.step-name {
  font-weight: bold;
  flex: 1;
}
.step-tools {
  margin: 10px 0;
}
.step-tools .el-tag {
  margin-right: 8px;
  margin-bottom: 5px;
}
.step-output {
  color: #606266;
  font-size: 13px;
}
.field-notes {
  color: #e6a23c;
  font-size: 12px;
  margin-top: 8px;
}
.timeline-summary {
  margin-top: 20px;
  padding: 15px;
  background: #f5f7fa;
  border-radius: 4px;
}
.resource-tag {
  margin-right: 8px;
  margin-bottom: 8px;
}
</style>
