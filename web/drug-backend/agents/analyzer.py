"""
需求分析Agent (Analyzer)
功能：解析研究员画像，提取药物设计关键需求
"""
from typing import Dict, List, Any

class AnalyzerAgent:
    """需求分析Agent - 解析研究员画像"""

    def __init__(self):
        self.name = "需求分析Agent"
        # 研究领域 -> 常见靶点映射
        self.field_targets = {
            "抗肿瘤": ["EGFR", "HER2", "VEGF", "PD-1", "BCR-ABL", "ALK"],
            "抗病毒": ["HIV protease", "Neuraminidase", "RdRp", "3CLpro"],
            "抗菌": ["DNA gyrase", "Topoisomerase IV", "Beta-lactamase"],
            "抗炎": ["COX-2", "LOX", "TNF-alpha", "IL-6"],
            "神经系统": ["Dopamine D2", "Serotonin 5-HT", "GABA", "NMDA"],
            "心血管": ["ACE", "Angiotensin II", "HMG-CoA", "PDE5"],
        }
        # 经验等级 -> 设计复杂度
        self.complexity_map = {
            "初级": {"max_steps": 3, "detail_level": "基础"},
            "中级": {"max_steps": 5, "detail_level": "标准"},
            "高级": {"max_steps": 7, "detail_level": "高级"},
        }

    def analyze(self, profile: Dict[str, Any]) -> Dict[str, Any]:
        """
        分析研究员画像，提取设计需求

        Args:
            profile: 研究员画像，包含 name, institution, research_field, target_protein, experience_level

        Returns:
            分析结果，包含需求摘要、推荐靶点、设计复杂度等
        """
        result = {
            "agent": self.name,
            "status": "success",
            "profile_summary": {},
            "extracted_needs": {},
            "recommendations": {},
        }

        # 1. 提取基本信息
        result["profile_summary"] = {
            "researcher": profile.get("name", "未知"),
            "institution": profile.get("institution", "未知"),
            "field": profile.get("research_field", "未知"),
            "target": profile.get("target_protein", "未知"),
            "level": profile.get("experience_level", "中级"),
        }

        # 2. 分析研究领域
        field = profile.get("research_field", "")
        matched_field = self._match_field(field)
        result["extracted_needs"]["research_domain"] = matched_field

        # 3. 推荐相关靶点
        target = profile.get("target_protein", "")
        recommended_targets = self._recommend_targets(matched_field, target)
        result["extracted_needs"]["recommended_targets"] = recommended_targets

        # 4. 确定设计复杂度
        level = profile.get("experience_level", "中级")
        complexity = self.complexity_map.get(level, self.complexity_map["中级"])
        result["extracted_needs"]["design_complexity"] = complexity

        # 5. 生成需求摘要
        result["extracted_needs"]["requirement_summary"] = self._generate_summary(
            profile, matched_field, recommended_targets, complexity
        )

        # 6. 给出建议
        result["recommendations"] = {
            "suggested_libraries": self._suggest_libraries(matched_field),
            "suggested_methods": self._suggest_methods(matched_field),
            "priority": "high" if matched_field != "未知领域" else "medium",
        }

        return result

    def _match_field(self, field: str) -> str:
        """匹配研究领域"""
        field_lower = field.lower()
        for key in self.field_targets:
            if key in field_lower or any(kw in field_lower for kw in [key[:2], key[-2:]]):
                return key
        return "未知领域"

    def _recommend_targets(self, field: str, current_target: str) -> List[str]:
        """推荐相关靶点"""
        targets = self.field_targets.get(field, [])
        if current_target and current_target not in targets:
            # 如果用户指定了靶点，把它放第一个
            return [current_target] + [t for t in targets if t != current_target]
        return targets[:5] if targets else ["请指定具体靶点"]

    def _generate_summary(self, profile: Dict, field: str, targets: List[str], complexity: Dict) -> str:
        """生成需求摘要"""
        return (
            f"研究员 {profile.get('name', '未知')} 来自 {profile.get('institution', '未知')}，"
            f"专注于 {field} 领域，目标靶点为 {profile.get('target_protein', '未指定')}。"
            f"建议关注靶点：{', '.join(targets[:3])}。"
            f"设计复杂度：{complexity['detail_level']}（最多{complexity['max_steps']}步策略）。"
        )

    def _suggest_libraries(self, field: str) -> List[str]:
        """推荐化合物库"""
        library_map = {
            "抗肿瘤": ["ZINC抗肿瘤子集", "ChEMBL激酶抑制剂库", "FDA已批准抗肿瘤药"],
            "抗病毒": ["ZINC抗病毒子集", "ChEMBL抗病毒化合物", "天然产物抗病毒库"],
            "抗菌": ["ZINC抗菌子集", "ChEMBL抗生素", "天然产物抗菌库"],
            "抗炎": ["ChEMBL抗炎化合物", "COX-2抑制剂库", "天然产物抗炎库"],
            "神经系统": ["ChEMBL CNS化合物", "GPCR配体库", "血脑屏障穿透库"],
            "心血管": ["ChEMBL心血管化合物", "FDA心血管药物", "ACE抑制剂库"],
        }
        return library_map.get(field, ["ChEMBL通用化合物库", "ZINC通用库"])

    def _suggest_methods(self, field: str) -> List[str]:
        """推荐设计方法"""
        method_map = {
            "抗肿瘤": ["基于结构的药物设计(SBDD)", "分子对接", "药效团建模"],
            "抗病毒": ["虚拟筛选", "基于片段的药物设计", "共价抑制剂设计"],
            "抗菌": ["骨架跃迁", "生物等排体替换", "ADMET优化"],
            "抗炎": ["配体-based设计", "QSAR建模", "多靶点药物设计"],
            "神经系统": ["CNS渗透性优化", "血脑屏障预测", "GPCR建模"],
            "心血管": ["ADMET优化", "心脏毒性预测", "代谢稳定性优化"],
        }
        return method_map.get(field, ["虚拟筛选", "分子对接", "药效团建模"])


# 单例实例
analyzer_agent = AnalyzerAgent()
