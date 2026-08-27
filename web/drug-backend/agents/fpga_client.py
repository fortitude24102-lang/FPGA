"""Z15 FPGA status client and real-molecule TCP inference adapter."""

import json
import math
import os
import socket
import struct
import time
from pathlib import Path
from typing import Any, Dict, List
from urllib.parse import urlparse
from urllib.request import urlopen

from config import FPGA_CONFIG
from agents.fpga_model import (
    encode_descriptors,
    encode_graph,
    load_profile,
    profile_is_rank_eligible,
    validate_weight_image,
)


class FPGAProtocolError(RuntimeError):
    """The board returned a malformed or failed TCP response."""


class FPGAClient:
    MAGIC = 0x5A
    VERSION = 1
    HEADER = struct.Struct("<BBBBIII")
    FLAG_RESPONSE = 0x01
    FLAG_ERROR = 0x04

    TASK_TANIMOTO = 0
    TASK_GNN = 1
    TASK_ADMET = 2
    TASK_RELOAD = 0xFE

    MAX_NODES = 50
    FEATURE_DIM = 64
    FINGERPRINT_BITS = 1024

    def __init__(self, host: str = None, port: int = None, service_url: str = None,
                 enabled: bool = None, timeout: float = 5.0):
        configured_host = FPGA_CONFIG.get("host", "localhost")
        configured_port = FPGA_CONFIG.get("port", 5001)
        self.service_url = (
            service_url
            or os.getenv("FPGA_SERVICE_URL")
            or f"http://{configured_host}"
        ).rstrip("/")
        board_host = urlparse(self.service_url).hostname
        self.host = host or os.getenv("FPGA_TCP_HOST") or board_host or configured_host
        self.port = int(port or os.getenv("FPGA_TCP_PORT") or
                        (configured_port if configured_port != 8888 else 5001))
        env_enabled = os.getenv("ENABLE_FPGA", "").lower() in ("1", "true", "yes")
        self.enabled = enabled if enabled is not None else (
            env_enabled or FPGA_CONFIG.get("enabled", False)
        )
        self.timeout = timeout
        self.connected = False
        self.socket = None
        self._trace_id = int(time.time() * 1000) & 0xFFFFFFFF
        self.stats = {
            "total_requests": 0,
            "total_errors": 0,
            "avg_compute_time": 0,
            "fpga_vs_cpu_speedup": 0,
        }
        self.profile = None
        self.model_profile = None
        self.model_epoch = None
        self.ranking_eligible = False
        self.profile_error = None
        configured_model_dir = os.getenv("FPGA_MODEL_DIR")
        self.model_dir = Path(configured_model_dir) if configured_model_dir else (
            Path(__file__).resolve().parents[1] / "models" / "fpga" / "egfr_admet_v1"
        )
        self._load_model_profile()
        if self.enabled and os.getenv("FPGA_AUTOLOAD_MODEL", "false").lower() in (
                "1", "true", "yes"):
            self.reload_model()

    def _load_model_profile(self) -> None:
        try:
            profile = load_profile(self.model_dir)
            image = (self.model_dir / profile["weights"]["file"]).read_bytes()
            validate_weight_image(profile, image)
        except Exception as exc:
            self.profile_error = str(exc)
            return
        self.profile = profile
        self.model_profile = profile["profile"]

    @staticmethod
    def _fingerprint_words(smiles: str) -> List[int]:
        from rdkit import Chem
        from rdkit.Chem import AllChem

        molecule = Chem.MolFromSmiles(smiles)
        if molecule is None:
            raise ValueError(f"invalid SMILES: {smiles}")
        try:
            fingerprint = AllChem.GetMorganGenerator(radius=2, fpSize=1024).GetFingerprint(molecule)
        except AttributeError:
            fingerprint = AllChem.GetMorganFingerprintAsBitVect(molecule, 2, nBits=1024)
        words = [0] * 32
        for bit in fingerprint.GetOnBits():
            words[bit // 32] |= 1 << (bit % 32)
        return words

    def _is_rank_eligible(self, target: str) -> bool:
        return bool(
            self.model_epoch is not None and self.profile is not None
            and profile_is_rank_eligible(self.profile, target) and self.ranking_eligible
        )

    def connect(self) -> bool:
        if not self.enabled:
            print("[FPGA] FPGA加速未启用，使用CPU计算")
            return False
        self.get_health()
        print(f"[FPGA] {'连接成功' if self.connected else '连接失败'}: {self.service_url}")
        return self.connected

    def disconnect(self):
        if self.socket:
            try:
                self.socket.close()
            except OSError:
                pass
        self.socket = None
        self.connected = False

    def _fetch_json(self, path: str) -> Dict[str, Any]:
        with urlopen(f"{self.service_url}{path}", timeout=self.timeout) as response:
            payload = json.loads(response.read().decode("utf-8"))
        if not isinstance(payload, dict):
            raise ValueError("FPGA service returned a non-object JSON response")
        return payload

    def get_health(self) -> Dict[str, Any]:
        if not self.enabled:
            self.connected = False
            return {"status": "DISABLED", "online": False, "fault": False}
        try:
            health = self._fetch_json("/api/fpga/health")
            self.connected = bool(health.get("online")) and not bool(health.get("fault"))
            return health
        except Exception as exc:
            self.connected = False
            return {"status": "OFFLINE", "online": False, "fault": True, "error": str(exc)}

    def get_benchmark(self) -> Dict[str, Any]:
        if not self.enabled:
            return {"lanes": []}
        try:
            benchmark = self._fetch_json("/api/fpga/benchmark")
            self.connected = True
            return benchmark
        except Exception as exc:
            self.connected = False
            return {"lanes": [], "error": str(exc)}

    @staticmethod
    def _q8(value: float) -> int:
        scaled = int(round(value * 256.0))
        return min(32767, max(-32768, scaled))

    @staticmethod
    def _u16(value: int) -> int:
        return value & 0xFFFF

    @staticmethod
    def _signed_q8(word: int, high: bool = False) -> float:
        raw = (word >> 16) & 0xFFFF if high else word & 0xFFFF
        if raw & 0x8000:
            raw -= 0x10000
        return round(raw / 256.0, 6)

    @staticmethod
    def _pack_words(words) -> bytes:
        words = tuple(int(word) & 0xFFFFFFFF for word in words)
        return struct.pack(f"<{len(words)}I", *words)

    def encode_molecule(self, smiles: str) -> Dict[str, Any]:
        """Encode one SMILES exactly as the current RTL payload memories expect."""
        from rdkit import Chem
        from rdkit.Chem import AllChem, Descriptors

        molecule = Chem.MolFromSmiles(smiles)
        if molecule is None:
            raise ValueError(f"invalid SMILES: {smiles}")
        if molecule.GetNumAtoms() > self.MAX_NODES:
            raise ValueError(
                f"molecule has {molecule.GetNumAtoms()} atoms; FPGA maximum is 50"
            )

        try:
            generator = AllChem.GetMorganGenerator(radius=2, fpSize=self.FINGERPRINT_BITS)
            fingerprint = generator.GetFingerprint(molecule)
        except AttributeError:
            fingerprint = AllChem.GetMorganFingerprintAsBitVect(
                molecule, 2, nBits=self.FINGERPRINT_BITS
            )
        fingerprint_words = [0] * 32
        for bit in fingerprint.GetOnBits():
            fingerprint_words[bit // 32] |= 1 << (bit % 32)

        adjacency_words = [0] * 79
        for atom_index in range(molecule.GetNumAtoms()):
            bit = atom_index * self.MAX_NODES + atom_index
            adjacency_words[bit // 32] |= 1 << (bit % 32)
        for bond in molecule.GetBonds():
            begin, end = bond.GetBeginAtomIdx(), bond.GetEndAtomIdx()
            for row, column in ((begin, end), (end, begin)):
                bit = row * self.MAX_NODES + column
                adjacency_words[bit // 32] |= 1 << (bit % 32)

        features = [0] * (self.MAX_NODES * self.FEATURE_DIM)
        for atom in molecule.GetAtoms():
            base = atom.GetIdx() * self.FEATURE_DIM
            features[base + min(31, max(0, atom.GetAtomicNum() - 1))] = 256
            features[base + 32 + min(5, atom.GetDegree())] = 256
            features[base + 38 + min(4, max(0, atom.GetFormalCharge() + 2))] = 256
            features[base + 43] = 256 if atom.GetIsAromatic() else 0
        feature_words = [
            self._u16(features[index]) | (self._u16(features[index + 1]) << 16)
            for index in range(0, len(features), 2)
        ]

        descriptor_specs = (
            (Descriptors.MolWt, 300.0, 100.0),
            (Descriptors.MolLogP, 0.0, 5.0),
            (Descriptors.NumHDonors, 0.0, 5.0),
            (Descriptors.NumHAcceptors, 0.0, 10.0),
            (Descriptors.TPSA, 0.0, 100.0),
            (Descriptors.NumRotatableBonds, 0.0, 10.0),
            (Descriptors.RingCount, 0.0, 8.0),
            (Descriptors.FractionCSP3, 0.0, 1.0),
            (Descriptors.HeavyAtomCount, 0.0, 50.0),
            (Descriptors.NHOHCount, 0.0, 10.0),
            (Descriptors.NOCount, 0.0, 20.0),
            (Descriptors.NumAromaticRings, 0.0, 8.0),
            (Descriptors.NumAliphaticRings, 0.0, 8.0),
            (Descriptors.NumSaturatedRings, 0.0, 8.0),
            (Descriptors.NumHeteroatoms, 0.0, 20.0),
            (Descriptors.MaxPartialCharge, 0.0, 1.0),
            (Descriptors.MinPartialCharge, 0.0, 1.0),
            (Descriptors.BalabanJ, 0.0, 5.0),
            (Descriptors.BertzCT, 0.0, 500.0),
            (Descriptors.MolMR, 0.0, 100.0),
        )
        descriptor_words = []
        for function, center, scale in descriptor_specs:
            value = float(function(molecule))
            if not math.isfinite(value):
                value = 0.0
            descriptor_words.append(self._u16(self._q8((value - center) / scale)))

        return {
            "canonical_smiles": Chem.MolToSmiles(molecule),
            "node_count": molecule.GetNumAtoms(),
            "fingerprint_words": fingerprint_words,
            "adjacency_words": adjacency_words,
            "feature_words": feature_words,
            "descriptor_words": descriptor_words,
        }

    @staticmethod
    def _recv_exact(connection, size: int) -> bytes:
        data = bytearray()
        while len(data) < size:
            chunk = connection.recv(size - len(data))
            if not chunk:
                raise FPGAProtocolError("connection closed during FPGA response")
            data.extend(chunk)
        return bytes(data)

    def _request_words(self, task_id: int, payload: bytes, batch_size: int):
        self._trace_id = (self._trace_id + 1) & 0xFFFFFFFF
        trace_id = self._trace_id
        frame = self.HEADER.pack(
            self.MAGIC, self.VERSION, task_id, 0, len(payload), trace_id, batch_size
        ) + payload
        started = time.perf_counter()
        with socket.create_connection((self.host, self.port), self.timeout) as connection:
            connection.settimeout(self.timeout)
            connection.sendall(frame)
            header = self._recv_exact(connection, self.HEADER.size)
            magic, version, response_task, flags, length, response_trace, response_batch = \
                self.HEADER.unpack(header)
            if magic != self.MAGIC or version != self.VERSION or not flags & self.FLAG_RESPONSE:
                raise FPGAProtocolError("invalid FPGA response header")
            if (response_task, response_trace, response_batch) != (task_id, trace_id, batch_size):
                raise FPGAProtocolError("FPGA response does not match request")
            if length % 4:
                raise FPGAProtocolError("FPGA response length is not word aligned")
            response = self._recv_exact(connection, length)
        if flags & self.FLAG_ERROR:
            if len(response) != 8:
                raise FPGAProtocolError("invalid FPGA error response")
            code, detail = struct.unpack("<II", response)
            raise FPGAProtocolError(f"FPGA error code={code} detail={detail}")
        expected = 1 if task_id == self.TASK_RELOAD else (
            batch_size if task_id in (self.TASK_TANIMOTO, self.TASK_GNN) else batch_size * 4
        )
        if length != expected * 4:
            raise FPGAProtocolError(
                f"FPGA returned {length // 4} words; expected {expected}"
            )
        words = struct.unpack(f"<{expected}I", response)
        self.connected = True
        elapsed = time.perf_counter() - started
        self.stats["total_requests"] += 1
        self._update_avg_time(elapsed)
        return words, trace_id, elapsed

    def reload_model(self) -> Dict[str, Any]:
        """Validate and upload the configured model image, returning its board epoch."""
        if self.profile is None:
            self.ranking_eligible = False
            return {
                "status": "profile_unavailable", "model_profile": None,
                "ranking_eligible": False, "error": self.profile_error,
            }
        try:
            image = (self.model_dir / self.profile["weights"]["file"]).read_bytes()
            validate_weight_image(self.profile, image)
            words, _, _ = self._request_words(self.TASK_RELOAD, image, 1)
        except Exception as exc:
            self.ranking_eligible = False
            self.connected = False
            self.stats["total_errors"] += 1
            return {
                "status": "reload_failed", "model_profile": self.model_profile,
                "ranking_eligible": False, "error": str(exc),
            }
        self.model_epoch = int(words[0])
        self.ranking_eligible = profile_is_rank_eligible(self.profile, "EGFR")
        return {
            "status": "reloaded", "model_profile": self.model_profile,
            "epoch": self.model_epoch, "ranking_eligible": self.ranking_eligible,
        }

    def evaluate_molecules(self, molecules: List[Dict[str, Any]], target: str = "EGFR") -> Dict[str, Any]:
        """Run real candidate data through all three accelerator tasks."""
        if not self.enabled:
            for molecule in molecules:
                molecule["fpga_evaluation"] = {
                    "status": "disabled", "accelerated": False
                }
            return {"status": "disabled", "accelerated_count": 0,
                    "model_profile": self.model_profile, "ranking_eligible": False}

        if self.profile is None:
            for molecule in molecules:
                molecule["fpga_evaluation"] = {
                    "status": "profile_unavailable", "accelerated": False,
                    "model_profile": None, "ranking_eligible": False,
                    "ranking_effect": "ineligible", "error": self.profile_error,
                }
            return {"status": "profile_unavailable", "accelerated_count": 0,
                    "model_profile": None, "ranking_eligible": False}

        if str(target).upper() != self.profile["target"]["name"].upper():
            for molecule in molecules:
                molecule["fpga_evaluation"] = {
                    "status": "target_mismatch", "accelerated": False,
                    "model_profile": self.model_profile, "ranking_eligible": False,
                    "ranking_effect": "ineligible",
                }
            return {"status": "target_mismatch", "accelerated_count": 0,
                    "model_profile": self.model_profile, "ranking_eligible": False}

        valid = []
        for molecule in molecules:
            try:
                smiles = molecule.get("smiles", "")
                valid.append((molecule, {
                    "fingerprint_words": self._fingerprint_words(smiles),
                    "graph": encode_graph(smiles, self.profile),
                    "descriptor_words": encode_descriptors(smiles, self.profile),
                }))
            except Exception as exc:
                molecule["fpga_evaluation"] = {
                    "status": "not_encodable",
                    "accelerated": False,
                    "error": str(exc),
                    "model_profile": self.model_profile,
                    "ranking_eligible": False,
                    "ranking_effect": "ineligible",
                }
        if not valid:
            return {"status": "no_encodable_molecules", "accelerated_count": 0}

        batch_size = min(len(valid), 16)
        valid = valid[:batch_size]
        reference_smiles = self.profile["target"]["reference_smiles"]
        reference_words = self._fingerprint_words(reference_smiles)
        gnn_words = [
            word for _, encoded in valid
            for word in encoded["graph"]["adjacency_words"] + encoded["graph"]["feature_words"]
        ]
        admet_words = [
            word for _, encoded in valid for word in encoded["descriptor_words"]
        ]

        try:
            tani = []
            tani_trace = []
            tani_seconds = 0.0
            for _, encoded in valid:
                words, trace_id, seconds = self._request_words(
                    self.TASK_TANIMOTO,
                    self._pack_words(
                        reference_words + encoded["fingerprint_words"]
                    ),
                    1,
                )
                tani.append(words[0])
                tani_trace.append(trace_id)
                tani_seconds += seconds
            gnn, gnn_trace, gnn_seconds = self._request_words(
                self.TASK_GNN, self._pack_words(gnn_words), batch_size
            )
            admet, admet_trace, admet_seconds = self._request_words(
                self.TASK_ADMET, self._pack_words(admet_words), batch_size
            )
        except Exception as exc:
            self.connected = False
            self.ranking_eligible = False
            self.stats["total_errors"] += 1
            for molecule, _ in valid:
                molecule["fpga_evaluation"] = {
                    "status": "fallback", "accelerated": False, "error": str(exc),
                    "model_profile": self.model_profile,
                    "ranking_eligible": False,
                    "ranking_effect": "ineligible",
                }
            return {
                "status": "fallback", "accelerated_count": 0, "error": str(exc),
                "model_profile": self.model_profile, "ranking_eligible": False,
                "ranking_effect": "ineligible",
            }

        traces = {"tanimoto": tani_trace, "gnn": gnn_trace, "admet": admet_trace}
        latency_ms = {
            "tanimoto": round(tani_seconds * 1000, 3),
            "gnn": round(gnn_seconds * 1000, 3),
            "admet": round(admet_seconds * 1000, 3),
        }
        for index, (molecule, encoded) in enumerate(valid):
            raw_admet = list(admet[index * 4:index * 4 + 4])
            predictions = [self._signed_q8(word) for word in raw_admet]
            named_admet = {
                name: min(1.0, max(0.0, value))
                for name, value in zip(self.profile["outputs"]["admet"], predictions)
            }
            named_admet["lipophilicity"] = named_admet["lipophilicity_desirability"]
            eligible = self._is_rank_eligible(target)
            molecule["fpga_evaluation"] = {
                "status": "hardware_complete",
                "accelerated": True,
                "reference_smiles": reference_smiles,
                "node_count": encoded["graph"]["node_count"],
                "tanimoto": {
                    "raw_q16_16": tani[index],
                    "similarity": round(tani[index] / 65536.0, 6),
                },
                "gnn": {
                    "raw_output_word": gnn[index],
                    "node0_hidden0": self._signed_q8(gnn[index]),
                    "node0_hidden1": self._signed_q8(gnn[index], high=True),
                    "egfr_activity_score": min(1.0, max(0.0, self._signed_q8(gnn[index]))),
                    "egfr_activity_trace": self._signed_q8(gnn[index], high=True),
                },
                "admet": {
                    "raw_q8_8": raw_admet,
                    "predictions": predictions,
                    **named_admet,
                },
                "trace_ids": traces,
                "latency_ms": latency_ms,
                "model_profile": self.model_profile,
                "ranking_eligible": eligible,
                "ranking_effect": "eligible" if eligible else "ineligible",
            }
        return {
            "status": "hardware_complete",
            "accelerated_count": batch_size,
            "reference_smiles": reference_smiles,
            "trace_ids": traces,
            "latency_ms": latency_ms,
            "model_profile": self.model_profile,
            "epoch": self.model_epoch,
            "ranking_eligible": self._is_rank_eligible(target),
        }

    def compute_tanimoto_smiles(self, smiles1: str, smiles2: str) -> Dict[str, Any]:
        """Compute one real-SMILES pair with the board's Tanimoto task."""
        if not self.enabled:
            raise ConnectionError("FPGA acceleration is disabled")
        left = self._fingerprint_words(smiles1)
        right = self._fingerprint_words(smiles2)
        words, trace_id, elapsed = self._request_words(
            self.TASK_TANIMOTO, self._pack_words(left + right), 1
        )
        similarity = words[0] / 65536.0
        return {
            "similarity": round(similarity, 6),
            "raw_q16_16": int(words[0]),
            "method": "Tanimoto (Morgan 1024-bit, FPGA)",
            "interpretation": (
                "高度相似" if similarity > 0.7 else
                "中等相似" if similarity > 0.4 else "低相似度"
            ),
            "accelerated": True,
            "trace_id": str(trace_id),
            "compute_time_ms": round(elapsed * 1000, 3),
        }

    def compute_fingerprint(self, smiles: str, fp_size: int = 2048) -> Dict[str, Any]:
        started = time.time()
        self.stats["total_requests"] += 1
        try:
            from rdkit import Chem
            from rdkit.Chem import AllChem
            molecule = Chem.MolFromSmiles(smiles)
            if molecule is None:
                return {"error": "无效的SMILES", "smiles": smiles}
            fingerprint = AllChem.GetMorganFingerprintAsBitVect(
                molecule, 2, nBits=fp_size
            ).ToBitString()
            elapsed = time.time() - started
            self._update_avg_time(elapsed)
            return {
                "smiles": smiles,
                "fingerprint": fingerprint,
                "fp_size": fp_size,
                "method": "Morgan RDKit输入编码",
                "compute_time_ms": round(elapsed * 1000, 3),
                "accelerated": False,
            }
        except ImportError:
            return {"error": "RDKit未安装", "smiles": smiles}

    def compute_similarity(self, fp1: str, fp2: str, method: str = "tanimoto") -> Dict[str, Any]:
        started = time.time()
        common = sum(a == b == "1" for a, b in zip(fp1, fp2))
        union = sum(a == "1" or b == "1" for a, b in zip(fp1, fp2))
        similarity = common / union if union else 0.0
        return {
            "similarity": round(similarity, 4),
            "method": f"{method} CPU计算",
            "compute_time_ms": round((time.time() - started) * 1000, 3),
            "accelerated": False,
        }

    def batch_compute_fingerprints(self, smiles_list: List[str], fp_size: int = 2048):
        return [self.compute_fingerprint(smiles, fp_size) for smiles in smiles_list]

    def batch_compute_similarity_matrix(self, fingerprints: List[str]):
        size = len(fingerprints)
        matrix = [[0.0] * size for _ in range(size)]
        for left in range(size):
            matrix[left][left] = 1.0
            for right in range(left + 1, size):
                value = self.compute_similarity(
                    fingerprints[left], fingerprints[right]
                )["similarity"]
                matrix[left][right] = matrix[right][left] = value
        return matrix

    def _update_avg_time(self, compute_time: float):
        count = self.stats["total_requests"]
        if count:
            self.stats["avg_compute_time"] = (
                self.stats["avg_compute_time"] * (count - 1) + compute_time
            ) / count

    def get_status(self) -> Dict[str, Any]:
        health = self.get_health()
        self.stats["total_requests"] = int(health.get("completed_tasks", 0))
        self.stats["total_errors"] = int(health.get("failed_tasks", 0))
        self.stats["avg_compute_time"] = float(health.get("avg_latency_us", 0)) / 1_000_000.0
        return {
            **health,
            "connected": self.connected,
            "enabled": self.enabled,
            "service_url": self.service_url,
            "host": self.host,
            "port": self.port,
            "stats": self.stats,
        }

    def get_performance_report(self) -> Dict[str, Any]:
        health = self.get_health()
        benchmark = self.get_benchmark() if self.connected else {"lanes": []}
        total_requests = int(health.get("completed_tasks", 0))
        total_errors = int(health.get("failed_tasks", 0))
        return {
            "fpga_enabled": self.enabled,
            "fpga_connected": self.connected,
            "total_requests": total_requests,
            "total_errors": total_errors,
            "error_rate": round(total_errors / total_requests, 4) if total_requests else 0,
            "avg_compute_time_ms": round(float(health.get("avg_latency_us", 0)) / 1000.0, 3),
            "lanes": benchmark.get("lanes", []),
            "health": health,
        }


fpga_client = FPGAClient()
