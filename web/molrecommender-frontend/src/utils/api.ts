import { request } from './request'

const BASE_URL = import.meta.env.VITE_API_BASE_URL || 'http://127.0.0.1:8000'
const API_BASE = `${BASE_URL}/api/v1`

export interface ResearcherProfile {
  researcher_id: string
  name: string
  background: string
  experience_years: number
  target: string
  research_goal: string
  constraints: string[]
  skills: Record<string, number>
}

export interface FingerprintResult {
  smiles: string
  fingerprint?: string
  maccs?: string
  morgan?: string
  maccs_hex?: string
  fp_size?: number
  success?: boolean
  error?: string
}

export interface SimilarityResult {
  smiles1: string
  smiles2: string
  similarity?: number
  tanimoto_maccs?: number
  tanimoto_morgan?: number
  error?: string
}

export interface MoleculeInfo {
  smiles: string
  molecular_weight?: number
  mol_weight?: number
  formula?: string
  logp?: number
  num_atoms?: number
  num_bonds?: number
  valid?: boolean
  error?: string
}

export interface FeedbackPayload {
  researcher_id: string
  molecule_id?: string
  smiles?: string
  target_protein?: string
  rating?: number
  action?: string
  comments?: string
  resource_id?: string
  helpful?: boolean
  properties?: Record<string, unknown>
}

export interface DebateRound {
  round: number
  speaker: 'Generator' | 'Reviewer'
  content: string
  confidence: number
  evidence: string[]
  timestamp: string
}

export interface Debate {
  debate_id: string
  topic: string
  rounds: DebateRound[]
  verdict: 'approved' | 'rejected' | 'needs_revision'
  final_confidence: number
  duration_ms: number
}

export interface KnowledgeSource {
  type: string
  name: string
  confidence: number
}

export interface ValidationStep {
  name: string
  status: 'passed' | 'failed' | 'warning'
  detail: string
}

export interface Provenance {
  knowledge_sources: KnowledgeSource[]
  generation_path: string[]
  validation_chain: ValidationStep[]
  generated_at: string
}

export interface RadarDimension {
  name: string
  score: number
}

export interface LlmAnalysis {
  knowledge_gaps: string[]
  analysis: string
  recommendations: string[]
}

export interface ProfileRadarData {
  user_id: string
  dimensions: RadarDimension[]
  overall_score?: number
  updated_at?: string
  llm_analysis?: LlmAnalysis | null
}

export interface LearningNode {
  title: string
  status: 'completed' | 'current' | 'locked'
  estimate: string
  summary: string
}

export interface HallucinationResult {
  rate: number
  level: 'trusted' | 'suspicious' | 'high_risk'
  types: string[]
  rdkit_basis: string
}

export interface BatchTestResult {
  user_type: string
  hallucination_rate: number
  adaptation_accuracy: number
  coverage: number
  result: string
}

async function requestJson<T>(url: string, options?: { method?: string; body?: string }): Promise<T> {
  const data = options?.body ? JSON.parse(options.body) : undefined
  return request<T>({
    url,
    method: options?.method || 'GET',
    data,
  })
}

export async function healthCheck() {
  return requestJson<{ status?: string; message?: string; version?: string }>(`${API_BASE}/health`)
}

export async function readyCheck() {
  return requestJson<{
    status?: string
    version?: string
    services?: Record<string, string>
    api?: string
    storage?: string
    fpga?: string
  }>(`${BASE_URL}/ready`)
}

export async function getAgentStatus() {
  return requestJson<Record<string, unknown>>(`${API_BASE}/agents/status`)
}

export async function runPipeline(profile: ResearcherProfile) {
  return requestJson<Record<string, unknown>>(`${API_BASE}/pipeline`, {
    method: 'POST',
    body: JSON.stringify(profile),
  })
}

export async function analyze(profile: ResearcherProfile) {
  return requestJson<Record<string, unknown>>(`${API_BASE}/analyze`, {
    method: 'POST',
    body: JSON.stringify(profile),
  })
}

export async function plan(data: Record<string, unknown>) {
  return requestJson<Record<string, unknown>>(`${API_BASE}/plan`, {
    method: 'POST',
    body: JSON.stringify(data),
  })
}

export async function generate(data: Record<string, unknown>) {
  return requestJson<Record<string, unknown>>(`${API_BASE}/generate`, {
    method: 'POST',
    body: JSON.stringify(data),
  })
}

export async function review(data: Record<string, unknown>) {
  return requestJson<Record<string, unknown>>(`${API_BASE}/review`, {
    method: 'POST',
    body: JSON.stringify(data),
  })
}

export async function submitFeedback(feedback: FeedbackPayload) {
  return requestJson<Record<string, unknown>>(`${API_BASE}/feedback`, {
    method: 'POST',
    body: JSON.stringify(feedback),
  })
}

export async function getFingerprint(smiles: string) {
  const params = new URLSearchParams({ smiles })
  return requestJson<FingerprintResult>(`${API_BASE}/fingerprint?${params}`, { method: 'POST' })
}

export async function getSimilarity(smiles1: string, smiles2: string) {
  return requestJson<SimilarityResult>(`${API_BASE}/compare`, {
    method: 'POST',
    body: JSON.stringify({ smiles1, smiles2 }),
  })
}

export async function getMoleculeInfo(smiles: string) {
  const params = new URLSearchParams({ smiles })
  return requestJson<MoleculeInfo>(`${API_BASE}/molecule/properties?${params}`)
}

export async function validateSmiles(smiles: string) {
  const params = new URLSearchParams({ smiles })
  return requestJson<MoleculeInfo>(`${API_BASE}/molecule/validate?${params}`)
}

export async function adminStatus() {
  return requestJson<Record<string, unknown>>(`${BASE_URL}/api/admin/status`)
}

export async function reloadConfig() {
  return requestJson<Record<string, unknown>>(`${BASE_URL}/api/admin/reload-config`, { method: 'POST' })
}

export async function startDebate(payload: Record<string, unknown>) {
  return requestJson<{ debate_id: string }>(`${BASE_URL}/api/debate/start`, {
    method: 'POST',
    body: JSON.stringify(payload),
  })
}

export async function getDebateRounds(debateId: string) {
  return requestJson<DebateRound[]>(`${BASE_URL}/api/debate/${debateId}/rounds`)
}

export async function respondDebate(debateId: string, payload: Record<string, unknown>) {
  return requestJson<Record<string, unknown>>(`${BASE_URL}/api/debate/${debateId}/respond`, {
    method: 'POST',
    body: JSON.stringify(payload),
  })
}

export async function getDebateVerdict(debateId: string) {
  return requestJson<Pick<Debate, 'verdict' | 'final_confidence' | 'duration_ms'>>(`${BASE_URL}/api/debate/${debateId}/verdict`)
}

export async function startAssessment(payload: Record<string, unknown>) {
  return requestJson<Record<string, unknown>>(`${BASE_URL}/api/assessment/start`, {
    method: 'POST',
    body: JSON.stringify(payload),
  })
}

export async function submitAssessment(id: string, payload: Record<string, unknown>) {
  return requestJson<Record<string, unknown>>(`${BASE_URL}/api/assessment/${id}/submit`, {
    method: 'POST',
    body: JSON.stringify(payload),
  })
}

export async function getProfileRadar(userId: string) {
  return requestJson<ProfileRadarData | RadarDimension[] | { status?: string; data?: ProfileRadarData }>(
    `${BASE_URL}/api/profile/${userId}/radar`,
  )
}

export async function getLearningPath(userId: string) {
  return requestJson<LearningNode[]>(`${BASE_URL}/api/profile/${userId}/learning-path`)
}

export async function getResourceProvenance(resourceId: string) {
  return requestJson<Provenance>(`${BASE_URL}/api/resources/${resourceId}/provenance`)
}

export async function checkHallucination(payload: Record<string, unknown>) {
  return requestJson<HallucinationResult>(`${BASE_URL}/api/hallucination/check`, {
    method: 'POST',
    body: JSON.stringify(payload),
  })
}

export async function getHallucinationStats() {
  return requestJson<{ hallucination_rate: number; success_rate: number; coverage: number }>(`${BASE_URL}/api/hallucination/stats`)
}

export async function runBatchTest(payload: Record<string, unknown>) {
  return requestJson<{ task_id?: string; results?: BatchTestResult[] }>(`${BASE_URL}/api/batch-test/run`, {
    method: 'POST',
    body: JSON.stringify(payload),
  })
}

export async function getBatchTestResults() {
  return requestJson<BatchTestResult[]>(`${BASE_URL}/api/batch-test/results`)
}

export async function adjustAdaptation(payload: Record<string, unknown>) {
  return requestJson<Record<string, unknown>>(`${BASE_URL}/api/adaptation/adjust`, {
    method: 'POST',
    body: JSON.stringify(payload),
  })
}

export { API_BASE, BASE_URL }

export async function askSocratic(payload: Record<string, unknown>) {
  const res = await requestJson<Record<string, unknown> | string>(`${BASE_URL}/api/socratic/ask`, {
    method: 'POST',
    body: JSON.stringify(payload),
  })
  // 后端返回纯字符串时，包装成对象格式
  if (typeof res === 'string') {
    return { response: res, hint_level: '引导', should_reveal: false }
  }
  return res
}

export async function getKnowledgeGraph(userId: string) {
  return requestJson<Record<string, unknown>>(`${BASE_URL}/api/profile/${userId}/knowledge-graph`)
}

export async function inferKnowledgeGraph(userId: string) {
  return requestJson<Record<string, unknown>>(`${BASE_URL}/api/kg/infer/${userId}`)
}

export async function getPropagationRecommend(userId: string) {
  return requestJson<Record<string, unknown>>(`${BASE_URL}/api/profile/${userId}/propagate-recommend`)
}

export async function getDifficultyCurve(userId: string) {
  return requestJson<Record<string, unknown>>(`${BASE_URL}/api/profile/${userId}/difficulty-curve`)
}

export async function getCredentials(userId: string) {
  return requestJson<Record<string, unknown>>(`${BASE_URL}/api/profile/${userId}/credentials`)
}

export async function getPortfolio(userId: string) {
  return requestJson<Record<string, unknown>>(`${BASE_URL}/api/profile/${userId}/portfolio`)
}

export async function getPrediction(userId: string) {
  return requestJson<Record<string, unknown>>(`${BASE_URL}/api/profile/${userId}/prediction`)
}

export async function getLearningPathHistory(userId: string) {
  return requestJson<Record<string, unknown>>(`${BASE_URL}/api/profile/${userId}/learning-path/history`)
}

export async function getPrivacyStatement() {
  return requestJson<Record<string, unknown>>(`${BASE_URL}/api/privacy/statement`)
}

export async function revokeConsent(userId: string) {
  return requestJson<Record<string, unknown>>(`${BASE_URL}/api/privacy/revoke-consent/${userId}`, { method: 'POST' })
}

export async function deletePrivacyData(userId: string) {
  return requestJson<Record<string, unknown>>(`${BASE_URL}/api/privacy/data/${userId}`, { method: 'DELETE' })
}

export async function getAuditLogs() {
  return requestJson<Record<string, unknown>>(`${BASE_URL}/api/privacy/audit-logs`)
}

export async function getTaskStatus(taskId: string) {
  return requestJson<Record<string, unknown>>(`${BASE_URL}/api/tasks/${taskId}/status`)
}

export async function exportData(payload: Record<string, unknown>) {
  return requestJson<Blob | Record<string, unknown>>(`${BASE_URL}/api/export`, {
    method: 'POST',
    body: JSON.stringify(payload),
  })
}
