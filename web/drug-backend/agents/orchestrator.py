"""
调度中枢 v3 (Orchestrator)
功能：协调5个Agent的工作流程，集成知识中心和认知增强
"""
from typing import Dict, List, Any
import time

from agents.analyzer import analyzer_agent
from agents.planner import planner_agent
from agents.generator import generator_agent
from agents.reviewer import reviewer_agent
from agents.learner import learner_agent
from agents.knowledge_base import knowledge_base
from agents.cognitive_engine import cognitive_engine
from agents.fpga_client import fpga_client

class Orchestrator:
    """调度中枢 - 5-Agent协同调度 + 知识增强"""

    def __init__(self):
        self.name = "调度中枢"
        self.agents = {
            "analyzer": analyzer_agent,
            "planner": planner_agent,
            "generator": generator_agent,
            "reviewer": reviewer_agent,
            "learner": learner_agent,
        }

    def run_pipeline(self, researcher_profile: Dict[str, Any]) -> Dict[str, Any]:
        """
        执行完整的5-Agent pipeline
        增强版：集成知识中心和认知增强
        """
        raw_target = researcher_profile.get("target_protein") or researcher_profile.get("target")
        target = raw_target.strip() if isinstance(raw_target, str) else ""
        if not target or target.lower() == "string":
            target = "EGFR"
        researcher_profile = {**researcher_profile, "target_protein": target}

        start_time = time.time()
        pipeline_result = {
            "pipeline_status": "running",
            "start_time": time.strftime("%Y-%m-%d %H:%M:%S"),
            "steps": {},
            "errors": [],
            "knowledge_enhanced": True,
        }

        # 预加载知识
        target_info = knowledge_base.get_target_info(target) if target else None

        # Step 1: 需求分析 (Analyzer)
        try:
            print("[Orchestrator] Step 1/5: 需求分析Agent执行中...")
            analysis = analyzer_agent.analyze(researcher_profile)

            # 知识增强
            if target_info:
                analysis["knowledge_enhancement"] = {
                    "target_full_name": target_info.full_name,
                    "target_family": target_info.family,
                    "known_drugs": target_info.known_drugs[:5],
                    "difficulty": target_info.difficulty,
                    "related_targets": knowledge_base.get_related_targets(target),
                }

            pipeline_result["steps"]["analyzer"] = {
                "status": "success",
                "result": analysis,
            }
        except Exception as e:
            pipeline_result["steps"]["analyzer"] = {"status": "error", "error": str(e)}
            pipeline_result["errors"].append(f"Analyzer错误: {str(e)}")

        # Step 2: 策略规划 (Planner)
        try:
            print("[Orchestrator] Step 2/5: 策略规划Agent执行中...")
            if pipeline_result["steps"]["analyzer"]["status"] == "success":
                planning = planner_agent.plan(pipeline_result["steps"]["analyzer"]["result"])

                # 知识增强：添加药物分类建议
                if target_info:
                    drug_class = knowledge_base.get_drug_class_for_target(target)
                    if drug_class:
                        planning["knowledge_enhancement"] = {
                            "drug_class": drug_class.name,
                            "typical_scaffolds": drug_class.typical_scaffolds,
                            "admet_profile": drug_class.admet_profile,
                        }

                pipeline_result["steps"]["planner"] = {
                    "status": "success",
                    "result": planning,
                }
            else:
                pipeline_result["steps"]["planner"] = {
                    "status": "skipped",
                    "reason": "Analyzer步骤失败",
                }
        except Exception as e:
            pipeline_result["steps"]["planner"] = {"status": "error", "error": str(e)}
            pipeline_result["errors"].append(f"Planner错误: {str(e)}")

        # Step 3: 分子生成 (Generator)
        try:
            print("[Orchestrator] Step 3/5: 分子生成Agent执行中...")

            # 认知增强：获取优化约束
            researcher_id = researcher_profile.get("name", "anonymous")
            enhanced_constraints = cognitive_engine.get_enhanced_constraints(researcher_id, target)

            gen_request = {
                "target_protein": target,
                "count": 5,
                "constraints": {
                    "min_molwt": 200,
                    "max_molwt": 600,
                    "min_qed": 0.3,
                },
                "cognitive_enhancement": enhanced_constraints,
            }

            generation = generator_agent.generate(gen_request)
            generation["fpga_batch"] = fpga_client.evaluate_molecules(
                generation["generated_molecules"], target=target
            )
            pipeline_result["steps"]["generator"] = {
                "status": "success",
                "result": generation,
            }
        except Exception as e:
            pipeline_result["steps"]["generator"] = {"status": "error", "error": str(e)}
            pipeline_result["errors"].append(f"Generator错误: {str(e)}")

        # Step 4: 审核裁判 (Reviewer)
        try:
            print("[Orchestrator] Step 4/5: 审核裁判Agent执行中...")
            if pipeline_result["steps"]["generator"]["status"] == "success":
                review = reviewer_agent.review(pipeline_result["steps"]["generator"]["result"])

                # 知识增强：ADMET评估
                if review.get("filtered_molecules"):
                    for mol in review["filtered_molecules"]:
                        props = mol.get("properties", {})
                        if props:
                            mol["admet_evaluation"] = knowledge_base.evaluate_admet(props)

                pipeline_result["steps"]["reviewer"] = {
                    "status": "success",
                    "result": review,
                }
            else:
                pipeline_result["steps"]["reviewer"] = {
                    "status": "skipped",
                    "reason": "Generator步骤失败",
                }
        except Exception as e:
            pipeline_result["steps"]["reviewer"] = {"status": "error", "error": str(e)}
            pipeline_result["errors"].append(f"Reviewer错误: {str(e)}")

        # Step 5: 反馈学习 (Learner)
        try:
            print("[Orchestrator] Step 5/5: 反馈学习Agent执行中...")
            top_candidates = []
            if pipeline_result["steps"]["reviewer"]["status"] == "success":
                top_candidates = pipeline_result["steps"]["reviewer"]["result"].get("top_candidates", [])

            pipeline_result["steps"]["learner"] = {
                "status": "success",
                "result": {
                    "message": "Pipeline执行完成，结果已记录",
                    "top_candidates_count": len(top_candidates),
                    "candidates": [
                        {
                            "id": c["id"],
                            "smiles": c["smiles"],
                            "score": c.get("total_score", 0),
                        }
                        for c in top_candidates[:3]
                    ],
                },
            }
        except Exception as e:
            pipeline_result["steps"]["learner"] = {"status": "error", "error": str(e)}
            pipeline_result["errors"].append(f"Learner错误: {str(e)}")

        # 完成
        elapsed = time.time() - start_time
        pipeline_result["pipeline_status"] = "completed" if not pipeline_result["errors"] else "completed_with_errors"
        pipeline_result["elapsed_time"] = round(elapsed, 2)
        pipeline_result["total_steps"] = 5
        pipeline_result["successful_steps"] = sum(1 for s in pipeline_result["steps"].values() if s["status"] == "success")

        # 汇总
        pipeline_result["summary"] = self._generate_summary(pipeline_result)

        # 知识增强摘要
        if target_info:
            pipeline_result["summary"]["target_info"] = {
                "full_name": target_info.full_name,
                "difficulty": target_info.difficulty,
                "known_drugs_count": len(target_info.known_drugs),
            }

        print(f"[Orchestrator] Pipeline完成! 耗时: {elapsed:.2f}s, 成功步骤: {pipeline_result['successful_steps']}/5")

        return pipeline_result

    def _generate_summary(self, pipeline_result: Dict) -> Dict[str, Any]:
        """生成pipeline摘要"""
        summary = {
            "researcher": "",
            "target": "",
            "strategy": "",
            "total_molecules": 0,
            "passed_molecules": 0,
            "top_candidate": None,
        }

        if pipeline_result["steps"]["analyzer"]["status"] == "success":
            profile = pipeline_result["steps"]["analyzer"]["result"].get("profile_summary", {})
            summary["researcher"] = profile.get("researcher", "")
            summary["target"] = profile.get("target", "")

        if pipeline_result["steps"]["planner"]["status"] == "success":
            strategy = pipeline_result["steps"]["planner"]["result"].get("strategy_overview", {})
            summary["strategy"] = strategy.get("approach", "")

        if pipeline_result["steps"]["generator"]["status"] == "success":
            summary["total_molecules"] = pipeline_result["steps"]["generator"]["result"].get("total_generated", 0)

        if pipeline_result["steps"]["reviewer"]["status"] == "success":
            review = pipeline_result["steps"]["reviewer"]["result"]
            summary["passed_molecules"] = len(review.get("filtered_molecules", []))
            top = review.get("top_candidates", [])
            if top:
                summary["top_candidate"] = {
                    "id": top[0]["id"],
                    "smiles": top[0]["smiles"],
                    "score": top[0].get("total_score", 0),
                }

        return summary


# 单例实例
orchestrator = Orchestrator()
