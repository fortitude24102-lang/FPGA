import { describe, expect, it, vi } from 'vitest'
import { debounce, throttle } from './performance'

describe('performance helpers', () => {
  it('debounces repeated calls', () => {
    vi.useFakeTimers()
    const fn = vi.fn()
    const debounced = debounce(fn, 300)
    debounced()
    debounced()
    vi.advanceTimersByTime(299)
    expect(fn).not.toHaveBeenCalled()
    vi.advanceTimersByTime(1)
    expect(fn).toHaveBeenCalledTimes(1)
    vi.useRealTimers()
  })

  it('throttles calls within one frame window', () => {
    vi.stubGlobal('requestAnimationFrame', (cb: FrameRequestCallback) => window.setTimeout(() => cb(0), 0))
    vi.stubGlobal('cancelAnimationFrame', (id: number) => window.clearTimeout(id))
    const fn = vi.fn()
    const throttled = throttle(fn, 16)
    throttled()
    throttled()
    expect(fn).toHaveBeenCalledTimes(0)
  })
})
