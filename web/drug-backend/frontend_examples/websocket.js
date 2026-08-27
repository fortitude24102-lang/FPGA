// websocket.js - 前端WebSocket实时通信封装
const WS_URL = 'ws://localhost:8000/ws';

class DrugDesignWebSocket {
  constructor() {
    this.ws = null;
    this.reconnectAttempts = 0;
    this.maxReconnectAttempts = 5;
    this.reconnectDelay = 3000;
    this.callbacks = {};
  }

  // 连接WebSocket
  connect() {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(WS_URL);

      this.ws.onopen = () => {
        console.log('[WebSocket] 连接成功');
        this.reconnectAttempts = 0;

        // 订阅频道
        this.subscribe(['agent_monitor', 'pipeline', 'molecule', 'review']);

        resolve();
      };

      this.ws.onmessage = (event) => {
        const message = JSON.parse(event.data);
        this.handleMessage(message);
      };

      this.ws.onclose = () => {
        console.log('[WebSocket] 连接关闭');
        this.attemptReconnect();
      };

      this.ws.onerror = (error) => {
        console.error('[WebSocket] 错误:', error);
        reject(error);
      };
    });
  }

  // 订阅频道
  subscribe(channels) {
    this.send({
      type: 'subscribe',
      channels: channels,
    });
  }

  // 发送消息
  send(data) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(data));
    }
  }

  // 处理接收到的消息
  handleMessage(message) {
    const { type, data } = message;

    switch (type) {
      case 'agent_status':
        this.trigger('agentStatus', data);
        break;
      case 'pipeline_progress':
        this.trigger('pipelineProgress', data);
        break;
      case 'molecule_generated':
        this.trigger('moleculeGenerated', data);
        break;
      case 'review_result':
        this.trigger('reviewResult', data);
        break;
      case 'pong':
        console.log('[WebSocket] 心跳响应');
        break;
      default:
        console.log('[WebSocket] 未知消息类型:', type);
    }
  }

  // 注册回调
  on(event, callback) {
    if (!this.callbacks[event]) {
      this.callbacks[event] = [];
    }
    this.callbacks[event].push(callback);
  }

  // 触发回调
  trigger(event, data) {
    if (this.callbacks[event]) {
      this.callbacks[event].forEach(cb => cb(data));
    }
  }

  // 重连
  attemptReconnect() {
    if (this.reconnectAttempts < this.maxReconnectAttempts) {
      this.reconnectAttempts++;
      console.log(`[WebSocket] ${this.reconnectDelay}ms后尝试重连 (${this.reconnectAttempts}/${this.maxReconnectAttempts})`);
      setTimeout(() => this.connect(), this.reconnectDelay);
    }
  }

  // 断开连接
  disconnect() {
    if (this.ws) {
      this.ws.close();
    }
  }

  // 心跳检测
  startHeartbeat() {
    setInterval(() => {
      this.send({ type: 'ping' });
    }, 30000);
  }
}

// 使用示例
/*
const ws = new DrugDesignWebSocket();

// 连接
await ws.connect();
ws.startHeartbeat();

// 监听Agent状态
ws.on('agentStatus', (data) => {
  console.log('Agent状态更新:', data);
});

// 监听Pipeline进度
ws.on('pipelineProgress', (data) => {
  console.log('Pipeline进度:', data);
  // 更新进度条
  updateProgressBar(data.progress);
});

// 监听新生成的分子
ws.on('moleculeGenerated', (data) => {
  console.log('新分子:', data.molecule);
  // 添加到分子列表
  addMoleculeToList(data.molecule);
});

// 监听审核结果
ws.on('reviewResult', (data) => {
  console.log('审核结果:', data);
  // 更新分子评分
  updateMoleculeScore(data.molecule_id, data.score);
});
*/

export default DrugDesignWebSocket;
