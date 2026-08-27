"""
审核裁判Agent (Reviewer)
功能：对生成分子进行多维度打分、过滤和排序
"""
from typing import Dict, List, Any
import copy

from agents.fpga_model import hardware_score

try:
    from rdkit import Chem
    from rdkit.Chem import Descriptors, AllChem, QED
    from rdkit import DataStructs
    RDKIT_AVAILABLE = True
except ImportError:
    RDKIT_AVAILABLE = False


class ReviewerAgent:
    """审核裁判Agent - 分子质量评估"""

    def __init__(self):
        self.name = "审核裁判Agent"
        # 评分权重
        self.weights = {
            "lipinski": 0.25,      # Lipinski规则
            "qed": 0.25,           # 药物相似性
            "sa_score": 0.20,      # 合成可及性
            "mw": 0.10,            # 分子量
            "logp": 0.10,          # 脂溶性
            "tpsa": 0.10,          # 极性表面积
        }

    def review(self, generation_result: Dict[str, Any]) -> Dict[str, Any]:
        """
        审核生成分子

        Args:
            generation_result: Generator的输出结果

        Returns:
            审核结果，包含打分、过滤、排名
        """
        molecules = generation_result.get("generated_molecules", [])

        result = {
            "agent": self.name,
            "status": "success",
            "total_reviewed": len(molecules),
            "scoring_details": [],
            "filtered_molecules": [],
            "rejected_molecules": [],
            "top_candidates": [],
        }

        # 对每个分子进行评分
        scored_molecules = []
        for mol in molecules:
            scored = self._score_molecule(mol)
            scored_molecules.append(scored)

        # 排序
        scored_molecules.sort(key=lambda x: x["total_score"], reverse=True)

        # 分类：通过/不通过
        for mol in scored_molecules:
            score_detail = {
                "id": mol["id"],
                "smiles": mol["smiles"],
                "total_score": round(mol["total_score"], 3),
                "breakdown": mol["score_breakdown"],
                "verdict": mol["verdict"],
                "reasons": mol["reasons"],
            }
            result["scoring_details"].append(score_detail)

            if mol["verdict"] == "PASS":
                result["filtered_molecules"].append(mol)
            else:
                result["rejected_molecules"].append(mol)

        # 前N名候选
        result["top_candidates"] = result["filtered_molecules"][:5]

        # 统计
        result["statistics"] = {
            "pass_rate": len(result["filtered_molecules"]) / len(molecules) if molecules else 0,
            "avg_score": sum(m["total_score"] for m in scored_molecules) / len(scored_molecules) if scored_molecules else 0,
            "best_score": scored_molecules[0]["total_score"] if scored_molecules else 0,
            "worst_score": scored_molecules[-1]["total_score"] if scored_molecules else 0,
        }

        return result

    def _score_molecule(self, molecule: Dict) -> Dict:
        """对单个分子评分"""
        props = molecule.get("properties", {})

        # 复制分子数据
        scored = copy.deepcopy(molecule)
        scored["score_breakdown"] = {}
        scored["reasons"] = []

        # 1. Lipinski评分 (0-100)
        lipinski_score = self._score_lipinski(props)
        scored["score_breakdown"]["lipinski"] = round(lipinski_score, 1)

        # 2. QED评分 (0-100)
        qed_score = props.get("qed", 0) * 100
        scored["score_breakdown"]["qed"] = round(qed_score, 1)

        # 3. 合成可及性评分 (0-100, 分数越低越好)
        sa = props.get("sa_score", 5)
        sa_score = max(0, 100 - sa * 15)  # SA=0->100, SA=5->25, SA=10->0
        scored["score_breakdown"]["sa_score"] = round(sa_score, 1)

        # 4. 分子量评分 (最优范围: 300-500)
        mw = props.get("molwt", 400)
        if 300 <= mw <= 500:
            mw_score = 100
        elif 200 <= mw < 300:
            mw_score = 80 - (300 - mw) * 0.5
        elif 500 < mw <= 600:
            mw_score = 80 - (mw - 500) * 0.5
        else:
            mw_score = 30
        scored["score_breakdown"]["mw"] = round(mw_score, 1)

        # 5. LogP评分 (最优范围: 1-3)
        logp = props.get("logp", 2)
        if 1 <= logp <= 3:
            logp_score = 100
        elif -1 <= logp < 1:
            logp_score = 70 + (logp + 1) * 15
        elif 3 < logp <= 5:
            logp_score = 70 - (logp - 3) * 20
        else:
            logp_score = 20
        scored["score_breakdown"]["logp"] = round(logp_score, 1)

        # 6. TPSA评分 (最优范围: 40-120)
        tpsa = props.get("tpsa", 80)
        if 40 <= tpsa <= 120:
            tpsa_score = 100
        elif 20 <= tpsa < 40:
            tpsa_score = 80 - (40 - tpsa) * 2
        elif 120 < tpsa <= 160:
            tpsa_score = 80 - (tpsa - 120) * 1.5
        else:
            tpsa_score = 30
        scored["score_breakdown"]["tpsa"] = round(tpsa_score, 1)

        # 计算总分
        baseline_total = sum(
            scored["score_breakdown"][k] * self.weights[k]
            for k in self.weights
        )
        total = baseline_total
        hardware = hardware_score(scored.get("fpga_evaluation", {}))
        if hardware is not None:
            scored["score_breakdown"]["fpga_hardware"] = round(hardware, 1)
            total = 0.70 * baseline_total + 0.30 * hardware
            scored["ranking_effect"] = "blended_30_percent"
        scored["total_score"] = total

        # 判定
        if total >= 60 and props.get("lipinski_pass", False):
            scored["verdict"] = "PASS"
        elif total >= 50:
            scored["verdict"] = "CONDITIONAL"
            scored["reasons"].append("总分偏低，需要优化")
        else:
            scored["verdict"] = "REJECT"
            if not props.get("lipinski_pass", False):
                scored["reasons"].append(f"违反Lipinski规则({props.get('lipinski_violations', 0)}项)")
            if total < 50:
                scored["reasons"].append("综合评分过低")

        # 额外评价
        if props.get("qed", 0) > 0.7:
            scored["reasons"].append("优秀的药物相似性")
        if props.get("sa_score", 5) < 3:
            scored["reasons"].append("合成可及性良好")

        return scored

    def _score_lipinski(self, props: Dict) -> float:
        """Lipinski规则评分"""
        violations = props.get("lipinski_violations", 0)
        if violations == 0:
            return 100
        elif violations == 1:
            return 75
        elif violations == 2:
            return 40
        else:
            return 10

    def compare_molecules(self, smiles1: str, smiles2: str) -> Dict[str, Any]:
        """比较两个分子的相似性"""
        if not RDKIT_AVAILABLE:
            return {"similarity": 0.5, "method": "mock"}

        try:
            mol1 = Chem.MolFromSmiles(smiles1)
            mol2 = Chem.MolFromSmiles(smiles2)

            if not mol1 or not mol2:
                return {"similarity": 0, "error": "无效的SMILES"}

            fp1 = AllChem.GetMorganFingerprintAsBitVect(mol1, 2, nBits=2048)
            fp2 = AllChem.GetMorganFingerprintAsBitVect(mol2, 2, nBits=2048)

            tanimoto = DataStructs.TanimotoSimilarity(fp1, fp2)

            return {
                "similarity": round(tanimoto, 3),
                "method": "Tanimoto (Morgan fingerprint)",
                "interpretation": (
                    "高度相似" if tanimoto > 0.7 else
                    "中等相似" if tanimoto > 0.4 else
                    "低相似度"
                ),
            }
        except Exception as e:
            return {"similarity": 0, "error": str(e)}


# 单例实例
reviewer_agent = ReviewerAgent()
