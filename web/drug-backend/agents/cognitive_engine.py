"""
认知增强引擎 (Cognitive Engine)
功能：基于历史反馈进行深度学习优化，提升推荐质量
对应云之脑架构：认知系统
"""
from typing import Dict, List, Any, Optional
import json
import os
from collections import defaultdict
from datetime import datetime, timedelta

class CognitiveEngine:
    """认知增强引擎 - 持续学习优化"""

    def __init__(self):
        self.memory_file = "cognitive_memory.json"
        self.memory = self._load_memory()

        # 研究员偏好记忆
        self.researcher_profiles = self.memory.get("researcher_profiles", {})

        # 靶点特异性权重
        self.target_weights = self.memory.get("target_weights", {})

        # 生成策略记忆
        self.generation_strategies = self.memory.get("generation_strategies", {})

        # 成功案例库
        self.success_cases = self.memory.get("success_cases", [])

        # 失败案例分析
        self.failure_patterns = self.memory.get("failure_patterns", [])

    def _load_memory(self) -> Dict:
        """加载认知记忆"""
        if os.path.exists(self.memory_file):
            try:
                with open(self.memory_file, 'r', encoding='utf-8') as f:
                    return json.load(f)
            except:
                pass
        return {}

    def _save_memory(self):
        """保存认知记忆"""
        memory = {
            "researcher_profiles": self.researcher_profiles,
            "target_weights": self.target_weights,
            "generation_strategies": self.generation_strategies,
            "success_cases": self.success_cases[-100:],  # 只保留最近100个
            "failure_patterns": self.failure_patterns[-50:],
            "last_updated": datetime.now().isoformat(),
        }
        with open(self.memory_file, 'w', encoding='utf-8') as f:
            json.dump(memory, f, ensure_ascii=False, indent=2)

    def learn_from_feedback(self, feedback: Dict[str, Any]) -> Dict[str, Any]:
        """
        从反馈中学习

        Args:
            feedback: {
                "researcher_id": "...",
                "target_protein": "...",
                "molecule_id": "...",
                "smiles": "...",
                "rating": 1-5,
                "properties": {...},
                "generation_params": {...},
            }
        """
        researcher_id = feedback.get("researcher_id", "anonymous")
        target = feedback.get("target_protein", "")
        rating = feedback.get("rating", 3)
        props = feedback.get("properties", {})

        # 1. 学习研究员偏好
        self._learn_researcher_preference(researcher_id, rating, props)

        # 2. 学习靶点特异性
        if target:
            self._learn_target_specificity(target, rating, props)

        # 3. 记录成功/失败案例
        if rating >= 4:
            self._record_success(feedback)
        elif rating <= 2:
            self._record_failure(feedback)

        # 4. 优化生成策略
        self._optimize_generation_strategy(feedback)

        self._save_memory()

        return {
            "status": "learned",
            "researcher_id": researcher_id,
            "preference_updated": True,
            "target_weights_updated": bool(target),
        }

    def _learn_researcher_preference(self, researcher_id: str, rating: int, props: Dict):
        """学习研究员偏好"""
        if researcher_id not in self.researcher_profiles:
            self.researcher_profiles[researcher_id] = {
                "feedback_count": 0,
                "avg_rating": 0,
                "property_preferences": {},
                "preferred_targets": [],
            }

        profile = self.researcher_profiles[researcher_id]
        profile["feedback_count"] += 1

        # 更新平均评分
        n = profile["feedback_count"]
        profile["avg_rating"] = (profile["avg_rating"] * (n - 1) + rating) / n

        # 学习属性偏好
        for prop, value in props.items():
            if prop not in profile["property_preferences"]:
                profile["property_preferences"][prop] = {"values": [], "avg": 0}

            pref = profile["property_preferences"][prop]
            pref["values"].append(value)
            # 只保留最近20个值
            pref["values"] = pref["values"][-20:]
            pref["avg"] = sum(pref["values"]) / len(pref["values"])

    def _learn_target_specificity(self, target: str, rating: int, props: Dict):
        """学习靶点特异性权重"""
        if target not in self.target_weights:
            self.target_weights[target] = {
                "feedback_count": 0,
                "avg_rating": 0,
                "optimal_ranges": {},
                "scoring_adjustments": {},
            }

        tw = self.target_weights[target]
        tw["feedback_count"] += 1
        n = tw["feedback_count"]
        tw["avg_rating"] = (tw["avg_rating"] * (n - 1) + rating) / n

        # 学习最优属性范围
        key_props = ["molwt", "logp", "qed", "sa_score", "tpsa"]
        for prop in key_props:
            if prop in props:
                if prop not in tw["optimal_ranges"]:
                    tw["optimal_ranges"][prop] = []
                tw["optimal_ranges"][prop].append(props[prop])
                # 只保留最近30个值
                tw["optimal_ranges"][prop] = tw["optimal_ranges"][prop][-30:]

    def _record_success(self, feedback: Dict):
        """记录成功案例"""
        case = {
            "timestamp": datetime.now().isoformat(),
            "target": feedback.get("target_protein", ""),
            "smiles": feedback.get("smiles", ""),
            "rating": feedback.get("rating", 0),
            "properties": feedback.get("properties", {}),
            "generation_params": feedback.get("generation_params", {}),
        }
        self.success_cases.append(case)

    def _record_failure(self, feedback: Dict):
        """记录失败案例"""
        case = {
            "timestamp": datetime.now().isoformat(),
            "target": feedback.get("target_protein", ""),
            "smiles": feedback.get("smiles", ""),
            "rating": feedback.get("rating", 0),
            "properties": feedback.get("properties", {}),
            "reason": feedback.get("comments", ""),
        }
        self.failure_patterns.append(case)

    def _optimize_generation_strategy(self, feedback: Dict):
        """优化生成策略"""
        target = feedback.get("target_protein", "")
        if not target:
            return

        if target not in self.generation_strategies:
            self.generation_strategies[target] = {
                "attempts": 0,
                "success_rate": 0,
                "best_params": {},
            }

        gs = self.generation_strategies[target]
        gs["attempts"] += 1

        rating = feedback.get("rating", 3)
        # 更新成功率
        n = gs["attempts"]
        current_success = 1 if rating >= 4 else 0
        gs["success_rate"] = (gs["success_rate"] * (n - 1) + current_success) / n

    def get_enhanced_constraints(self, researcher_id: str, target: str) -> Dict[str, Any]:
        """
        获取增强的约束条件
        基于学习到的偏好优化生成参数
        """
        constraints = {}

        # 1. 研究员偏好约束
        if researcher_id in self.researcher_profiles:
            profile = self.researcher_profiles[researcher_id]
            prefs = profile.get("property_preferences", {})

            if "molwt" in prefs:
                avg_mw = prefs["molwt"]["avg"]
                constraints["target_molwt"] = {
                    "min": avg_mw * 0.8,
                    "max": avg_mw * 1.2,
                    "weight": 0.3,
                }

            if "logp" in prefs:
                avg_logp = prefs["logp"]["avg"]
                constraints["target_logp"] = {
                    "min": avg_logp - 1,
                    "max": avg_logp + 1,
                    "weight": 0.2,
                }

            if "qed" in prefs:
                constraints["min_qed"] = max(0.5, prefs["qed"]["avg"] - 0.1)

        # 2. 靶点特异性约束
        if target in self.target_weights:
            tw = self.target_weights[target]
            for prop, values in tw.get("optimal_ranges", {}).items():
                if len(values) >= 5:
                    avg = sum(values) / len(values)
                    std = (sum((v - avg) ** 2 for v in values) / len(values)) ** 0.5
                    constraints[f"target_{prop}"] = {
                        "min": avg - 2 * std,
                        "max": avg + 2 * std,
                        "weight": 0.25,
                    }

        # 3. 生成策略建议
        if target in self.generation_strategies:
            gs = self.generation_strategies[target]
            constraints["strategy_suggestion"] = {
                "success_rate": gs["success_rate"],
                "recommended_count": 5 if gs["success_rate"] > 0.6 else 10,
            }

        return constraints

    def get_researcher_insights(self, researcher_id: str) -> Dict[str, Any]:
        """获取研究员洞察"""
        if researcher_id not in self.researcher_profiles:
            return {"status": "no_data", "message": "暂无该研究员的数据"}

        profile = self.researcher_profiles[researcher_id]

        insights = {
            "status": "success",
            "researcher_id": researcher_id,
            "feedback_count": profile["feedback_count"],
            "avg_rating": round(profile["avg_rating"], 2),
            "property_preferences": {},
            "suggestions": [],
        }

        # 分析偏好
        for prop, data in profile["property_preferences"].items():
            insights["property_preferences"][prop] = {
                "average": round(data["avg"], 3),
                "sample_size": len(data["values"]),
            }

        # 生成建议
        if profile["avg_rating"] < 3.5:
            insights["suggestions"].append("该研究员的平均评分较低，建议优化生成策略")

        if "qed" in profile["property_preferences"]:
            avg_qed = profile["property_preferences"]["qed"]["avg"]
            if avg_qed < 0.6:
                insights["suggestions"].append("偏好QED较低的分子，可能关注结构多样性")
            elif avg_qed > 0.8:
                insights["suggestions"].append("偏好高药物相似性分子")

        return insights

    def get_target_insights(self, target: str) -> Dict[str, Any]:
        """获取靶点洞察"""
        if target not in self.target_weights:
            return {"status": "no_data", "message": "暂无该靶点的数据"}

        tw = self.target_weights[target]

        insights = {
            "status": "success",
            "target": target,
            "feedback_count": tw["feedback_count"],
            "avg_rating": round(tw["avg_rating"], 2),
            "optimal_ranges": {},
            "scoring_adjustments": tw.get("scoring_adjustments", {}),
        }

        for prop, values in tw.get("optimal_ranges", {}).items():
            if len(values) >= 3:
                avg = sum(values) / len(values)
                insights["optimal_ranges"][prop] = {
                    "min": round(min(values), 2),
                    "max": round(max(values), 2),
                    "avg": round(avg, 2),
                    "recommended": round(avg, 2),
                }

        return insights


# 单例实例
cognitive_engine = CognitiveEngine()
