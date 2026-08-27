export function debounce<T extends (...args: unknown[]) => void>(fn: T, wait = 300) {
  let timer: number | undefined
  return (...args: Parameters<T>) => {
    if (timer) window.clearTimeout(timer)
    timer = window.setTimeout(() => fn(...args), wait)
  }
}

export function throttle<T extends (...args: unknown[]) => void>(fn: T, wait = 16) {
  let last = 0
  let frame = 0
  return (...args: Parameters<T>) => {
    const now = Date.now()
    if (now - last < wait) return
    last = now
    if (frame) cancelAnimationFrame(frame)
    frame = requestAnimationFrame(() => fn(...args))
  }
}

export function bindLazyImages(root: ParentNode = document) {
  const images = Array.from(root.querySelectorAll<HTMLImageElement>('img[data-src]'))
  if (!('IntersectionObserver' in window)) {
    images.forEach((img) => {
      img.src = img.dataset.src || ''
      img.removeAttribute('data-src')
    })
    return
  }
  const observer = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (!entry.isIntersecting) return
      const img = entry.target as HTMLImageElement
      img.src = img.dataset.src || ''
      img.removeAttribute('data-src')
      observer.unobserve(img)
    })
  })
  images.forEach((img) => observer.observe(img))
}
