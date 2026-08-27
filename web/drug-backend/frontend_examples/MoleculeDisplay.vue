<!-- MoleculeDisplay.vue - 分子展示页面组件 -->
<template>
  <div class="molecule-display">
    <h2>🧬 分子展示与评估</h2>

    <!-- 分子列表 -->
    <el-card v-if="molecules.length">
      <template #header>
        <span>候选分子列表 ({{ molecules.length }}个)</span>
      </template>

      <el-table :data="molecules" stripe>
        <el-table-column type="index" width="50" />
        <el-table-column prop="id" label="ID" width="180" />
        <el-table-column prop="smiles" label="SMILES" min-width="200">
          <template #default="scope">
            <el-tooltip :content="scope.row.smiles" placement="top">
              <span class="smiles-text">{{ scope.row.smiles }}</span>
            </el-tooltip>
          </template>
        </el-table-column>
        <el-table-column prop="properties.molwt" label="分子量" width="100" sortable />
        <el-table-column prop="properties.logp" label="LogP" width="80" sortable />
        <el-table-column prop="properties.qed" label="QED" width="100" sortable>
          <template #default="scope">
            <el-progress 
              :percentage="scope.row.properties.qed * 100" 
              :color="qedColor"
              :show-text="false"
              style="width: 60px"
            />
            <span class="qed-value">{{ scope.row.properties.qed.toFixed(3) }}</span>
          </template>
        </el-table-column>
        <el-table-column prop="properties.lipinski_pass" label="Lipinski" width="100">
          <template #default="scope">
            <el-tag :type="scope.row.properties.lipinski_pass ? 'success' : 'danger'">
              {{ scope.row.properties.lipinski_pass ? '✅通过' : '❌不通过' }}
            </el-tag>
          </template>
        </el-table-column>
        <el-table-column label="操作" width="150">
          <template #default="scope">
            <el-button size="small" @click="showDetails(scope.row)">详情</el-button>
            <el-button size="small" type="primary" @click="openFeedback(scope.row)">反馈</el-button>
          </template>
        </el-table-column>
      </el-table>
    </el-card>

    <!-- 评分详情弹窗 -->
    <el-dialog v-model="detailVisible" title="分子详情" width="600px">
      <div v-if="selectedMolecule">
        <p><strong>ID:</strong> {{ selectedMolecule.id }}</p>
        <p><strong>SMILES:</strong> <code>{{ selectedMolecule.smiles }}</code></p>

        <el-divider />
        <h4>分子性质</h4>
        <el-descriptions :column="2" border>
          <el-descriptions-item label="分子量">{{ selectedMolecule.properties?.molwt }}</el-descriptions-item>
          <el-descriptions-item label="LogP">{{ selectedMolecule.properties?.logp }}</el-descriptions-item>
          <el-descriptions-item label="TPSA">{{ selectedMolecule.properties?.tpsa }}</el-descriptions-item>
          <el-descriptions-item label="HBD">{{ selectedMolecule.properties?.hbd }}</el-descriptions-item>
          <el-descriptions-item label="HBA">{{ selectedMolecule.properties?.hba }}</el-descriptions-item>
          <el-descriptions-item label="可旋转键">{{ selectedMolecule.properties?.rotatable_bonds }}</el-descriptions-item>
          <el-descriptions-item label="QED">{{ selectedMolecule.properties?.qed }}</el-descriptions-item>
          <el-descriptions-item label="SA Score">{{ selectedMolecule.properties?.sa_score }}</el-descriptions-item>
        </el-descriptions>

        <el-divider />
        <h4>评分详情</h4>
        <div v-if="selectedMolecule.score_breakdown">
          <div v-for="(score, key) in selectedMolecule.score_breakdown" :key="key" class="score-item">
            <span class="score-label">{{ scoreLabels[key] || key }}:</span>
            <el-progress :percentage="score" :color="getScoreColor(score)" />
          </div>
          <div class="total-score">
            <strong>总分: {{ selectedMolecule.total_score?.toFixed(1) }}</strong>
            <el-tag :type="selectedMolecule.verdict === 'PASS' ? 'success' : 'danger'">
              {{ selectedMolecule.verdict }}
            </el-tag>
          </div>
        </div>
      </div>
    </el-dialog>

    <!-- 反馈弹窗 -->
    <el-dialog v-model="feedbackVisible" title="分子反馈" width="500px">
      <el-form :model="feedbackForm">
        <el-form-item label="分子ID">
          <el-input v-model="feedbackForm.molecule_id" disabled />
        </el-form-item>
        <el-form-item label="评分">
          <el-rate v-model="feedbackForm.rating" :max="5" show-score />
        </el-form-item>
        <el-form-item label="评论">
          <el-input v-model="feedbackForm.comments" type="textarea" rows="3" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="feedbackVisible = false">取消</el-button>
        <el-button type="primary" @click="submitFeedback">提交</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<script setup>
import { ref } from 'vue';

const API_BASE = 'http://localhost:8000';

const props = defineProps({
  molecules: {
    type: Array,
    default: () => []
  }
});

const detailVisible = ref(false);
const feedbackVisible = ref(false);
const selectedMolecule = ref(null);

const feedbackForm = ref({
  molecule_id: '',
  smiles: '',
  rating: 3,
  comments: '',
  researcher_id: 'user_001',
  target_protein: '',
  properties: {}
});

const scoreLabels = {
  lipinski: 'Lipinski规则',
  qed: '药物相似性(QED)',
  sa_score: '合成可及性',
  mw: '分子量',
  logp: '脂溶性(LogP)',
  tpsa: '极性表面积(TPSA)'
};

const qedColor = [
  { color: '#f56c6c', percentage: 20 },
  { color: '#e6a23c', percentage: 40 },
  { color: '#5cb87a', percentage: 60 },
  { color: '#1989fa', percentage: 80 },
  { color: '#6f7ad3', percentage: 100 }
];

function getScoreColor(score) {
  if (score >= 80) return '#67c23a';
  if (score >= 60) return '#e6a23c';
  return '#f56c6c';
}

function showDetails(molecule) {
  selectedMolecule.value = molecule;
  detailVisible.value = true;
}

function openFeedback(molecule) {
  feedbackForm.value = {
    molecule_id: molecule.id,
    smiles: molecule.smiles,
    rating: 3,
    comments: '',
    researcher_id: 'user_001',
    target_protein: molecule.target || '',
    properties: molecule.properties || {}
  };
  feedbackVisible.value = true;
}

async function submitFeedback() {
  try {
    const res = await fetch(`${API_BASE}/api/v1/feedback`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(feedbackForm.value)
    });
    const data = await res.json();
    if (data.status === 'success') {
      ElMessage.success('反馈提交成功！');
      feedbackVisible.value = false;
    }
  } catch (e) {
    ElMessage.error('提交失败: ' + e.message);
  }
}
</script>

<style scoped>
.smiles-text {
  font-family: monospace;
  font-size: 12px;
  color: #409eff;
}
.qed-value {
  margin-left: 8px;
  font-size: 12px;
}
.score-item {
  display: flex;
  align-items: center;
  margin-bottom: 10px;
}
.score-label {
  width: 120px;
  flex-shrink: 0;
}
.total-score {
  margin-top: 20px;
  padding: 15px;
  background: #f5f7fa;
  border-radius: 4px;
  display: flex;
  justify-content: space-between;
  align-items: center;
}
</style>
