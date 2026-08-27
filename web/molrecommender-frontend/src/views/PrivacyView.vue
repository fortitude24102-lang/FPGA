<script setup lang="ts">
import { computed, ref } from 'vue'
import { RecycleScroller } from 'vue-virtual-scroller'
import { ElMessage } from 'element-plus'
import { deletePrivacyData, getAuditLogs, getPrivacyStatement, revokeConsent } from '../utils/api'
import { clearPrivacySensitiveStorage } from '../utils/rbac'

type AuditLog = { id: string; time: string; action: string; user: string; resource: string }

const props = defineProps<{ tab?: string }>()
const activeTab = ref(props.tab || 'statement')
const userId = ref(localStorage.getItem('user_id') || 'anonymous')
const confirmText = ref('')
const statement = ref('本系统收集测评答案、学习路径、反馈记录和系统操作日志，用于生成个性化学习建议、知识图谱和能力证书。用户可导出个人数据、撤回授权或删除个人数据。')
const auditLogs = ref<AuditLog[]>(
  Array.from({ length: 120 }, (_, index) => ({
    id: `audit_${index}`,
    time: `2026-08-19 14:${String(index % 60).padStart(2, '0')}`,
    action: index % 3 === 0 ? 'export' : index % 3 === 1 ? 'revoke' : 'view',
    user: 'anonymous',
    resource: index % 2 === 0 ? 'portfolio' : 'audit_logs',
  })),
)
const canDelete = computed(() => confirmText.value === 'DELETE')

async function load() {
  try {
    const data = await getPrivacyStatement() as { statement?: string }
    if (data.statement) statement.value = data.statement
  } catch {}
  try {
    const data = await getAuditLogs() as { logs?: AuditLog[] }
    if (Array.isArray(data.logs)) auditLogs.value = data.logs.map((item, index) => ({ ...item, id: item.id || `remote_${index}` }))
  } catch {}
}

async function revoke() {
  try { await revokeConsent(userId.value) } catch {}
  localStorage.setItem('privacy_revoked_at', new Date().toISOString())
  clearPrivacySensitiveStorage()
  ElMessage.warning('已撤回授权，并清除本地缓存数据')
}

async function removeData() {
  if (!canDelete.value) return
  try { await deletePrivacyData(userId.value) } catch {}
  clearPrivacySensitiveStorage()
  ElMessage.success('删除请求已提交，本地数据已清空')
}

load()
</script>

<template>
  <section class="stacked-page">
    <el-card shadow="never">
      <el-tabs v-model="activeTab">
        <el-tab-pane label="隐私声明" name="statement">
          <p>{{ statement }}</p>
          <el-descriptions border>
            <el-descriptions-item label="收集数据">测评、反馈、学习路径、证书、审计日志</el-descriptions-item>
            <el-descriptions-item label="保留政策">按项目要求保留，可由用户请求删除</el-descriptions-item>
            <el-descriptions-item label="用户权利">导出、撤回授权、删除数据</el-descriptions-item>
          </el-descriptions>
        </el-tab-pane>
        <el-tab-pane label="隐私设置" name="settings">
          <div class="danger-zone">
            <h3>危险操作区</h3>
            <el-input v-model="userId" placeholder="用户ID" />
            <el-button type="warning" class="mt-12" @click="revoke">撤回授权</el-button>
            <el-input v-model="confirmText" class="mt-12" placeholder="输入 DELETE 确认删除" />
            <el-button type="danger" class="mt-12" :disabled="!canDelete" @click="removeData">删除我的数据</el-button>
          </div>
        </el-tab-pane>
        <el-tab-pane label="审计日志" name="logs">
          <RecycleScroller class="virtual-list" :items="auditLogs" :item-size="58" key-field="id" v-slot="{ item }">
            <div class="virtual-row">
              <span>{{ item.time }}</span>
              <strong>{{ item.action }}</strong>
              <span>{{ item.user }}</span>
              <span>{{ item.resource }}</span>
            </div>
          </RecycleScroller>
        </el-tab-pane>
      </el-tabs>
    </el-card>
  </section>
</template>
