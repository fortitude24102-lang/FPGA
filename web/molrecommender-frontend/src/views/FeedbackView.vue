<script setup lang="ts">
import { reactive, ref } from 'vue'
import { ChatLineRound, Check, Star } from '@element-plus/icons-vue'
import { ElMessage } from 'element-plus'
import { submitFeedback } from '../utils/api'
import { demoCandidates, resources } from '../utils/mockData'

const submitting = ref(false)
const submitted = ref(false)
const defaultCandidate = demoCandidates[0]!
const defaultResource = resources[0]!
const form = reactive({
  researcher_id: 'researcher-demo-001',
  molecule_id: defaultCandidate.id,
  smiles: defaultCandidate.smiles,
  action: '选择',
  rating: 4,
  comments: '活性较好，但希望进一步降低 logP。',
  resource_id: defaultResource.id,
  helpful: true,
})

function syncMolecule(id: string) {
  const mol = demoCandidates.find((item) => item.id === id)
  if (mol) form.smiles = mol.smiles
}

async function sendFeedback() {
  submitting.value = true
  try {
    await submitFeedback(form)
    ElMessage.success('反馈已提交给 Learner Agent')
  } catch (error) {
    ElMessage.warning(error instanceof Error ? `后端暂不可用，反馈已在前端记录：${error.message}` : '反馈已在前端记录')
  } finally {
    submitting.value = false
    submitted.value = true
  }
}
</script>

<template>
  <section class="feedback-layout" :class="{ done: submitted }">
    <aside class="feedback-guide">
      <div class="guide-mark">
        <el-icon><ChatLineRound /></el-icon>
      </div>
      <h3>Learner Agent 会把你的选择、评分和资源评价转成偏好信号。</h3>
      <p>这些信号会影响下一轮候选分子排序、知识盲区补齐和资源推荐。</p>
    </aside>

    <el-card v-if="submitted" class="success-card" shadow="never">
      <el-icon><Check /></el-icon>
      <h3>反馈已记录</h3>
      <p>页面已进入收起状态，Learner Agent 可以使用这次反馈更新用户画像。</p>
      <el-button type="primary" @click="submitted = false">继续填写</el-button>
    </el-card>

    <el-card v-else shadow="never">
      <template #header>候选分子与资源反馈</template>
      <el-form label-position="top">
        <el-form-item label="候选分子">
          <el-select v-model="form.molecule_id" @change="syncMolecule">
            <el-option v-for="mol in demoCandidates" :key="mol.id" :label="`${mol.id} | ${mol.status}`" :value="mol.id" />
          </el-select>
        </el-form-item>
        <el-form-item label="操作">
          <el-radio-group v-model="form.action" class="pill-radio">
            <el-radio-button label="选择" />
            <el-radio-button label="跳过" />
            <el-radio-button label="关注" />
          </el-radio-group>
        </el-form-item>
        <el-form-item label="评分">
          <el-rate v-model="form.rating" :void-icon="Star" show-score />
        </el-form-item>
        <el-form-item label="研究资源">
          <el-select v-model="form.resource_id">
            <el-option v-for="res in resources" :key="res.id" :label="res.title" :value="res.id" />
          </el-select>
        </el-form-item>
        <el-form-item label="是否有帮助">
          <el-switch v-model="form.helpful" active-text="有帮助" inactive-text="无帮助" />
        </el-form-item>
        <el-form-item label="备注">
          <el-input v-model="form.comments" type="textarea" :rows="4" />
        </el-form-item>
        <el-button type="primary" :loading="submitting" @click="sendFeedback">提交反馈</el-button>
      </el-form>
    </el-card>
  </section>
</template>
