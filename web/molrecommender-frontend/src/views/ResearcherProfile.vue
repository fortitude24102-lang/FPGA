<script setup lang="ts">
import { computed, reactive, ref } from 'vue'
import { useRouter } from 'vue-router'
import { ElMessage } from 'element-plus'
import { Check, Right } from '@element-plus/icons-vue'
import { runPipeline, type ResearcherProfile } from '../utils/api'
import { skillDimensions } from '../utils/mockData'

const router = useRouter()
const submitting = ref(false)

const form = reactive<ResearcherProfile>({
  researcher_id: 'researcher-demo-001',
  name: 'Demo Researcher',
  background: '药物化学',
  experience_years: 2,
  target: 'EGFR',
  research_goal: '提高候选分子选择性并控制 logP',
  constraints: ['pKi > 8', 'logP < 5', '分子量 < 500'],
  skills: {
    化学信息学: 68,
    靶点生物学: 62,
    ADMET预测: 45,
    分子对接: 58,
    'GNN/机器学习': 38,
    合成可及性: 52,
  },
})

const constraints = ['pKi > 8', 'logP < 5', '分子量 < 500', 'hERG IC50 > 10uM', '口服利用度 > 30%', '合成可及性 < 5']

const averageScore = computed(() => Math.round(Object.values(form.skills).reduce((sum, item) => sum + item, 0) / skillDimensions.length))
const grade = computed(() => (averageScore.value >= 80 ? 'A' : averageScore.value >= 60 ? 'B+' : 'C'))

async function submitProfile() {
  submitting.value = true
  try {
    const result = await runPipeline(form)
    sessionStorage.setItem('pipelineResult', JSON.stringify(result))
    ElMessage.success('画像已提交，正在进入 Agent 调度监控')
  } catch (error) {
    sessionStorage.setItem('pipelineResult', JSON.stringify({ status: 'demo', profile: form }))
   // ElMessage.warning(error instanceof Error ? `后端暂不可用，已进入演示流程：${error.message}` : '已进入演示流程')
  } finally {
    sessionStorage.setItem('researcherProfile', JSON.stringify(form))
    submitting.value = false
    router.push('/agent-dashboard')
  }
}
</script>

<template>
  <section class="profile-layout">
    <el-card class="profile-form-card" shadow="never">
      <template #header>
        <div class="section-title">
          <span>研究员基础画像</span>
          <el-tag type="success">/api/v1/pipeline</el-tag>
        </div>
      </template>

      <el-form label-position="top">
        <el-form-item label="研究员姓名">
          <el-input v-model="form.name" />
        </el-form-item>
        <el-form-item label="专业背景">
          <el-select v-model="form.background">
            <el-option label="药物化学" value="药物化学" />
            <el-option label="计算化学" value="计算化学" />
            <el-option label="生物信息学" value="生物信息学" />
          </el-select>
        </el-form-item>
        <el-form-item label="药物设计经验年限">
          <el-input-number v-model="form.experience_years" :min="0" :max="30" />
        </el-form-item>
        <el-form-item label="靶点">
          <el-input v-model="form.target" placeholder="例如 EGFR" />
        </el-form-item>
        <el-form-item label="研究目标">
          <el-select v-model="form.research_goal">
            <el-option label="提高候选分子选择性并控制 logP" value="提高候选分子选择性并控制 logP" />
            <el-option label="优化 ADMET 风险" value="优化 ADMET 风险" />
            <el-option label="降低合成难度" value="降低合成难度" />
            <el-option label="寻找骨架跃迁候选" value="寻找骨架跃迁候选" />
          </el-select>
        </el-form-item>
        <el-form-item label="约束条件">
          <el-checkbox-group v-model="form.constraints" class="constraint-grid">
            <el-checkbox v-for="item in constraints" :key="item" :label="item">
              <span class="check-card"><el-icon><Check /></el-icon>{{ item }}</span>
            </el-checkbox>
          </el-checkbox-group>
        </el-form-item>
      </el-form>
    </el-card>

    <section class="ability-panel">
      <el-card shadow="never">
        <template #header>
          <div class="section-title">
            <span>6 个专业能力维度</span>
            <strong class="rating-number">{{ grade }} · {{ averageScore }}</strong>
          </div>
        </template>
        <div class="ability-grid">
          <label v-for="skill in skillDimensions" :key="skill" class="ability-item">
            <el-progress type="circle" :percentage="form.skills[skill]" :width="92" />
            <span>{{ skill }}</span>
            <el-slider v-model="form.skills[skill]" :min="0" :max="100" />
          </label>
        </div>
      </el-card>
    </section>

    <el-button class="floating-submit" type="primary" :icon="Right" :loading="submitting" @click="submitProfile">
      启动多 Agent 协同分析
    </el-button>
  </section>
</template>
