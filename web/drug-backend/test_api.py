#!/usr/bin/env python3
"""
AI药物分子智能决策辅助系统 - API 回归测试脚本 v4.1
比赛前一键验证所有核心接口是否正常
用法: python test_api.py
"""
import httpx as requests
import sys
import time

BASE = "http://localhost:8000"
TIMEOUT = 10

TESTS = [
    # 系统监控
    ("GET", "/health", 200, None, "健康检查"),
    ("GET", "/ready", 200, None, "就绪检查"),
    ("GET", "/api/admin/status", 200, None, "系统状态"),

    # Agent 管理
    ("GET", "/api/v1/agents/status", 200, None, "Agent状态"),

    # 知识中心
    ("GET", "/api/v1/knowledge/targets", 200, None, "靶点列表"),
    ("GET", "/api/v1/knowledge/admet-rules", 200, None, "ADMET规则"),

    # 分子工具
    ("GET", "/api/v1/molecule/validate?smiles=CCO", 200, None, "SMILES验证"),
    ("GET", "/api/v1/molecule/properties?smiles=CCO", 200, None, "分子性质计算"),
    ("POST", "/api/v1/fingerprint?smiles=CCO&fp_size=2048", 200, None, "指纹计算(FPGA/CPU)"),

    # 核心 Pipeline
    ("POST", "/api/v1/pipeline", 200, {
        "name": "测试", "institution": "测试大学", "research_field": "抗肿瘤",
        "target_protein": "EGFR", "experience_level": "中级"
    }, "Pipeline执行"),

    # v3.2 增强模块
    ("POST", "/api/debate/start", 200, {"topic": "测试辩论"}, "辩论启动"),
    ("POST", "/api/hallucination/check", 200, {
        "generated_content": "这是一个测试分子", "content_type": "text"
    }, "幻觉检测"),
    ("POST", "/api/adaptation/adjust", 200, {
        "user_id": "test_user", "correct_rate": 0.75, "current_level": "standard"
    }, "动态难度"),
    ("POST", "/api/assessment/start", 200, {
        "user_id": "test_user", "question_count": 5
    }, "学情评估"),
    ("POST", "/api/batch-test/run", 200, {
        "test_cases": [{"id": "TC-TEST", "profile": {"name": "测试", "background": "本科", "theory_score": 60, "experience": "1年"}, "expected": {"resource_difficulty": "入门", "knowledge_gaps": []}}]
    }, "批量测试"),
    ("POST", "/api/tasks/generate", 200, {
        "task_type": "molecule_generation", "params": {"target": "EGFR", "count": 3}
    }, "异步任务"),

    # v4.0 新增
    ("POST", "/api/export", 200, {"data_type": "all", "format": "json"}, "数据导出"),
]


def run_test(method, path, expect_code, payload, desc):
    url = BASE + path
    try:
        if method == "GET":
            r = requests.get(url, timeout=TIMEOUT)
        else:
            r = requests.post(url, json=payload, timeout=TIMEOUT)

        ok = r.status_code == expect_code
        trace_id = r.headers.get('x-trace-id', 'N/A')

        if ok:
            print(f"  ✓ [{desc}] {method} {path} -> {r.status_code} (trace_id={trace_id})")
            return True
        else:
            print(f"  ✗ [{desc}] {method} {path} -> {r.status_code} (期望{expect_code}) trace_id={trace_id}")
            print(f"     响应: {r.text[:200]}")
            return False
    except requests.ConnectError:
        print(f"  ✗ [{desc}] {method} {path} -> 连接失败（后端未启动？）")
        return False
    except Exception as e:
        print(f"  ✗ [{desc}] {method} {path} -> 异常: {e}")
        return False


def main():
    print("=" * 60)
    print("AI药物分子智能决策辅助系统 - API 回归测试 v4.1")
    print("=" * 60)
    print(f"测试地址: {BASE}")
    print(f"测试项数: {len(TESTS)}")
    print("=" * 60)

    # 先检查服务是否存活
    try:
        r = requests.get(BASE + "/health", timeout=5)
        print(f"服务状态: {r.json().get('status', 'unknown')}")
    except:
        print("✗ 后端服务未启动，请先运行 python main.py")
        sys.exit(1)

    print()
    passed = 0
    start = time.time()

    for method, path, code, payload, desc in TESTS:
        if run_test(method, path, code, payload, desc):
            passed += 1
        time.sleep(0.3)  # 避免触发限流

    elapsed = round(time.time() - start, 2)

    print()
    print("=" * 60)
    print(f"测试结果: {passed}/{len(TESTS)} 通过 | 耗时: {elapsed}s")
    if passed == len(TESTS):
        print("✓ 全部通过，系统状态良好，可以开始演示！")
    else:
        print(f"✗ {len(TESTS) - passed} 项失败，请检查日志: logs/app.log")
    print("=" * 60)

    return passed == len(TESTS)


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
