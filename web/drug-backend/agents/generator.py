"""
分子生成Agent (Generator)
功能：基于RDKit生成候选药物分子，计算分子性质
"""
from typing import Dict, List, Any, Optional
import random

try:
    from rdkit import Chem
    from rdkit.Chem import Descriptors, AllChem, QED, rdMolDescriptors
    from rdkit.Chem import Draw
    from rdkit import DataStructs
    RDKIT_AVAILABLE = True
except ImportError:
    RDKIT_AVAILABLE = False
    print("警告: RDKit未安装，将使用模拟数据")


class GeneratorAgent:
    """分子生成Agent - 生成候选药物分子"""

    def __init__(self):
        self.name = "分子生成Agent"
        # 预定义的分子片段库（用于生成新分子）
        self.fragments = {
            "aromatic": ["c1ccccc1", "c1cccnc1", "c1ncccn1", "c1ccc(O)cc1", "c1ccc(N)cc1"],
            "heterocycle": ["C1CCNC1", "C1CCOC1", "c1n[nH]c2ccccc12", "c1cncnc1"],
            "linker": ["CC", "CCO", "CCN", "CC(=O)", "CCS", "C=CC"],
            "functional": ["C(=O)O", "C(=O)N", "S(=O)(=O)N", "CN", "CF", "CCl"],
        }
        # 已知药物分子SMILES（用于参考和变异）
        self.known_drugs = {
            "阿司匹林": "CC(=O)Oc1ccccc1C(=O)O",
            "布洛芬": "CC(C)Cc1ccc(C(C)C(=O)O)cc1",
            "对乙酰氨基酚": "CC(=O)Nc1ccc(O)cc1",
            "二甲双胍": "CN(C)C(=N)N",
            "西地那非": "CCCC1=NN(C)C2=C1NC(=NC2=O)C1CCC(O)CC1",
            "华法林": "CC(=O)CC(c1ccccc1)c1c(O)oc2ccccc12",
            "塞来昔布": "Cc1ccc(cc1)c1cc(nn1c1ccc(cc1)S(N)(=O)=O)C(F)(F)F",
            "吉非替尼": "COc1cc2ncnc(Nc3ccc(F)c(Cl)c3)c2cc1OCCCN1CCOCC1",
            "厄洛替尼": "C#Cc1cccc(Nc2ncnc3cc(OCCOC)c(OCCOC)cc23)c1",
        }

    def generate(self, request: Dict[str, Any]) -> Dict[str, Any]:
        """
        生成候选药物分子

        Args:
            request: 包含 target_protein, count, constraints 等

        Returns:
            生成的分子列表及性质
        """
        target = request.get("target_protein", "")
        count = request.get("count", 5)
        constraints = request.get("constraints", {})

        result = {
            "agent": self.name,
            "status": "success",
            "target": target,
            "generated_molecules": [],
            "generation_method": "RDKit-based generation",
            "total_generated": 0,
        }

        if RDKIT_AVAILABLE:
            molecules = self._generate_with_rdkit(target, count, constraints)
        else:
            molecules = self._generate_mock(target, count)

        result["generated_molecules"] = molecules
        result["total_generated"] = len(molecules)

        # 统计信息
        if molecules:
            result["statistics"] = {
                "avg_molwt": sum(m["properties"]["molwt"] for m in molecules) / len(molecules),
                "avg_logp": sum(m["properties"]["logp"] for m in molecules) / len(molecules),
                "avg_qed": sum(m["properties"]["qed"] for m in molecules) / len(molecules),
                "pass_lipinski": sum(1 for m in molecules if m["properties"]["lipinski_pass"]),
            }

        return result

    def _generate_with_rdkit(self, target: str, count: int, constraints: Dict) -> List[Dict]:
        """使用RDKit生成分子"""
        molecules = []

        # 策略1: 基于已知药物进行变异
        for drug_name, smiles in self.known_drugs.items():
            if len(molecules) >= count:
                break
            mol = Chem.MolFromSmiles(smiles)
            if mol:
                variant = self._mutate_molecule(mol)
                if variant:
                    mol_info = self._get_molecule_info(variant, f"variant_of_{drug_name}")
                    if self._check_constraints(mol_info["properties"], constraints):
                        molecules.append(mol_info)

        # 策略2: 从头生成分子（基于片段组合）
        attempts = 0
        max_attempts = count * 5
        while len(molecules) < count and attempts < max_attempts:
            attempts += 1
            new_mol = self._build_from_fragments()
            if new_mol:
                mol_info = self._get_molecule_info(new_mol, f"generated_{len(molecules)+1}")
                if self._check_constraints(mol_info["properties"], constraints):
                    # 检查是否重复
                    if not any(m["smiles"] == mol_info["smiles"] for m in molecules):
                        molecules.append(mol_info)

        return molecules[:count]

    def _mutate_molecule(self, mol) -> Optional[Any]:
        """对分子进行变异"""
        if not RDKIT_AVAILABLE:
            return None

        try:
            # 简单的变异策略：替换一个原子
            smiles = Chem.MolToSmiles(mol)
            # 随机替换一些常见基团
            replacements = [
                ("c1ccccc1", "c1cccnc1"),  # 苯环 -> 吡啶
                ("C(=O)O", "C(=O)N"),      # 羧酸 -> 酰胺
                ("O", "N"),                 # 氧 -> 氮
                ("N", "O"),                 # 氮 -> 氧
            ]

            if random.random() < 0.5 and replacements:
                old, new = random.choice(replacements)
                if old in smiles:
                    new_smiles = smiles.replace(old, new, 1)
                    new_mol = Chem.MolFromSmiles(new_smiles)
                    if new_mol:
                        return new_mol

            # 如果没有成功变异，返回原分子
            return mol
        except:
            return mol

    def _build_from_fragments(self) -> Optional[Any]:
        """从片段构建分子"""
        if not RDKIT_AVAILABLE:
            return None

        try:
            # 随机选择2-4个片段组合
            num_fragments = random.randint(2, 4)
            selected = []

            # 至少选一个芳香环
            selected.append(random.choice(self.fragments["aromatic"]))

            # 添加连接链
            if num_fragments > 2:
                selected.append(random.choice(self.fragments["linker"]))

            # 添加功能基团
            selected.append(random.choice(self.fragments["functional"]))

            # 尝试组合
            combined = "".join(selected)
            mol = Chem.MolFromSmiles(combined)

            # 如果无效，尝试简单组合
            if not mol:
                simple_smiles = random.choice(self.fragments["aromatic"]) + random.choice(self.fragments["functional"])
                mol = Chem.MolFromSmiles(simple_smiles)

            return mol
        except:
            return None

    def _get_molecule_info(self, mol, name: str) -> Dict[str, Any]:
        """获取分子详细信息"""
        if not RDKIT_AVAILABLE:
            return self._get_mock_molecule_info(name)

        smiles = Chem.MolToSmiles(mol)

        # 计算分子性质
        molwt = Descriptors.MolWt(mol)
        logp = Descriptors.MolLogP(mol)
        tpsa = Descriptors.TPSA(mol)
        hbd = Descriptors.NumHDonors(mol)
        hba = Descriptors.NumHAcceptors(mol)
        rotatable = Descriptors.NumRotatableBonds(mol)

        # QED (药物相似性)
        try:
            qed = QED.qed(mol)
        except:
            qed = 0.5

        # SAscore (合成可及性)
        try:
            sa = self._calculate_sa_score(mol)
        except:
            sa = 3.0

        # Lipinski规则
        lipinski_pass = (molwt <= 500 and logp <= 5 and hbd <= 5 and hba <= 10)
        lipinski_violations = sum([
            molwt > 500,
            logp > 5,
            hbd > 5,
            hba > 10
        ])

        # 分子指纹（用于相似性计算）
        try:
            fp = AllChem.GetMorganFingerprintAsBitVect(mol, 2, nBits=2048)
            fp_str = fp.ToBitString()
        except:
            fp_str = ""

        return {
            "id": name,
            "smiles": smiles,
            "properties": {
                "molwt": round(molwt, 2),
                "logp": round(logp, 2),
                "tpsa": round(tpsa, 2),
                "hbd": hbd,
                "hba": hba,
                "rotatable_bonds": rotatable,
                "qed": round(qed, 3),
                "sa_score": round(sa, 2),
                "lipinski_pass": lipinski_pass,
                "lipinski_violations": lipinski_violations,
            },
            "fingerprint": fp_str,
        }

    def _calculate_sa_score(self, mol) -> float:
        """计算合成可及性分数 (简化版)"""
        # 基于一些简单启发式规则
        sa = 1.0
        sa += mol.GetNumAtoms() * 0.05  # 原子数越多越难合成
        sa += Descriptors.NumRotatableBonds(mol) * 0.2  # 可旋转键
        sa += len(mol.GetRingInfo().AtomRings()) * 0.5  # 环数
        return min(sa, 10.0)

    def _check_constraints(self, props: Dict, constraints: Dict) -> bool:
        """检查是否满足约束条件"""
        if not constraints:
            return True

        if "min_molwt" in constraints and props["molwt"] < constraints["min_molwt"]:
            return False
        if "max_molwt" in constraints and props["molwt"] > constraints["max_molwt"]:
            return False
        if "min_logp" in constraints and props["logp"] < constraints["min_logp"]:
            return False
        if "max_logp" in constraints and props["logp"] > constraints["max_logp"]:
            return False
        if "min_qed" in constraints and props["qed"] < constraints["min_qed"]:
            return False

        return True

    def _generate_mock(self, target: str, count: int) -> List[Dict]:
        """生成模拟分子数据（RDKit不可用时）"""
        mock_smiles = [
            "CC(=O)Oc1ccccc1C(=O)O",
            "CC(C)Cc1ccc(C(C)C(=O)O)cc1",
            "CC(=O)Nc1ccc(O)cc1",
            "CN1C=NC2=C1C(=O)N(C(=O)N2C)C",
            "c1ccc(cc1)C(=O)O",
        ]

        molecules = []
        for i in range(min(count, len(mock_smiles))):
            molecules.append(self._get_mock_molecule_info(f"molecule_{i+1}", mock_smiles[i]))

        return molecules

    def _get_mock_molecule_info(self, name: str, smiles: str = "") -> Dict[str, Any]:
        """模拟分子信息"""
        import random as rd
        return {
            "id": name,
            "smiles": smiles or "CC(=O)Oc1ccccc1C(=O)O",
            "properties": {
                "molwt": round(rd.uniform(200, 500), 2),
                "logp": round(rd.uniform(-1, 5), 2),
                "tpsa": round(rd.uniform(20, 150), 2),
                "hbd": rd.randint(0, 5),
                "hba": rd.randint(1, 10),
                "rotatable_bonds": rd.randint(0, 10),
                "qed": round(rd.uniform(0.3, 0.9), 3),
                "sa_score": round(rd.uniform(1.5, 5.0), 2),
                "lipinski_pass": rd.random() > 0.3,
                "lipinski_violations": rd.randint(0, 2),
            },
            "fingerprint": "",
        }


# 单例实例
generator_agent = GeneratorAgent()
