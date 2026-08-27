"""
后端测试脚本 v3 - 验证云之脑架构完整功能
运行方式: python test.py
"""
import requests
import json
import time

BASE_URL = "http://localhost:8000"

def print_section(title):
    print("\n" + "=" * 60)
    print(f"[TEST] {title}")
    print("=" * 60)

def test_root():
    """测试根路由"""
    print_section("1. 根路由测试")
    try:
        r = requests.get(f"{BASE_URL}/")
        data = r.json()
        print(f"  状态码: {r.status_code}")
        print(f"  服务: {data.get('service')}")
        print(f"  版本: {data.get('version')}")
        print(f"  架构: {data.get('architecture')}")
        print(f"  组件: {json.dumps(data.get('components', {}), ensure_ascii=False)}")
        return r.status_code == 200
    except Exception as e:
        print(f"  错误: {e}")
        return False

def test_health():
    """测试健康检查"""
    print_section("2. 健康检查")
    try:
        r = requests.get(f"{BASE_URL}/api/v1/health")
        data = r.json()
        print(f"  状态码: {r.status_code}")
        print(f"  状态: {data.get('status')}")
        print(f"  组件状态: {json.dumps(data.get('components', {}), ensure_ascii=False)}")
        return r.status_code == 200
    except Exception as e:
        print(f"  错误: {e}")
        return False

def test_system_info():
    """测试系统信息"""
    print_section("3. 系统信息")
    try:
        r = requests.get(f"{BASE_URL}/api/v1/system/info")
        data = r.json()
        print(f"  状态码: {r.status_code}")
        info = data.get("data", {})
        print(f"  版本: {info.get('version')}")
        print(f"  架构: {info.get('architecture')}")
        print(f"  Agent数: {info.get('agents')}")
        print(f"  总运行次数: {info.get('total_pipeline_runs')}")
        print(f"  FPGA: {json.dumps(info.get('fpga_config', {}), ensure_ascii=False)}")
        return r.status_code == 200
    except Exception as e:
        print(f"  错误: {e}")
        return False

def test_agents_status():
    """测试Agent状态"""
    print_section("4. Agent状态查询")
    try:
        r = requests.get(f"{BASE_URL}/api/v1/agents/status")
        data = r.json()
        print(f"  状态码: {r.status_code}")
        agents = data.get("data", {}).get("agents", [])
        print(f"  Agent数量: {len(agents)}")
        for a in agents:
            print(f"    {a.get('icon', '•')} {a['name']}: {a['status']}")
        return r.status_code == 200 and len(agents) == 5
    except Exception as e:
        print(f"  错误: {e}")
        return False

def test_knowledge_targets():
    """测试靶点知识库"""
    print_section("5. 靶点知识库")
    try:
        r = requests.get(f"{BASE_URL}/api/v1/knowledge/targets")
        data = r.json()
        print(f"  状态码: {r.status_code}")
        targets = data.get("data", [])
        print(f"  靶点数量: {len(targets)}")
        for t in targets[:5]:
            print(f"    • {t['name']} ({t['full_name']}) - 难度:{t['difficulty']} 热度:{t['popularity']}")
        return r.status_code == 200 and len(targets) > 0
    except Exception as e:
        print(f"  错误: {e}")
        return False

def test_knowledge_target_detail():
    """测试靶点详情"""
    print_section("6. 靶点详情查询")
    try:
        r = requests.get(f"{BASE_URL}/api/v1/knowledge/target/EGFR")
        data = r.json()
        print(f"  状态码: {r.status_code}")
        info = data.get("data", {})
        print(f"  名称: {info.get('name')}")
        print(f"  全称: {info.get('full_name')}")
        print(f"  家族: {info.get('family')}")
        print(f"  已知药物: {', '.join(info.get('known_drugs', [])[:3])}")
        print(f"  相关疾病: {', '.join(info.get('related_diseases', [])[:3])}")
        return r.status_code == 200
    except Exception as e:
        print(f"  错误: {e}")
        return False

def test_knowledge_admet():
    """测试ADMET规则"""
    print_section("7. ADMET规则")
    try:
        r = requests.get(f"{BASE_URL}/api/v1/knowledge/admet-rules")
        data = r.json()
        print(f"  状态码: {r.status_code}")
        rules = data.get("data", [])
        print(f"  规则数量: {len(rules)}")
        for rule in rules:
            print(f"    • {rule['name']} (可靠性:{rule['reliability']})")
        return r.status_code == 200 and len(rules) > 0
    except Exception as e:
        print(f"  错误: {e}")
        return False

def test_knowledge_evaluate():
    """测试ADMET评估"""
    print_section("8. ADMET性质评估")
    try:
        properties = {
            "MW": 450,
            "LogP": 3.5,
            "HBD": 2,
            "HBA": 5,
            "QED": 0.75,
        }
        r = requests.post(f"{BASE_URL}/api/v1/knowledge/evaluate-admet", json=properties)
        data = r.json()
        print(f"  状态码: {r.status_code}")
        results = data.get("data", {})
        for rule_name, result in results.items():
            icon = "✅" if result["passed"] else "❌"
            print(f"    {icon} {rule_name}: {'通过' if result['passed'] else '不通过'}")
            if result["violations"]:
                print(f"       违规: {result['violations']}")
        return r.status_code == 200
    except Exception as e:
        print(f"  错误: {e}")
        return False

def test_analyzer():
    """测试需求分析Agent"""
    print_section("9. 需求分析Agent")
    profile = {
        "name": "张三",
        "institution": "某某大学",
        "research_field": "抗肿瘤药物",
        "target_protein": "EGFR",
        "experience_level": "中级"
    }
    try:
        r = requests.post(f"{BASE_URL}/api/v1/analyze", json=profile)
        data = r.json()
        print(f"  状态码: {r.status_code}")
        result = data.get("data", {})
        print(f"  研究领域: {result.get('extracted_needs', {}).get('research_domain', '')}")

        # 检查知识增强
        ke = result.get('knowledge_enhancement', {})
        if ke:
            print(f"  知识增强: {ke.get('target_full_name')} ({ke.get('difficulty')})")
        return r.status_code == 200
    except Exception as e:
        print(f"  错误: {e}")
        return False

def test_pipeline():
    """测试完整Pipeline"""
    print_section("10. 完整Pipeline (核心接口)")
    profile = {
        "name": "张三",
        "institution": "某某大学",
        "research_field": "抗肿瘤药物",
        "target_protein": "EGFR",
        "experience_level": "中级"
    }
    try:
        start = time.time()
        r = requests.post(f"{BASE_URL}/api/v1/pipeline", json=profile)
        elapsed = time.time() - start
        data = r.json()
        print(f"  状态码: {r.status_code}")
        print(f"  响应时间: {elapsed:.2f}s")

        result = data.get("data", {})
        print(f"  Pipeline状态: {result.get('pipeline_status', '')}")
        print(f"  知识增强: {result.get('knowledge_enhanced', False)}")
        print(f"  成功步骤: {result.get('successful_steps', 0)}/5")

        steps = result.get("steps", {})
        for agent_id, step in steps.items():
            icon = "✅" if step["status"] == "success" else "❌"
            print(f"    {icon} {agent_id}: {step['status']}")

        summary = result.get("summary", {})
        print(f"  研究员: {summary.get('researcher', '')}")
        print(f"  靶点: {summary.get('target', '')}")
        print(f"  生成分子: {summary.get('total_molecules', 0)}")
        print(f"  通过审核: {summary.get('passed_molecules', 0)}")

        # 检查靶点信息
        target_info = summary.get("target_info", {})
        if target_info:
            print(f"  靶点难度: {target_info.get('difficulty')}")

        return r.status_code == 200 and result.get("successful_steps", 0) >= 4
    except Exception as e:
        print(f"  错误: {e}")
        return False

def test_cognitive_researcher():
    """测试认知增强-研究员洞察"""
    print_section("11. 认知增强-研究员洞察")
    try:
        r = requests.get(f"{BASE_URL}/api/v1/cognitive/researcher/user_001")
        data = r.json()
        print(f"  状态码: {r.status_code}")
        result = data.get("data", {})
        print(f"  状态: {result.get('status')}")
        if result.get('status') == 'success':
            print(f"  反馈数: {result.get('feedback_count')}")
            print(f"  平均评分: {result.get('avg_rating')}")
        return r.status_code == 200
    except Exception as e:
        print(f"  错误: {e}")
        return False

def test_cognitive_target():
    """测试认知增强-靶点洞察"""
    print_section("12. 认知增强-靶点洞察")
    try:
        r = requests.get(f"{BASE_URL}/api/v1/cognitive/target/EGFR")
        data = r.json()
        print(f"  状态码: {r.status_code}")
        result = data.get("data", {})
        print(f"  状态: {result.get('status')}")
        if result.get('status') == 'success':
            print(f"  反馈数: {result.get('feedback_count')}")
            print(f"  平均评分: {result.get('avg_rating')}")
            ranges = result.get('optimal_ranges', {})
            for prop, range_info in ranges.items():
                print(f"    • {prop}: {range_info.get('min')}-{range_info.get('max')} (推荐:{range_info.get('recommended')})")
        return r.status_code == 200
    except Exception as e:
        print(f"  错误: {e}")
        return False

def test_fpga_status():
    """测试FPGA状态"""
    print_section("13. FPGA状态")
    try:
        r = requests.get(f"{BASE_URL}/api/v1/fpga/status")
        data = r.json()
        print(f"  状态码: {r.status_code}")
        result = data.get("data", {})
        print(f"  已连接: {result.get('connected')}")
        print(f"  已启用: {result.get('enabled')}")
        print(f"  地址: {result.get('host')}:{result.get('port')}")
        return r.status_code == 200
    except Exception as e:
        print(f"  错误: {e}")
        return False

def test_fpga_performance():
    """测试FPGA性能报告"""
    print_section("14. FPGA性能报告")
    try:
        r = requests.get(f"{BASE_URL}/api/v1/fpga/performance")
        data = r.json()
        print(f"  状态码: {r.status_code}")
        result = data.get("data", {})
        print(f"  总请求: {result.get('total_requests')}")
        print(f"  错误率: {result.get('error_rate')}")
        print(f"  平均计算时间: {result.get('avg_compute_time_ms')}ms")
        print(f"  预估加速比: {result.get('estimated_speedup')}")
        return r.status_code == 200
    except Exception as e:
        print(f"  错误: {e}")
        return False

def test_monitor():
    """测试监控统计"""
    print_section("15. 请求监控统计")
    try:
        r = requests.get(f"{BASE_URL}/api/v1/monitor/requests")
        data = r.json()
        print(f"  状态码: {r.status_code}")
        result = data.get("data", {})
        print(f"  总请求: {result.get('total_requests')}")
        print(f"  总错误: {result.get('total_errors')}")
        print(f"  错误率: {result.get('error_rate')}")
        return r.status_code == 200
    except Exception as e:
        print(f"  错误: {e}")
        return False

def test_history():
    """测试历史记录"""
    print_section("16. 历史记录")
    try:
        r = requests.get(f"{BASE_URL}/api/v1/history?limit=5")
        data = r.json()
        print(f"  状态码: {r.status_code}")
        result = data.get("data", {})
        print(f"  总记录: {result.get('total_records')}")
        print(f"  返回数: {result.get('returned')}")
        return r.status_code == 200
    except Exception as e:
        print(f"  错误: {e}")
        return False

def test_molecule_properties():
    """测试分子性质(含ADMET)"""
    print_section("17. 分子性质计算(增强版)")
    smiles = "CC(=O)Oc1ccccc1C(=O)O"
    try:
        r = requests.get(f"{BASE_URL}/api/v1/molecule/properties?smiles={smiles}")
        data = r.json()
        print(f"  状态码: {r.status_code}")
        result = data.get("data", {})
        props = result.get("properties", {})
        print(f"  分子量: {props.get('molwt')}")
        print(f"  QED: {props.get('qed')}")

        admet = result.get("admet_evaluation", {})
        print(f"  ADMET评估 ({len(admet)}条规则):")
        for rule_name, eval_result in list(admet.items())[:3]:
            icon = "✅" if eval_result["passed"] else "❌"
            print(f"    {icon} {rule_name}")
        return r.status_code == 200
    except Exception as e:
        print(f"  错误: {e}")
        return False

def run_all_tests():
    """运行所有测试"""
    print("=" * 60)
    print("药物分子设计平台 - 云之脑架构测试 v3")
    print("=" * 60)

    tests = [
        ("根路由", test_root),
        ("健康检查", test_health),
        ("系统信息", test_system_info),
        ("Agent状态", test_agents_status),
        ("靶点知识库", test_knowledge_targets),
        ("靶点详情", test_knowledge_target_detail),
        ("ADMET规则", test_knowledge_admet),
        ("ADMET评估", test_knowledge_evaluate),
        ("需求分析", test_analyzer),
        ("完整Pipeline", test_pipeline),
        ("认知-研究员", test_cognitive_researcher),
        ("认知-靶点", test_cognitive_target),
        ("FPGA状态", test_fpga_status),
        ("FPGA性能", test_fpga_performance),
        ("监控统计", test_monitor),
        ("历史记录", test_history),
        ("分子性质", test_molecule_properties),
    ]

    results = []
    for name, test_func in tests:
        try:
            passed = test_func()
            results.append((name, passed))
        except Exception as e:
            print(f"\n[ERROR] {name} 测试异常: {e}")
            results.append((name, False))
        time.sleep(0.3)

    # 汇总
    print("\n" + "=" * 60)
    print("测试结果汇总")
    print("=" * 60)
    passed_count = sum(1 for _, p in results if p)
    for name, passed in results:
        icon = "✅ PASS" if passed else "❌ FAIL"
        print(f"  {icon} {name}")
    print(f"\n总计: {passed_count}/{len(results)} 通过")

    if passed_count == len(results):
        print("\n🎉 所有测试通过！云之脑架构完整运行！")
    elif passed_count >= len(results) * 0.8:
        print("\n✅ 大部分测试通过，系统基本可用")
    else:
        print("\n⚠️ 部分测试失败，请检查配置")

    return passed_count == len(results)

if __name__ == "__main__":
    run_all_tests()
