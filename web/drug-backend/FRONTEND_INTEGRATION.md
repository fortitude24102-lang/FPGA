# 前端联调接口文档

## 服务信息

| 项目 | 内容 |
|------|------|
| 服务地址 | `http://localhost:8000` |
| API文档 | `http://localhost:8000/docs` (Swagger UI) |
| CORS | 已开启，支持所有来源 |

## 核心接口：执行Pipeline

### POST /api/v1/pipeline

这是**比赛演示的核心接口**，一次性走完5-Agent全流程。

#### 请求体 (Request Body)

```json
{
  "name": "张三",
  "institution": "某某大学",
  "research_field": "抗肿瘤药物",
  "target_protein": "EGFR",
  "experience_level": "中级"
}
```

#### 字段说明

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| name | string | 否 | 研究员姓名 |
| institution | string | 否 | 所属机构 |
| research_field | string | 否 | 研究领域 |
| target_protein | string | 否 | 目标蛋白 |
| experience_level | string | 否 | 经验等级(初级/中级/高级) |

#### 响应示例

```json
{
  "status": "success",
  "pipeline_status": "completed",
  "elapsed_time": 1.23,
  "data": {
    "steps": {
      "analyzer": {
        "status": "success",
        "result": {
          "agent": "需求分析Agent",
          "profile_summary": {
            "researcher": "张三",
            "institution": "某某大学",
            "field": "抗肿瘤药物",
            "target": "EGFR",
            "level": "中级"
          },
          "extracted_needs": {
            "research_domain": "抗肿瘤",
            "recommended_targets": ["EGFR", "HER2", "VEGF"],
            "design_complexity": {"max_steps": 5, "detail_level": "标准"},
            "requirement_summary": "研究员张三专注于抗肿瘤领域..."
          },
          "recommendations": {
            "suggested_libraries": ["ZINC抗肿瘤子集", "ChEMBL激酶抑制剂库"],
            "suggested_methods": ["基于结构的药物设计", "分子对接"],
            "priority": "high"
          }
        }
      },
      "planner": {
        "status": "success",
        "result": {
          "agent": "策略规划Agent",
          "strategy_overview": {
            "approach": "基于结构的药物设计",
            "target_focus": "EGFR",
            "complexity_level": "标准",
            "estimated_duration": "2-4周"
          },
          "design_steps": [
            {"step_id": 1, "name": "靶点验证", "duration": "2-3天", ...},
            {"step_id": 2, "name": "化合物库准备", "duration": "1-2天", ...},
            ...
          ],
          "timeline": {...},
          "resources": {...}
        }
      },
      "generator": {
        "status": "success",
        "result": {
          "agent": "分子生成Agent",
          "target": "EGFR",
          "total_generated": 5,
          "generated_molecules": [
            {
              "id": "variant_of_阿司匹林",
              "smiles": "CC(=O)Oc1ccccc1C(=O)O",
              "properties": {
                "molwt": 180.16,
                "logp": 1.19,
                "tpsa": 63.6,
                "hbd": 1,
                "hba": 3,
                "rotatable_bonds": 3,
                "qed": 0.596,
                "sa_score": 1.82,
                "lipinski_pass": true,
                "lipinski_violations": 0
              },
              "fingerprint": "101010..."
            },
            ...
          ],
          "statistics": {
            "avg_molwt": 350.5,
            "avg_logp": 2.1,
            "avg_qed": 0.65,
            "pass_lipinski": 4
          }
        }
      },
      "reviewer": {
        "status": "success",
        "result": {
          "agent": "审核裁判Agent",
          "total_reviewed": 5,
          "scoring_details": [
            {
              "id": "variant_of_阿司匹林",
              "smiles": "CC(=O)Oc1ccccc1C(=O)O",
              "total_score": 85.5,
              "breakdown": {
                "lipinski": 100,
                "qed": 59.6,
                "sa_score": 72.7,
                "mw": 100,
                "logp": 100,
                "tpsa": 100
              },
              "verdict": "PASS",
              "reasons": ["优秀的药物相似性", "合成可及性良好"]
            },
            ...
          ],
          "filtered_molecules": [...],
          "rejected_molecules": [...],
          "top_candidates": [...],
          "statistics": {
            "pass_rate": 0.8,
            "avg_score": 72.5,
            "best_score": 85.5,
            "worst_score": 45.2
          }
        }
      },
      "learner": {
        "status": "success",
        "result": {
          "message": "Pipeline执行完成",
          "top_candidates_count": 4,
          "candidates": [
            {"id": "variant_of_阿司匹林", "smiles": "...", "score": 85.5},
            ...
          ]
        }
      }
    },
    "summary": {
      "researcher": "张三",
      "target": "EGFR",
      "strategy": "基于结构的药物设计",
      "total_molecules": 5,
      "passed_molecules": 4,
      "top_candidate": {
        "id": "variant_of_阿司匹林",
        "smiles": "CC(=O)Oc1ccccc1C(=O)O",
        "score": 85.5
      }
    },
    "pipeline_status": "completed",
    "elapsed_time": 1.23,
    "total_steps": 5,
    "successful_steps": 5,
    "errors": []
  }
}
```

## 前端页面数据映射

### 1. 画像录入页面
- **调用**: `POST /api/v1/pipeline`
- **发送**: 研究员画像表单数据
- **接收**: 整个pipeline结果，提取 `data.steps.analyzer.result` 展示需求分析

### 2. Agent监控页面
- **调用**: `GET /api/v1/agents/status`
- **展示**: 5个Agent的状态卡片
- **实时**: 可轮询pipeline执行进度

### 3. 诊断报告页面
- **数据来源**: `data.steps.planner.result`
- **展示**: 设计策略、步骤列表、时间线、资源需求

### 4. 分子展示页面
- **数据来源**: `data.steps.generator.result.generated_molecules`
- **展示**: 分子SMILES、分子量、LogP、QED等性质
- **数据来源2**: `data.steps.reviewer.result.top_candidates`
- **展示**: 评分排名、通过/不通过状态

### 5. 资源推荐页面
- **数据来源**: `data.steps.analyzer.result.recommendations`
- **展示**: 推荐化合物库、推荐设计方法

### 6. 反馈交互页面
- **调用**: `POST /api/v1/feedback`
- **发送**: 用户对分子的评分和评论
- **调用2**: `GET /api/v1/feedback/recommendations`
- **接收**: 基于历史反馈的优化建议

## Vue3 调用示例

```javascript
// api.js - 封装API调用
const API_BASE = 'http://localhost:8000';

export const api = {
  // 执行完整Pipeline
  async runPipeline(profile) {
    const res = await fetch(`${API_BASE}/api/v1/pipeline`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(profile)
    });
    return res.json();
  },

  // 获取Agent状态
  async getAgentStatus() {
    const res = await fetch(`${API_BASE}/api/v1/agents/status`);
    return res.json();
  },

  // 提交反馈
  async submitFeedback(feedback) {
    const res = await fetch(`${API_BASE}/api/v1/feedback`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(feedback)
    });
    return res.json();
  },

  // 获取优化建议
  async getRecommendations(target = '') {
    const res = await fetch(`${API_BASE}/api/v1/feedback/recommendations?target_protein=${target}`);
    return res.json();
  }
};
```

```vue
<!-- PipelineDemo.vue -->
<template>
  <div>
    <h2>5-Agent Pipeline 演示</h2>

    <!-- 研究员画像输入 -->
    <el-form :model="profile">
      <el-form-item label="姓名">
        <el-input v-model="profile.name" />
      </el-form-item>
      <el-form-item label="研究领域">
        <el-input v-model="profile.research_field" />
      </el-form-item>
      <el-form-item label="目标蛋白">
        <el-input v-model="profile.target_protein" />
      </el-form-item>
      <el-button type="primary" @click="runPipeline" :loading="loading">
        执行Pipeline
      </el-button>
    </el-form>

    <!-- 结果展示 -->
    <div v-if="result">
      <h3>执行结果</h3>
      <p>状态: {{ result.pipeline_status }}</p>
      <p>耗时: {{ result.elapsed_time }}s</p>

      <!-- 分子列表 -->
      <el-table :data="molecules" v-if="molecules.length">
        <el-table-column prop="id" label="ID" />
        <el-table-column prop="smiles" label="SMILES" />
        <el-table-column prop="properties.molwt" label="分子量" />
        <el-table-column prop="properties.qed" label="QED" />
        <el-table-column prop="total_score" label="评分" />
        <el-table-column prop="verdict" label="审核结果" />
      </el-table>
    </div>
  </div>
</template>

<script setup>
import { ref, computed } from 'vue';
import { api } from './api';

const profile = ref({
  name: '张三',
  institution: '某某大学',
  research_field: '抗肿瘤药物',
  target_protein: 'EGFR',
  experience_level: '中级'
});

const result = ref(null);
const loading = ref(false);

const molecules = computed(() => {
  if (!result.value) return [];
  return result.value.data?.steps?.reviewer?.result?.top_candidates || [];
});

async function runPipeline() {
  loading.value = true;
  try {
    const res = await api.runPipeline(profile.value);
    result.value = res.data;
  } finally {
    loading.value = false;
  }
}
</script>
```

## 注意事项

1. **确保后端服务已启动**后再调用前端
2. **CORS已开启**，前端可直接调用，无需代理
3. 分子SMILES可直接用RDKit.js在前端渲染分子结构图
4. 评分用进度条或颜色区分（绿色=通过，红色=不通过）
