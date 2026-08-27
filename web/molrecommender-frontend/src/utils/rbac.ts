export type UserRole = 'student' | 'teacher' | 'admin'

export const roleLabels: Record<UserRole, string> = {
  student: '学生',
  teacher: '教师',
  admin: '管理员',
}

export const rolePermissions: Record<UserRole, string[]> = {
  student: [
    '/startup',
    '/profile',
    '/assessment',
    '/diagnosis',
    '/profile/radar',
    '/adaptation',
    '/socratic',
    '/knowledge-graph',
    '/learning-path',
    '/hallucination',
    '/knowledge-graph/propagation',
    '/learning-path/history',
    '/difficulty-curve',
    '/profile/prediction',
    '/profile/credentials',
    '/profile/portfolio',
    '/privacy/statement',
    '/privacy/settings',
    '/molecules',
    '/resources',
    '/feedback',
  ],
  teacher: [
    '/startup',
    '/profile',
    '/assessment',
    '/diagnosis',
    '/profile/radar',
    '/adaptation',
    '/socratic',
    '/knowledge-graph',
    '/learning-path',
    '/hallucination',
    '/knowledge-graph/propagation',
    '/learning-path/history',
    '/difficulty-curve',
    '/profile/prediction',
    '/profile/credentials',
    '/profile/portfolio',
    '/privacy/statement',
    '/molecules',
    '/resources',
    '/feedback',
    '/agent-dashboard',
    '/agent-monitor',
    '/debate',
    '/testing',
    '/tasks',
  ],
  admin: ['/'],
}

export function getStoredRole(): UserRole {
  const saved = localStorage.getItem('user_role') as UserRole | null
  return saved === 'teacher' || saved === 'admin' || saved === 'student' ? saved : 'student'
}

export function setStoredRole(role: UserRole) {
  localStorage.setItem('user_role', role)
  window.dispatchEvent(new CustomEvent('role-change', { detail: role }))
}

export function canAccessPath(path: string, role = getStoredRole()) {
  if (path === '/403') return true
  const allowed = rolePermissions[role] || rolePermissions.student
  return allowed.some((prefix) => prefix === '/' || path.startsWith(prefix))
}

export function clearPrivacySensitiveStorage() {
  const keep = ['user_role']
  Object.keys(localStorage).forEach((key) => {
    if (!keep.includes(key)) localStorage.removeItem(key)
  })
}

