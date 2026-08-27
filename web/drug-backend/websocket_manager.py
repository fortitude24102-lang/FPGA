"""
WebSocket管理器
功能：实时推送Agent状态、Pipeline进度、分子生成结果
对应云之脑架构：神经网络实时通信
"""
from typing import Dict, List, Any, Optional
from fastapi import WebSocket
import json
import asyncio

class ConnectionManager:
    """WebSocket连接管理器"""

    def __init__(self):
        # 客户端连接列表
        self.active_connections: List[WebSocket] = []
        # 客户端订阅信息
        self.client_subscriptions: Dict[WebSocket, Dict[str, Any]] = {}

    async def connect(self, websocket: WebSocket):
        """接受新连接"""
        await websocket.accept()
        self.active_connections.append(websocket)
        self.client_subscriptions[websocket] = {
            "subscribed_channels": ["all"],
            "client_id": f"client_{len(self.active_connections)}",
        }
        print(f"[WebSocket] 新客户端连接: {self.client_subscriptions[websocket]['client_id']}")

    def disconnect(self, websocket: WebSocket):
        """断开连接"""
        if websocket in self.active_connections:
            self.active_connections.remove(websocket)
        if websocket in self.client_subscriptions:
            del self.client_subscriptions[websocket]
        print("[WebSocket] 客户端断开连接")

    async def send_personal_message(self, message: Dict, websocket: WebSocket):
        """发送个人消息"""
        try:
            await websocket.send_json(message)
        except Exception as e:
            print(f"[WebSocket] 发送失败: {e}")

    async def broadcast(self, message: Dict, channel: str = "all"):
        """广播消息到所有订阅该频道的客户端"""
        disconnected = []
        for connection in self.active_connections:
            try:
                subs = self.client_subscriptions.get(connection, {})
                channels = subs.get("subscribed_channels", ["all"])
                if channel in channels or "all" in channels:
                    await connection.send_json(message)
            except Exception as e:
                print(f"[WebSocket] 广播失败: {e}")
                disconnected.append(connection)

        # 清理断开的连接
        for conn in disconnected:
            self.disconnect(conn)

    async def broadcast_agent_status(self, agent_id: str, status: str, details: Dict = None):
        """广播Agent状态更新"""
        message = {
            "type": "agent_status",
            "timestamp": asyncio.get_event_loop().time(),
            "data": {
                "agent_id": agent_id,
                "status": status,
                "details": details or {},
            }
        }
        await self.broadcast(message, "agent_monitor")

    async def broadcast_pipeline_progress(self, pipeline_id: str, step: str, progress: float, result: Dict = None):
        """广播Pipeline进度"""
        message = {
            "type": "pipeline_progress",
            "timestamp": asyncio.get_event_loop().time(),
            "data": {
                "pipeline_id": pipeline_id,
                "current_step": step,
                "progress": progress,
                "result": result or {},
            }
        }
        await self.broadcast(message, "pipeline")

    async def broadcast_molecule_generated(self, molecule: Dict, target: str = ""):
        """广播新生成的分子"""
        message = {
            "type": "molecule_generated",
            "timestamp": asyncio.get_event_loop().time(),
            "data": {
                "molecule": molecule,
                "target": target,
            }
        }
        await self.broadcast(message, "molecule")

    async def broadcast_review_result(self, molecule_id: str, score: float, verdict: str):
        """广播审核结果"""
        message = {
            "type": "review_result",
            "timestamp": asyncio.get_event_loop().time(),
            "data": {
                "molecule_id": molecule_id,
                "score": score,
                "verdict": verdict,
            }
        }
        await self.broadcast(message, "review")

    def get_connection_count(self) -> int:
        """获取当前连接数"""
        return len(self.active_connections)


# 单例实例
manager = ConnectionManager()
