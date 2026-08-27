type WsHandler = (payload: Record<string, unknown>) => void
export type WsStatus = 'connecting' | 'open' | 'closed' | 'reconnecting' | 'failed' | 'limited'

class WsManager {
  private ws: WebSocket | null = null
  private handlers = new Map<string, Set<WsHandler>>()
  private reconnectCount = 0
  private heartbeat: number | null = null
  private watchdog: number | null = null
  private lastPong = 0
  private statusHandlers = new Set<(status: WsStatus) => void>()
  private channels: string[] = []

  connect(url = 'ws://127.0.0.1:8000/ws') {
    if (this.ws && (this.ws.readyState === WebSocket.OPEN || this.ws.readyState === WebSocket.CONNECTING)) return

    this.emitStatus('connecting')
    this.ws = new WebSocket(url)
    this.ws.onopen = () => {
      this.reconnectCount = 0
      this.lastPong = Date.now()
      this.emitStatus('open')
      this.startHeartbeat()
      if (this.channels.length) this.subscribe(this.channels)
    }
    this.ws.onmessage = (event) => this.dispatch(event.data)
    this.ws.onerror = () => this.emitStatus('failed')
    this.ws.onclose = (event) => {
      this.stopHeartbeat()
      if (event.code === 1013) {
        this.emitStatus('limited')
        return
      }
      this.emitStatus('closed')
      this.reconnect(url)
    }
  }

  on(type: string, handler: WsHandler) {
    if (!this.handlers.has(type)) this.handlers.set(type, new Set())
    this.handlers.get(type)?.add(handler)
    return () => this.handlers.get(type)?.delete(handler)
  }

  onStatus(handler: (status: WsStatus) => void) {
    this.statusHandlers.add(handler)
    return () => this.statusHandlers.delete(handler)
  }

  subscribe(channels: string[]) {
    this.channels = channels
    this.send('subscribe', { channels })
    this.send('subscribe_agent', { channels })
  }

  send(type: string, payload: Record<string, unknown> = {}) {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify({ type, ...payload }))
    }
  }

  private dispatch(raw: string) {
    try {
      const message = JSON.parse(raw)
      const type = message.type || 'message'
      if (type === 'pong') this.lastPong = Date.now()
      this.handlers.get(type)?.forEach((handler) => handler(message))
    } catch {
      this.handlers.get('message')?.forEach((handler) => handler({ content: raw }))
    }
  }

  private startHeartbeat() {
    this.stopHeartbeat()
    this.heartbeat = window.setInterval(() => this.send('ping', { ts: Date.now() }), 30000)
    this.watchdog = window.setInterval(() => {
      if (Date.now() - this.lastPong > 90000) {
        this.ws?.close()
      }
    }, 10000)
  }

  private stopHeartbeat() {
    if (this.heartbeat) window.clearInterval(this.heartbeat)
    if (this.watchdog) window.clearInterval(this.watchdog)
    this.heartbeat = null
    this.watchdog = null
  }

  private reconnect(url: string) {
    if (this.reconnectCount >= 5) return
    this.reconnectCount += 1
    this.emitStatus('reconnecting')
    const delay = Math.min(1000 * 2 ** (this.reconnectCount - 1), 30000)
    window.setTimeout(() => this.connect(url), delay)
  }

  private emitStatus(status: WsStatus) {
    this.statusHandlers.forEach((handler) => handler(status))
  }
}

export const wsManager = new WsManager()
