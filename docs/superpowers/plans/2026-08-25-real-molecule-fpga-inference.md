# 真实分子三加速器后端接入实施计划

1. 为分子编码和 TCP 协议增加失败测试。
2. 在 `agents/fpga_client.py` 中复用现有板端协议，实现 RDKit 编码、批请求和结果解码。
3. 为 Orchestrator 集成增加失败测试。
4. 在 Generator 后、Reviewer 前调用批量硬件评估并附加 `fpga_evaluation`。
5. 运行后端回归测试和真实开发板三任务测试。
6. 验证 `/api/v1/pipeline` 返回真实硬件结果，并确认前端哈希零变化。
