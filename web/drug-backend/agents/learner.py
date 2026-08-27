"""
反馈学习Agent (Learner)
功能：记录用户反馈，优化后续推荐策略
"""
from typing import Dict, List, Any
from datetime import datetime
import json
import os

class LearnerAgent:
    """反馈学习Agent - 持续优化推荐"""

    def __init__(self):
        self.name = "反馈学习Agent"
        self.feedback_db = []  # 内存中的反馈记录
        self.db_file = "feedback_db.json"
        self._load_feedback()

        # 学习参数
        self.learning_rate = 0.1
        self.preference_weights = {
            "qed": 0.25,
            "sa_score": 0.20,
            "mw": 0.15,
            "logp": 0.15,
            "tpsa": 0.15,
            "lipinski": 0.10,
        }

    def _load_feedback(self):
        """从文件加载历史反馈"""
        if os.path.exists(self.db_file):
            try:
                with open(self.db_file, 'r', encoding='utf-8') as f:
                    self.feedback_db = json.load(f)
            except:
                self.feedback_db = []

    def _save_feedback(self):
        """保存反馈到文件"""
        with open(self.db_file, 'w', encoding='utf-8') as f:
            json.dump(self.feedback_db, f, ensure_ascii=False, indent=2)

    def record_feedback(self, feedback: Dict[str, Any]) -> Dict[str, Any]:
        """
        记录用户对生成分子的反馈

        Args:
            feedback: {
                "molecule_id": "...",
                "smiles": "...",
                "rating": 1-5,  # 用户评分
                "comments": "...",
                "researcher_id": "...",
                "target_protein": "...",
            }

        Returns:
            记录结果
        """
        record = {
            "id": len(self.feedback_db) + 1,
            "timestamp": datetime.now().isoformat(),
            "molecule_id": feedback.get("molecule_id", ""),
            "smiles": feedback.get("smiles", ""),
            "rating": feedback.get("rating", 3),
            "comments": feedback.get("comments", ""),
            "researcher_id": feedback.get("researcher_id", "anonymous"),
            "target_protein": feedback.get("target_protein", ""),
            "properties": feedback.get("properties", {}),
        }

        self.feedback_db.append(record)
        self._save_feedback()

        # 更新偏好权重
        self._update_preferences(record)

        return {
            "agent": self.name,
            "status": "success",
            "record_id": record["id"],
            "message": "反馈已记录",
            "current_stats": self._get_stats(),
        }

    def _update_preferences(self, record: Dict):
        """根据反馈更新偏好权重"""
        rating = record.get("rating", 3)
        props = record.get("properties", {})

        # 正反馈(rating >= 4): 增强对应特征的权重
        # 负反馈(rating <= 2): 降低对应特征的权重
        adjustment = (rating - 3) * self.learning_rate

        if "qed" in props:
            if props["qed"] > 0.6:
                self.preference_weights["qed"] += adjustment * 0.1

        if "sa_score" in props:
            if props["sa_score"] < 3:
                self.preference_weights["sa_score"] += adjustment * 0.1

        if "molwt" in props:
            if 300 <= props["molwt"] <= 500:
                self.preference_weights["mw"] += adjustment * 0.05

        # 归一化权重
        total = sum(self.preference_weights.values())
        self.preference_weights = {k: round(v / total, 3) for k, v in self.preference_weights.items()}

    def get_recommendations(self, target_protein: str = "", researcher_id: str = "") -> Dict[str, Any]:
        """
        基于历史反馈给出优化建议

        Returns:
            优化建议
        """
        # 筛选相关反馈
        relevant = [
            f for f in self.feedback_db
            if (not target_protein or f.get("target_protein") == target_protein)
            and (not researcher_id or f.get("researcher_id") == researcher_id)
        ]

        if not relevant:
            return {
                "agent": self.name,
                "status": "no_data",
                "message": "暂无相关反馈数据",
                "suggestions": self._get_default_suggestions(),
            }

        # 分析偏好
        avg_rating = sum(f["rating"] for f in relevant) / len(relevant)
        high_rated = [f for f in relevant if f["rating"] >= 4]
        low_rated = [f for f in relevant if f["rating"] <= 2]

        suggestions = []

        # 分析高分分子的共同特征
        if high_rated:
            avg_qed = sum(f["properties"].get("qed", 0) for f in high_rated) / len(high_rated)
            avg_sa = sum(f["properties"].get("sa_score", 5) for f in high_rated) / len(high_rated)
            avg_mw = sum(f["properties"].get("molwt", 400) for f in high_rated) / len(high_rated)

            suggestions.append(f"用户偏好QED较高的分子(平均{avg_qed:.2f})")
            suggestions.append(f"用户偏好合成难度较低的分子(SA平均{avg_sa:.1f})")
            if avg_mw < 400:
                suggestions.append("用户倾向于较小的分子(分子量<400)")

        # 分析低分分子的共同特征
        if low_rated:
            common_issues = []
            for f in low_rated:
                if not f["properties"].get("lipinski_pass", True):
                    common_issues.append("违反Lipinski规则")
                if f["properties"].get("sa_score", 5) > 5:
                    common_issues.append("合成难度过高")

            if common_issues:
                from collections import Counter
                issue_counts = Counter(common_issues)
                for issue, count in issue_counts.most_common(3):
                    suggestions.append(f"常见问题: {issue}({count}次反馈)")

        return {
            "agent": self.name,
            "status": "success",
            "feedback_count": len(relevant),
            "average_rating": round(avg_rating, 2),
            "high_rated_count": len(high_rated),
            "low_rated_count": len(low_rated),
            "current_weights": self.preference_weights,
            "suggestions": suggestions,
            "optimization_direction": self._get_optimization_direction(high_rated, low_rated),
        }

    def _get_stats(self) -> Dict:
        """获取统计信息"""
        if not self.feedback_db:
            return {"total_records": 0}

        ratings = [f["rating"] for f in self.feedback_db]
        return {
            "total_records": len(self.feedback_db),
            "average_rating": round(sum(ratings) / len(ratings), 2),
            "rating_distribution": {
                "5星": sum(1 for r in ratings if r == 5),
                "4星": sum(1 for r in ratings if r == 4),
                "3星": sum(1 for r in ratings if r == 3),
                "2星": sum(1 for r in ratings if r == 2),
                "1星": sum(1 for r in ratings if r == 1),
            },
        }

    def _get_default_suggestions(self) -> List[str]:
        """默认建议"""
        return [
            "优先生成QED > 0.6的分子",
            "控制SAscore < 4，确保合成可及性",
            "分子量控制在300-500范围",
            "LogP控制在1-3之间",
            "确保符合Lipinski五规则",
        ]

    def _get_optimization_direction(self, high_rated: List, low_rated: List) -> Dict:
        """获取优化方向"""
        direction = {
            "increase_importance": [],
            "decrease_importance": [],
            "maintain": [],
        }

        if high_rated:
            direction["increase_importance"].append("QED (药物相似性)")
            direction["increase_importance"].append("合成可及性(SAscore)")

        if low_rated:
            direction["decrease_importance"].append("大分子量(>500)")
            direction["decrease_importance"].append("高LogP(>5)")

        direction["maintain"] = ["Lipinski规则符合性", "合理的TPSA范围"]

        return direction


# 单例实例
learner_agent = LearnerAgent()
