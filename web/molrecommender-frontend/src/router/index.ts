import { createRouter, createWebHistory } from 'vue-router'
import { canAccessPath, getStoredRole } from '../utils/rbac'

const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/', redirect: '/startup' },
    { path: '/startup', component: () => import('../views/StartupView.vue') },
    { path: '/profile', component: () => import('../views/ResearcherProfile.vue') },
    { path: '/assessment', component: () => import('../views/AssessmentView.vue') },
    { path: '/diagnosis', component: () => import('../views/DiagnosisReport.vue') },
    { path: '/profile/radar', component: () => import('../views/RadarProfile.vue') },
    { path: '/profile/prediction', component: () => import('../views/PredictionView.vue') },
    { path: '/profile/credentials', component: () => import('../views/CredentialsView.vue') },
    { path: '/profile/portfolio', component: () => import('../views/PortfolioView.vue') },
    { path: '/agent-dashboard', component: () => import('../views/AgentDashboard.vue') },
    { path: '/agent-monitor', component: () => import('../views/AgentMonitorView.vue') },
    { path: '/debate', component: () => import('../views/DebateHall.vue') },
    { path: '/adaptation', component: () => import('../views/AdaptationView.vue') },
    { path: '/difficulty-curve', component: () => import('../views/DifficultyCurveView.vue') },
    { path: '/socratic', component: () => import('../views/SocraticView.vue') },
    { path: '/knowledge-graph', component: () => import('../views/KnowledgeGraphView.vue') },
    { path: '/knowledge-graph/propagation', component: () => import('../views/PropagationView.vue') },
    { path: '/learning-path', component: () => import('../views/LearningPathView.vue') },
    { path: '/learning-path/history', component: () => import('../views/PathHistoryView.vue') },
    { path: '/tasks', component: () => import('../views/TaskCenterView.vue') },
    { path: '/molecules', component: () => import('../views/MoleculeView.vue') },
    { path: '/hallucination', component: () => import('../views/HallucinationView.vue') },
    { path: '/resources', component: () => import('../views/ResourceView.vue') },
    { path: '/feedback', component: () => import('../views/FeedbackView.vue') },
    { path: '/testing', component: () => import('../views/TestReportView.vue') },
    { path: '/admin', component: () => import('../views/AdminStatus.vue') },
    { path: '/privacy/statement', component: () => import('../views/PrivacyView.vue'), props: { tab: 'statement' } },
    { path: '/privacy/settings', component: () => import('../views/PrivacyView.vue'), props: { tab: 'settings' } },
    { path: '/403', component: () => import('../views/ForbiddenView.vue') },
  ],
})

router.beforeEach((to) => {
  const role = getStoredRole()
  if (!canAccessPath(to.path, role)) {
    return { path: '/403', query: { from: to.fullPath } }
  }
  return true
})

export default router

