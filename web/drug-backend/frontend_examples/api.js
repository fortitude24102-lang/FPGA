// api.js - 前端API调用封装
const API_BASE = 'http://localhost:8000';

/**
 * 通用请求封装
 */
async function request(url, options = {}) {
  const response = await fetch(`${API_BASE}${url}`, {
    headers: {
      'Content-Type': 'application/json',
      ...options.headers,
    },
    ...options,
  });

  if (!response.ok) {
    const error = await response.json();
    throw new Error(error.detail || '请求失败');
  }

  return response.json();
}

/**
 * API接口集合
 */
export const api = {
  // ==================== 系统接口 ====================

  /** 获取系统信息 */
  async getSystemInfo() {
    return request('/api/v1/system/info');
  },

  /** 获取Agent状态 */
  async getAgentStatus() {
    return request('/api/v1/agents/status');
  },

  // ==================== 核心Pipeline接口 ====================

  /** 
   * 执行完整Pipeline (核心接口)
   * @param {Object} profile - 研究员画像
   */
  async runPipeline(profile) {
    return request('/api/v1/pipeline', {
      method: 'POST',
      body: JSON.stringify(profile),
    });
  },

  /** 
   * 批量执行Pipeline
   * @param {Array} profiles - 研究员画像数组
   */
  async runPipelineBatch(profiles) {
    return request('/api/v1/pipeline/batch', {
      method: 'POST',
      body: JSON.stringify({ profiles }),
    });
  },

  // ==================== 各Agent独立接口 ====================

  /** 
   * 需求分析
   * @param {Object} profile - 研究员画像
   */
  async analyze(profile) {
    return request('/api/v1/analyze', {
      method: 'POST',
      body: JSON.stringify(profile),
    });
  },

  /** 
   * 策略规划
   * @param {Object} analysisResult - 分析结果
   */
  async plan(analysisResult) {
    return request('/api/v1/plan', {
      method: 'POST',
      body: JSON.stringify(analysisResult),
    });
  },

  /** 
   * 分子生成
   * @param {Object} params - 生成参数
   */
  async generate(params) {
    return request('/api/v1/generate', {
      method: 'POST',
      body: JSON.stringify(params),
    });
  },

  /** 
   * 审核分子
   * @param {Object} generationResult - 生成结果
   */
  async review(generationResult) {
    return request('/api/v1/review', {
      method: 'POST',
      body: JSON.stringify(generationResult),
    });
  },

  // ==================== 反馈学习接口 ====================

  /** 
   * 提交反馈
   * @param {Object} feedback - 反馈数据
   */
  async submitFeedback(feedback) {
    return request('/api/v1/feedback', {
      method: 'POST',
      body: JSON.stringify(feedback),
    });
  },

  /** 
   * 获取优化建议
   * @param {string} targetProtein - 目标蛋白(可选)
   * @param {string} researcherId - 研究员ID(可选)
   */
  async getRecommendations(targetProtein = '', researcherId = '') {
    const params = new URLSearchParams();
    if (targetProtein) params.append('target_protein', targetProtein);
    if (researcherId) params.append('researcher_id', researcherId);
    return request(`/api/v1/feedback/recommendations?${params}`);
  },

  // ==================== 历史记录接口 ====================

  /** 
   * 获取历史记录
   * @param {number} limit - 返回数量
   * @param {string} targetProtein - 靶点筛选
   */
  async getHistory(limit = 10, targetProtein = '') {
    const params = new URLSearchParams();
    params.append('limit', limit);
    if (targetProtein) params.append('target_protein', targetProtein);
    return request(`/api/v1/history?${params}`);
  },

  /** 获取历史统计 */
  async getHistoryStats() {
    return request('/api/v1/history/stats');
  },

  // ==================== 分子工具接口 ====================

  /** 
   * 计算分子性质
   * @param {string} smiles - 分子SMILES
   */
  async getMoleculeProperties(smiles) {
    const params = new URLSearchParams();
    params.append('smiles', smiles);
    return request(`/api/v1/molecule/properties?${params}`);
  },

  /** 
   * 验证SMILES
   * @param {string} smiles - 分子SMILES
   */
  async validateSmiles(smiles) {
    const params = new URLSearchParams();
    params.append('smiles', smiles);
    return request(`/api/v1/molecule/validate?${params}`);
  },

  /** 
   * 比较分子相似性
   * @param {string} smiles1 - 第一个SMILES
   * @param {string} smiles2 - 第二个SMILES
   */
  async compareMolecules(smiles1, smiles2) {
    return request('/api/v1/compare', {
      method: 'POST',
      body: JSON.stringify({ smiles1, smiles2 }),
    });
  },

  /** 
   * 计算分子指纹 (FPGA)
   * @param {string} smiles - 分子SMILES
   */
  async computeFingerprint(smiles) {
    const params = new URLSearchParams();
    params.append('smiles', smiles);
    return request(`/api/v1/fingerprint?${params}`);
  },
};

export default api;
