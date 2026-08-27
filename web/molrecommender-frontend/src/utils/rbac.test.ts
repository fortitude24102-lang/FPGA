import { beforeEach, describe, expect, it } from 'vitest'
import { canAccessPath, clearPrivacySensitiveStorage, getStoredRole, setStoredRole } from './rbac'

describe('rbac helpers', () => {
  beforeEach(() => localStorage.clear())

  it('defaults to student role', () => {
    expect(getStoredRole()).toBe('student')
  })

  it('stores and reads selected role', () => {
    setStoredRole('teacher')
    expect(getStoredRole()).toBe('teacher')
  })

  it('blocks student from admin route', () => {
    setStoredRole('student')
    expect(canAccessPath('/admin')).toBe(false)
    expect(canAccessPath('/assessment')).toBe(true)
  })

  it('keeps role while clearing sensitive local data', () => {
    setStoredRole('admin')
    localStorage.setItem('trace_id', 'abc')
    clearPrivacySensitiveStorage()
    expect(localStorage.getItem('user_role')).toBe('admin')
    expect(localStorage.getItem('trace_id')).toBeNull()
  })
})
