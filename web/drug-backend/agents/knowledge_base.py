"""
知识中心 (Knowledge Base)
功能：提供药物设计相关的知识图谱、靶点信息、ADMET经验规则
对应云之脑架构：知识中心组件
"""
from typing import Dict, List, Any, Optional
from dataclasses import dataclass

@dataclass
class TargetInfo:
    """靶点信息"""
    name: str
    full_name: str
    family: str
    related_diseases: List[str]
    known_drugs: List[str]
    pdb_ids: List[str]
    difficulty: str  # easy/medium/hard
    popularity: int  # 1-10

@dataclass
class DrugClass:
    """药物分类"""
    name: str
    description: str
    typical_scaffolds: List[str]
    common_targets: List[str]
    admet_profile: Dict[str, Any]

@dataclass
class ADMETRule:
    """ADMET经验规则"""
    name: str
    description: str
    thresholds: Dict[str, Any]
    source: str
    reliability: float  # 0-1


class KnowledgeBase:
    """药物设计知识中心"""

    def __init__(self):
        self._init_targets()
        self._init_drug_classes()
        self._init_admet_rules()
        self._init_scaffolds()

    def _init_targets(self):
        """初始化靶点知识库"""
        self.targets = {
            "EGFR": TargetInfo(
                name="EGFR",
                full_name="Epidermal Growth Factor Receptor",
                family="Receptor Tyrosine Kinase",
                related_diseases=["非小细胞肺癌", "结直肠癌", "胶质母细胞瘤"],
                known_drugs=["吉非替尼", "厄洛替尼", "奥希替尼", "阿法替尼"],
                pdb_ids=["1M17", "2ITW", "3W2Q"],
                difficulty="medium",
                popularity=9,
            ),
            "HER2": TargetInfo(
                name="HER2",
                full_name="Human Epidermal Growth Factor Receptor 2",
                family="Receptor Tyrosine Kinase",
                related_diseases=["乳腺癌", "胃癌", "卵巢癌"],
                known_drugs=["曲妥珠单抗", "帕妥珠单抗", "拉帕替尼", "T-DM1"],
                pdb_ids=["3PP0", "3WSQ"],
                difficulty="hard",
                popularity=8,
            ),
            "VEGF": TargetInfo(
                name="VEGF",
                full_name="Vascular Endothelial Growth Factor",
                family="Growth Factor",
                related_diseases=["结直肠癌", "肺癌", "肾细胞癌", "黄斑变性"],
                known_drugs=["贝伐珠单抗", "阿柏西普", "雷珠单抗"],
                pdb_ids=["1BJ1", "2QUH"],
                difficulty="hard",
                popularity=7,
            ),
            "PD-1": TargetInfo(
                name="PD-1",
                full_name="Programmed Cell Death Protein 1",
                family="Immune Checkpoint",
                related_diseases=["黑色素瘤", "非小细胞肺癌", "霍奇金淋巴瘤", "肾癌"],
                known_drugs=["帕博利珠单抗", "纳武利尤单抗", "特瑞普利单抗"],
                pdb_ids=["3RRQ", "5GGS"],
                difficulty="hard",
                popularity=10,
            ),
            "BCR-ABL": TargetInfo(
                name="BCR-ABL",
                full_name="Breakpoint Cluster Region-Abelson",
                family="Tyrosine Kinase",
                related_diseases=["慢性髓性白血病", "急性淋巴细胞白血病"],
                known_drugs=["伊马替尼", "达沙替尼", "尼洛替尼", "博舒替尼"],
                pdb_ids=["1IEP", "2HYY"],
                difficulty="medium",
                popularity=7,
            ),
            "ALK": TargetInfo(
                name="ALK",
                full_name="Anaplastic Lymphoma Kinase",
                family="Receptor Tyrosine Kinase",
                related_diseases=["非小细胞肺癌", "间变性大细胞淋巴瘤"],
                known_drugs=["克唑替尼", "艾乐替尼", "布加替尼", "劳拉替尼"],
                pdb_ids=["2XP2", "4FNW"],
                difficulty="medium",
                popularity=6,
            ),
            "HIV protease": TargetInfo(
                name="HIV protease",
                full_name="HIV-1 Protease",
                family="Aspartic Protease",
                related_diseases=["艾滋病"],
                known_drugs=["洛匹那韦", "达芦那韦", "阿扎那韦"],
                pdb_ids=["1HSG", "3OXC"],
                difficulty="medium",
                popularity=6,
            ),
            "3CLpro": TargetInfo(
                name="3CLpro",
                full_name="3C-like Protease",
                family="Cysteine Protease",
                related_diseases=["COVID-19", "SARS", "MERS"],
                known_drugs=["奈玛特韦", "恩司特韦"],
                pdb_ids=["6LU7", "7BQY"],
                difficulty="medium",
                popularity=8,
            ),
            "COX-2": TargetInfo(
                name="COX-2",
                full_name="Cyclooxygenase-2",
                family="Oxidoreductase",
                related_diseases=["关节炎", "疼痛", "炎症"],
                known_drugs=["塞来昔布", "罗非昔布", "依托考昔"],
                pdb_ids=["1CX2", "3LN1"],
                difficulty="easy",
                popularity=5,
            ),
            "ACE": TargetInfo(
                name="ACE",
                full_name="Angiotensin-Converting Enzyme",
                family="Metallopeptidase",
                related_diseases=["高血压", "心力衰竭", "糖尿病肾病"],
                known_drugs=["卡托普利", "依那普利", "贝那普利", "雷米普利"],
                pdb_ids=["1O86", "2XY9"],
                difficulty="easy",
                popularity=5,
            ),
            "Dopamine D2": TargetInfo(
                name="Dopamine D2",
                full_name="Dopamine Receptor D2",
                family="GPCR",
                related_diseases=["精神分裂症", "帕金森病", "抑郁症"],
                known_drugs=["氯丙嗪", "利培酮", "阿立哌唑"],
                pdb_ids=["6CM4", "7DFP"],
                difficulty="hard",
                popularity=6,
            ),
        }

    def _init_drug_classes(self):
        """初始化药物分类知识"""
        self.drug_classes = {
            "激酶抑制剂": DrugClass(
                name="激酶抑制剂",
                description="靶向激酶ATP结合口袋的小分子抑制剂",
                typical_scaffolds=["喹唑啉", "吡啶并嘧啶", "吡咯并吡啶"],
                common_targets=["EGFR", "HER2", "BCR-ABL", "ALK"],
                admet_profile={
                    "typical_mw": "400-550",
                    "typical_logp": "2-4",
                    "typical_tpsa": "80-120",
                    "bioavailability": "中等",
                    "metabolism": "CYP3A4",
                }
            ),
            "GPCR配体": DrugClass(
                name="GPCR配体",
                description="靶向G蛋白偶联受体的配体分子",
                typical_scaffolds=["吲哚", "哌啶", "苯并氮杂卓"],
                common_targets=["Dopamine D2", "Serotonin 5-HT", "GABA"],
                admet_profile={
                    "typical_mw": "300-500",
                    "typical_logp": "1-4",
                    "typical_tpsa": "40-90",
                    "bioavailability": "中等",
                    "metabolism": "CYP2D6",
                }
            ),
            "蛋白酶抑制剂": DrugClass(
                name="蛋白酶抑制剂",
                description="模拟肽键过渡态的蛋白酶抑制剂",
                typical_scaffolds=["羟乙胺", "环脲", "磺酰胺"],
                common_targets=["HIV protease", "3CLpro"],
                admet_profile={
                    "typical_mw": "500-700",
                    "typical_logp": "1-3",
                    "typical_tpsa": "120-180",
                    "bioavailability": "低-中等",
                    "metabolism": "CYP3A4",
                }
            ),
            "单克隆抗体": DrugClass(
                name="单克隆抗体",
                description="大分子生物制剂，靶向细胞表面蛋白",
                typical_scaffolds=["不适用"],
                common_targets=["PD-1", "HER2", "VEGF"],
                admet_profile={
                    "typical_mw": ">150000",
                    "route": "静脉注射",
                    "bioavailability": "不适用",
                    "metabolism": "蛋白酶降解",
                }
            ),
        }

    def _init_admet_rules(self):
        """初始化ADMET经验规则"""
        self.admet_rules = {
            "Lipinski五规则": ADMETRule(
                name="Lipinski五规则",
                description="口服药物的经典筛选规则",
                thresholds={
                    "MW": {"max": 500, "unit": "Da"},
                    "LogP": {"max": 5},
                    "HBD": {"max": 5},
                    "HBA": {"max": 10},
                },
                source="Lipinski et al., 1997",
                reliability=0.85,
            ),
            "Veber规则": ADMETRule(
                name="Veber规则",
                description="口服生物利用度的补充规则",
                thresholds={
                    "rotatable_bonds": {"max": 10},
                    "TPSA": {"max": 140, "unit": "Å²"},
                },
                source="Veber et al., 2002",
                reliability=0.80,
            ),
            "Pfizer3/75规则": ADMETRule(
                name="Pfizer 3/75规则",
                description="预测药物毒性的经验规则",
                thresholds={
                    "LogP": {"max": 3},
                    "TPSA": {"min": 75, "unit": "Å²"},
                },
                source="Hughes et al., 2008",
                reliability=0.75,
            ),
            "Ghose规则": ADMETRule(
                name="Ghose规则",
                description="基于药物数据库的理化性质范围",
                thresholds={
                    "MW": {"min": 160, "max": 480},
                    "LogP": {"min": -0.4, "max": 5.6},
                    "refractivity": {"min": 40, "max": 130},
                    "atoms": {"min": 20, "max": 70},
                },
                source="Ghose et al., 1999",
                reliability=0.78,
            ),
            "QED规则": ADMETRule(
                name="QED药物相似性",
                description="综合药物相似性评分",
                thresholds={
                    "QED": {"min": 0.5, "ideal": ">0.7"},
                },
                source="Bickerton et al., 2012",
                reliability=0.82,
            ),
            "BBB穿透规则": ADMETRule(
                name="血脑屏障穿透",
                description="预测分子能否穿过血脑屏障",
                thresholds={
                    "MW": {"max": 400},
                    "LogP": {"min": 1, "max": 4},
                    "TPSA": {"max": 90},
                    "HBD": {"max": 3},
                },
                source="Pajouhesh & Lenz, 2005",
                reliability=0.70,
            ),
        }

    def _init_scaffolds(self):
        """初始化常见药物骨架"""
        self.scaffolds = {
            "喹唑啉": {
                "smiles": "c1ccc2ncncc2c1",
                "description": "EGFR抑制剂常见骨架",
                "examples": ["吉非替尼", "厄洛替尼"],
            },
            "吡啶并嘧啶": {
                "smiles": "c1cnc2nccnc2c1",
                "description": "激酶抑制剂骨架",
                "examples": ["伊马替尼"],
            },
            "吲哚": {
                "smiles": "c1ccc2[nH]ccc2c1",
                "description": "GPCR配体常见骨架",
                "examples": ["舒马曲坦"],
            },
            "苯并咪唑": {
                "smiles": "c1ccc2[nH]cnc2c1",
                "description": "质子泵抑制剂骨架",
                "examples": ["奥美拉唑"],
            },
            "磺酰胺": {
                "smiles": "NS(=O)(=O)c1ccccc1",
                "description": "COX-2抑制剂骨架",
                "examples": ["塞来昔布"],
            },
        }

    # ==================== 查询接口 ====================

    def get_target_info(self, target_name: str) -> Optional[TargetInfo]:
        """获取靶点信息"""
        # 模糊匹配
        for key, info in self.targets.items():
            if target_name.lower() in key.lower() or key.lower() in target_name.lower():
                return info
        return None

    def get_related_targets(self, target_name: str) -> List[str]:
        """获取相关靶点"""
        info = self.get_target_info(target_name)
        if not info:
            return []
        # 同家族的靶点
        related = [
            name for name, t in self.targets.items()
            if t.family == info.family and name != info.name
        ]
        return related[:5]

    def get_drug_class_for_target(self, target_name: str) -> Optional[DrugClass]:
        """获取靶点对应的药物分类"""
        for name, dc in self.drug_classes.items():
            if any(target_name.lower() in t.lower() for t in dc.common_targets):
                return dc
        return None

    def get_admet_rules(self) -> Dict[str, ADMETRule]:
        """获取所有ADMET规则"""
        return self.admet_rules

    def evaluate_admet(self, properties: Dict[str, float]) -> Dict[str, Any]:
        """评估分子ADMET性质"""
        results = {}

        for rule_name, rule in self.admet_rules.items():
            violations = []
            passed = True

            for prop, threshold in rule.thresholds.items():
                value = properties.get(prop.lower(), None)
                if value is None:
                    continue

                if "min" in threshold and value < threshold["min"]:
                    violations.append(f"{prop}={value} < 最小值{threshold['min']}")
                    passed = False
                if "max" in threshold and value > threshold["max"]:
                    violations.append(f"{prop}={value} > 最大值{threshold['max']}")
                    passed = False

            results[rule_name] = {
                "passed": passed,
                "violations": violations,
                "reliability": rule.reliability,
                "source": rule.source,
            }

        return results

    def get_scaffold_suggestions(self, target_name: str) -> List[Dict]:
        """获取靶点相关的骨架建议"""
        dc = self.get_drug_class_for_target(target_name)
        if not dc:
            return []

        suggestions = []
        for scaffold_name in dc.typical_scaffolds:
            if scaffold_name in self.scaffolds:
                suggestions.append(self.scaffolds[scaffold_name])

        return suggestions

    def get_target_statistics(self) -> Dict[str, Any]:
        """获取靶点统计信息"""
        return {
            "total_targets": len(self.targets),
            "families": list(set(t.family for t in self.targets.values())),
            "difficulty_distribution": {
                "easy": sum(1 for t in self.targets.values() if t.difficulty == "easy"),
                "medium": sum(1 for t in self.targets.values() if t.difficulty == "medium"),
                "hard": sum(1 for t in self.targets.values() if t.difficulty == "hard"),
            },
            "top_targets": sorted(
                [(name, t.popularity) for name, t in self.targets.items()],
                key=lambda x: x[1],
                reverse=True
            )[:5],
        }


# 单例实例
knowledge_base = KnowledgeBase()
