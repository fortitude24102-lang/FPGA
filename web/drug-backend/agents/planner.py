"""
策略规划Agent (Planner)
功能：根据需求分析结果，生成药物设计策略和步骤
"""
from typing import Dict, List, Any

class PlannerAgent:
    """策略规划Agent - 生成药物设计策略"""

    def __init__(self):
        self.name = "策略规划Agent"

    def plan(self, analysis_result: Dict[str, Any]) -> Dict[str, Any]:
        """
        根据分析结果生成设计策略

        Args:
            analysis_result: Analyzer的输出结果

        Returns:
            策略规划结果，包含设计步骤、时间线、资源需求
        """
        needs = analysis_result.get("extracted_needs", {})
        complexity = needs.get("design_complexity", {"max_steps": 5, "detail_level": "标准"})
        field = needs.get("research_domain", "通用")
        targets = needs.get("recommended_targets", [])
        methods = analysis_result.get("recommendations", {}).get("suggested_methods", [])

        result = {
            "agent": self.name,
            "status": "success",
            "strategy_overview": {},
            "design_steps": [],
            "timeline": {},
            "resources": {},
        }

        # 1. 策略概览
        result["strategy_overview"] = {
            "approach": self._determine_approach(field, methods),
            "target_focus": targets[0] if targets else "未指定",
            "complexity_level": complexity["detail_level"],
            "estimated_duration": self._estimate_duration(complexity["max_steps"]),
        }

        # 2. 生成设计步骤
        result["design_steps"] = self._generate_steps(
            field, targets, methods, complexity["max_steps"]
        )

        # 3. 时间线
        result["timeline"] = self._generate_timeline(result["design_steps"])

        # 4. 资源需求
        result["resources"] = {
            "computational": ["RDKit分子生成", "分子对接软件", "ADMET预测工具"],
            "databases": analysis_result.get("recommendations", {}).get("suggested_libraries", []),
            "hardware": ["GPU加速(推荐)", "FPGA分子指纹计算(可选)"],
        }

        return result

    def _determine_approach(self, field: str, methods: List[str]) -> str:
        """确定设计方法"""
        if "基于结构" in str(methods):
            return "基于结构的药物设计 (Structure-Based Drug Design)"
        elif "基于片段" in str(methods):
            return "基于片段的药物设计 (Fragment-Based Drug Design)"
        elif "配体" in str(methods):
            return "基于配体的药物设计 (Ligand-Based Drug Design)"
        return "综合药物设计方法 (Hybrid Approach)"

    def _estimate_duration(self, max_steps: int) -> str:
        """估算时间"""
        duration_map = {3: "1-2周", 5: "2-4周", 7: "4-6周"}
        return duration_map.get(max_steps, "2-4周")

    def _generate_steps(self, field: str, targets: List[str], methods: List[str], max_steps: int) -> List[Dict]:
        """生成设计步骤"""
        base_steps = [
            {
                "step_id": 1,
                "name": "靶点验证与结构准备",
                "description": f"验证靶点 {targets[0] if targets else '指定靶点'} 的结构信息，准备蛋白质三维结构",
                "tools": ["PDB数据库", "AlphaFold", "结构优化工具"],
                "output": "准备好的靶点结构文件",
                "duration": "2-3天",
            },
            {
                "step_id": 2,
                "name": "化合物库准备",
                "description": "构建或选择合适的化合物库，进行初步过滤",
                "tools": ["RDKit", "ChEMBL", "ZINC数据库"],
                "output": "过滤后的候选化合物库",
                "duration": "1-2天",
            },
            {
                "step_id": 3,
                "name": "虚拟筛选",
                "description": "使用分子对接或药效团筛选化合物库",
                "tools": ["分子对接", "药效团匹配", "相似性搜索"],
                "output": "初步命中化合物列表",
                "duration": "2-3天",
            },
            {
                "step_id": 4,
                "name": "分子生成与优化",
                "description": "基于命中化合物生成新分子，优化性质",
                "tools": ["RDKit分子生成", "骨架跃迁", "生物等排体替换"],
                "output": "新生成的候选分子集",
                "duration": "3-5天",
            },
            {
                "step_id": 5,
                "name": "ADMET性质预测",
                "description": "预测候选分子的吸收、分布、代谢、排泄和毒性",
                "tools": ["ADMET预测模型", "Lipinski规则", "QED计算"],
                "output": "ADMET评估报告",
                "duration": "1-2天",
            },
            {
                "step_id": 6,
                "name": "合成可及性评估",
                "description": "评估候选分子的合成难度",
                "tools": ["SAscore", "合成路线规划", "反应数据库"],
                "output": "合成可行性排名",
                "duration": "1-2天",
            },
            {
                "step_id": 7,
                "name": "最终候选分子确定",
                "description": "综合评分，确定最终候选分子进行实验验证",
                "tools": ["多目标优化", "专家系统", "决策支持"],
                "output": "最终候选分子列表及详细报告",
                "duration": "1-2天",
            },
        ]

        # 根据复杂度截断步骤
        steps = base_steps[:max_steps]

        # 为每个步骤添加字段特定建议
        for step in steps:
            step["field_notes"] = self._get_field_notes(field, step["step_id"])

        return steps

    def _get_field_notes(self, field: str, step_id: int) -> str:
        """获取领域特定建议"""
        notes = {
            "抗肿瘤": {
                1: "重点关注激酶结构域的ATP结合口袋",
                3: "考虑选择性过滤，避免脱靶效应",
                4: "引入靶向基团提高选择性",
            },
            "抗病毒": {
                1: "关注病毒蛋白的保守区域",
                3: "考虑耐药突变位点",
                4: "设计共价抑制剂增强结合",
            },
            "抗菌": {
                1: "区分革兰氏阳性/阴性菌靶点",
                3: "过滤已知的抗生素结构",
                5: "特别注意细菌外膜穿透性",
            },
        }
        return notes.get(field, {}).get(step_id, "标准流程")

    def _generate_timeline(self, steps: List[Dict]) -> Dict[str, Any]:
        """生成时间线"""
        total_days = sum([int(s["duration"].split("-")[0].replace("天", "")) for s in steps])
        return {
            "total_steps": len(steps),
            "estimated_days": f"{total_days}-{total_days + len(steps) * 2}天",
            "milestones": [
                {"phase": "前期准备", "steps": [1, 2], "duration": "3-5天"},
                {"phase": "筛选与生成", "steps": [3, 4], "duration": "5-8天"},
                {"phase": "评估与决策", "steps": list(range(5, len(steps) + 1)), "duration": "3-6天"},
            ],
        }


# 单例实例
planner_agent = PlannerAgent()
