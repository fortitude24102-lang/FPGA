# FPGA Real-Model Ranking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Train and package hardware-compatible EGFR/ADMET models, load them through the existing FPGA protocol, and use validated hardware results in backend candidate ranking without changing the frontend.

**Architecture:** A compact NumPy/RDKit training tool emits one validated Q8.8 model package matching the programmed GNN and four ADMET networks. The backend loads the package, encodes a virtual graph node and target reference ligand, names hardware predictions, and blends a gated hardware score into the existing reviewer score. Every failure path retains the previous ranking behavior.

**Tech Stack:** Python standard library, NumPy, pandas, RDKit, httpx, unittest, existing Z15 TCP/DMA protocol

**Spec:** `docs/superpowers/specs/2026-08-26-fpga-real-model-ranking-design.md`

## Global Constraints

- Do not modify anything under `../molrecommender-frontend/`.
- Do not change existing frontend request paths, HTTP methods, or required request fields.
- Existing response fields remain present with their current types; new model and score details are additive only.
- Do not modify the current FPGA RTL, register map, TCP framing, or DMA weight-reload protocol.
- Production runtime dependencies remain limited to the packages already listed in `requirements.txt`.
- FPGA failure, disabled mode, an unknown target, or an unvalidated model must preserve the current CPU-only ranking behavior.
- Version 1 supports a trained target-activity model only for EGFR.
- This source tree has no `.git` directory, so task checkpoints are verified by tests and file hashes rather than commits.

---

## File map

- Create `agents/fpga_model.py`: model-manifest validation, shared molecular features, Q8.8 helpers, weight-image validation, and hardware-score calculation.
- Create `tools/train_fpga_models.py`: public dataset acquisition, scaffold splitting, compact NumPy training, quantization, metrics, and package generation.
- Create `models/fpga/egfr_admet_v1/manifest.json`: generated, reproducible runtime model contract and evaluation report.
- Create `models/fpga/egfr_admet_v1/weights.bin`: generated 18,152-byte FPGA reload image.
- Modify `agents/fpga_client.py`: profile loading, target reference encoding, weight reload, named predictions, and rank-eligibility state.
- Modify `agents/orchestrator.py`: pass the normalized target to FPGA evaluation.
- Modify `agents/reviewer.py`: preserve baseline scoring and conditionally blend validated FPGA scoring.
- Modify `.env.example`: document model path and optional startup reload without changing defaults.
- Create `test_fpga_model_profile.py`: feature, manifest, packing, and fixed-point tests.
- Modify `test_fpga_molecule_inference.py`: reference-ligand, reload, named-output, and fallback tests.
- Create `test_fpga_ranking.py`: ordering and strict fallback tests.
- Create `docs/FPGA_REAL_MODEL.md`: training, deployment, board reload, metrics, and limitations.

### Task 1: Lock the model and feature contract

**Files:**
- Create: `agents/fpga_model.py`
- Create: `test_fpga_model_profile.py`

**Interfaces:**
- Produces: `load_profile(profile_dir: Path) -> dict`
- Produces: `validate_weight_image(profile: dict, image: bytes) -> None`
- Produces: `encode_graph(smiles: str, profile: dict) -> dict[str, object]`
- Produces: `encode_descriptors(smiles: str, profile: dict) -> list[int]`
- Produces: `hardware_score(evaluation: dict) -> float | None`

- [ ] **Step 1: Write failing tests for profile and image validation**

```python
def test_profile_rejects_wrong_weight_length(self):
    profile = {
        "profile": "egfr_admet_v1",
        "validated": True,
        "target": {"name": "EGFR"},
        "weights": {"bytes": 18152, "crc32": "00000000"},
    }
    with self.assertRaisesRegex(ValueError, "18152"):
        validate_weight_image(profile, b"\x00" * 32)

def test_only_validated_egfr_profile_is_rank_eligible(self):
    profile = {
        "profile": "egfr_admet_v1",
        "validated": True,
        "target": {"name": "EGFR"},
    }
    self.assertTrue(profile_is_rank_eligible(profile, "EGFR"))
    self.assertFalse(profile_is_rank_eligible(profile, "ALK"))
```

- [ ] **Step 2: Run the profile tests and confirm they fail because the module does not exist**

Run: `venv\\Scripts\\python.exe -m unittest test_fpga_model_profile.py -v`

Expected: import failure for `agents.fpga_model`.

- [ ] **Step 3: Implement the manifest validator and Q8.8/image helpers**

```python
Q8_SCALE = 256
GNN_WEIGHT_COUNT = 8192
ADMET_MODEL_COUNT = 4
ADMET_VALUES_PER_MODEL = 221
WEIGHT_HALFWORDS = GNN_WEIGHT_COUNT + ADMET_MODEL_COUNT * ADMET_VALUES_PER_MODEL
WEIGHT_BYTES = WEIGHT_HALFWORDS * 2

def q8(value: float) -> int:
    return min(32767, max(-32768, int(round(value * Q8_SCALE))))

def validate_weight_image(profile: dict, image: bytes) -> None:
    expected = int(profile["weights"]["bytes"])
    if expected != WEIGHT_BYTES or len(image) != WEIGHT_BYTES:
        raise ValueError(f"weight image must contain {WEIGHT_BYTES} bytes")
    observed = f"{zlib.crc32(image) & 0xffffffff:08x}"
    if observed != str(profile["weights"]["crc32"]).lower():
        raise ValueError("weight image CRC32 does not match manifest")
```

- [ ] **Step 4: Add virtual-node graph encoding and manifest-driven descriptors**

```python
def profile_is_rank_eligible(profile: dict, target: str) -> bool:
    return (
        profile.get("validated") is True
        and profile.get("profile") == "egfr_admet_v1"
        and str(target).upper() == "EGFR"
        and profile.get("target", {}).get("name") == "EGFR"
    )
```

`encode_graph` must reserve node 0, shift each atom index by one, connect node 0 bidirectionally to all real atoms, retain atom self/bond edges, place a constant in feature 63, and reject more than 49 real atoms. `encode_descriptors` must use the exact manifest descriptor order and training centers/scales.

- [ ] **Step 5: Add and pass exact-shape tests**

Assert 79 adjacency words, 1,600 feature words, 20 descriptor halfwords, node-0-to-every-atom edges, atom shift by one, signed Q8.8 saturation, CRC behavior, and a 50-carbon rejection mentioning the 49-atom profile limit.

Run: `venv\\Scripts\\python.exe -m unittest test_fpga_model_profile.py -v`

Expected: all Task 1 tests pass.

### Task 2: Build reproducible public-data acquisition and scaffold splits

**Files:**
- Create: `tools/train_fpga_models.py`
- Test: `test_fpga_model_profile.py`

**Interfaces:**
- Consumes: feature functions from `agents.fpga_model`
- Produces: `fetch_chembl_egfr(cache_dir: Path) -> pandas.DataFrame`
- Produces: `fetch_tdc_dataset(name: str, cache_dir: Path) -> pandas.DataFrame`
- Produces: `scaffold_split(frame: pandas.DataFrame, seed: int) -> dict[str, pandas.DataFrame]`

- [ ] **Step 1: Write failing tests using local HTTP fixtures and fixed SMILES**

```python
def test_scaffold_split_never_leaks_a_scaffold(self):
    frame = pandas.DataFrame({
        "Drug": ["Cc1ccccc1", "Oc1ccccc1", "C1CCCCC1", "CCO", "CCN"],
        "Y": [1.0, 0.8, 0.4, 0.2, 0.1],
    })
    split = scaffold_split(frame, seed=20260826)
    scaffolds = [set(map(scaffold_key, part.Drug)) for part in split.values()]
    self.assertFalse(scaffolds[0] & scaffolds[1])
    self.assertFalse(scaffolds[0] & scaffolds[2])
    self.assertFalse(scaffolds[1] & scaffolds[2])
```

- [ ] **Step 2: Run the focused test and verify the missing functions fail**

Run: `venv\\Scripts\\python.exe -m unittest test_fpga_model_profile.DatasetTests -v`

Expected: import or attribute failure for acquisition/split functions.

- [ ] **Step 3: Implement acquisition with cache-first behavior**

The ChEMBL fetcher must request target `CHEMBL203`, follow API pagination, retain finite `pchembl_value` rows with canonical SMILES, canonicalize via RDKit, and median-reduce duplicates. The TDC fetcher must retrieve `Lipophilicity_AstraZeneca`, `Bioavailability_Ma`, `hERG`, and `BBB_Martins` into `data/model_training_cache/`, normalize their columns to `Drug` and `Y`, and reuse a non-empty cached file on later runs.

- [ ] **Step 4: Implement deterministic Bemis-Murcko scaffold splitting**

Group rows by scaffold, shuffle groups using `numpy.random.default_rng(seed)`, then allocate complete scaffold groups toward 70% train, 10% validation, and 20% test. Empty/invalid molecules are discarded and counts are returned for the manifest.

- [ ] **Step 5: Run acquisition unit tests without network access**

Run: `venv\\Scripts\\python.exe -m unittest test_fpga_model_profile.DatasetTests -v`

Expected: fixture pagination, cache reuse, duplicate reduction, and scaffold isolation all pass.

### Task 3: Train, quantize, emulate, and package the five models

**Files:**
- Modify: `tools/train_fpga_models.py`
- Modify: `test_fpga_model_profile.py`
- Create: `models/fpga/egfr_admet_v1/manifest.json`
- Create: `models/fpga/egfr_admet_v1/weights.bin`

**Interfaces:**
- Produces: `train_gnn_activity(split: dict, seed: int) -> dict`
- Produces: `train_admet(split: dict, kind: str, seed: int) -> dict`
- Produces: `emulate_q8_graph(encoded: dict, weights: numpy.ndarray) -> tuple[float, float]`
- Produces: `emulate_q8_admet(descriptors: list[int], parameters: dict) -> float`
- Produces: `write_package(output_dir: Path, models: dict, metadata: dict) -> tuple[Path, Path]`

- [ ] **Step 1: Write failing deterministic packing and emulator tests**

```python
def test_weight_image_matches_existing_protocol_order(self):
    gnn = numpy.zeros(8192, dtype=numpy.int16)
    gnn[0:3] = (1, -2, 3)
    admet = []
    for value in range(4):
        admet.append({
            "hidden_weights": numpy.full(200, value + 10, dtype=numpy.int16),
            "hidden_biases": numpy.full(10, value + 20, dtype=numpy.int16),
            "output_weights": numpy.full(10, value + 30, dtype=numpy.int16),
            "output_bias": numpy.array([value + 40], dtype=numpy.int16),
        })
    image = pack_weight_image(gnn, admet)
    values = struct.unpack("<9076h", image)
    self.assertEqual(tuple(gnn), values[:8192])
    self.assertEqual((10, 10, 10), values[8192:8195])
    self.assertEqual(40, values[8192 + 220])
    self.assertEqual(18152, len(image))

def test_piecewise_sigmoid_matches_rtl_knots(self):
    self.assertEqual([0, 5, 30, 69, 128, 187, 226, 251, 256],
                     [sigmoid_q8(x) for x in (-2048,-1024,-512,-256,0,256,512,1024,2048)])
```

- [ ] **Step 2: Run emulator tests and verify they fail before implementation**

Run: `venv\\Scripts\\python.exe -m unittest test_fpga_model_profile.FixedPointTests -v`

Expected: missing trainer/emulator symbols.

- [ ] **Step 3: Implement compact NumPy training**

Train the EGFR graph readout against bounded pChEMBL values and four `20 -> 10 -> 1` networks. Use ReLU hidden activations, sigmoid outputs, deterministic initialization, class-balanced binary loss for the three classifiers, mean-square loss for bounded lipophilicity, early stopping on validation metrics, and no dependency beyond NumPy/RDKit/pandas/httpx.

- [ ] **Step 4: Implement bit-accurate Q8.8 emulation and low-halfword-first packing**

Mirror RTL rounding, saturation, ReLU, and piecewise sigmoid. Pack 8,192 GNN values, then for each ADMET model pack 200 hidden weights, 10 hidden biases, 10 output weights, and one output bias using `struct.pack("<9076h", ...)`.

- [ ] **Step 5: Run the training command and generate the model package**

Run:

```powershell
venv\Scripts\python.exe tools\train_fpga_models.py `
  --output models\fpga\egfr_admet_v1 `
  --cache data\model_training_cache `
  --seed 20260826
```

Expected: `weights.bin` is 18,152 bytes; `manifest.json` reports all five held-out metrics, split counts, CRC32, descriptor normalization, gefitinib reference, `validated: true`, and fixed-point drift no greater than 0.02.

- [ ] **Step 6: Run all model-package tests**

Run: `venv\\Scripts\\python.exe -m unittest test_fpga_model_profile.py -v`

Expected: all package, metric, and emulator checks pass.

### Task 4: Load the real profile and use target-specific hardware inputs

**Files:**
- Modify: `agents/fpga_client.py`
- Modify: `test_fpga_molecule_inference.py`
- Modify: `.env.example`

**Interfaces:**
- Consumes: `load_profile`, `validate_weight_image`, `encode_graph`, and `encode_descriptors`
- Produces: `FPGAClient.reload_model() -> dict[str, object]`
- Changes: `FPGAClient.evaluate_molecules(molecules, target="EGFR") -> dict[str, object]`

- [ ] **Step 1: Write failing tests for fixed reference, reload, and named outputs**

```python
def test_reference_is_manifest_ligand_not_first_candidate(self):
    summary = client.evaluate_molecules([{"id":"a","smiles":"CCO"}], target="EGFR")
    self.assertEqual(profile["target"]["reference_smiles"], summary["reference_smiles"])

def test_reload_accepts_one_epoch_word(self):
    result = client.reload_model()
    self.assertEqual("egfr_admet_v1", result["model_profile"])
    self.assertGreaterEqual(result["epoch"], 1)
```

- [ ] **Step 2: Run focused client tests and confirm the old behavior fails**

Run: `venv\\Scripts\\python.exe -m unittest test_fpga_molecule_inference.HardwareBatchEvaluationTests -v`

Expected: failures because candidate zero is still the reference and task `0xFE` is unsupported.

- [ ] **Step 3: Load and validate the configured profile**

Read `FPGA_MODEL_DIR`, defaulting to `models/fpga/egfr_admet_v1`. Keep `model_profile=None` and `ranking_eligible=False` on missing/invalid packages. Add `FPGA_AUTOLOAD_MODEL=false` to `.env.example`; no startup network write occurs unless explicitly enabled.

- [ ] **Step 4: Add task `0xFE` reload handling and rank eligibility**

`_request_words` must expect exactly one response word for reload. `reload_model` validates local length/CRC before sending, stores the returned epoch only on success, and never marks an unvalidated or target-mismatched profile rank-eligible.

- [ ] **Step 5: Replace demo encodings and output labels**

Use the manifest reference fingerprint for Tanimoto, virtual-node graph encoding for GNN, and manifest normalization for ADMET. Preserve raw fields and add named values:

```python
"gnn": {"egfr_activity_score": score, ...},
"admet": {
    "lipophilicity": value,
    "oral_bioavailability": probability,
    "herg_block_risk": probability,
    "bbb_permeability": probability,
    ...,
},
"model_profile": "egfr_admet_v1",
"ranking_effect": "eligible",
```

- [ ] **Step 6: Run client tests**

Run: `venv\\Scripts\\python.exe -m unittest test_fpga_molecule_inference.py -v`

Expected: existing batching tests plus fixed-reference, reload, named-output, 49-atom, target-mismatch, and fallback tests pass.

### Task 5: Blend validated hardware scores into reviewer ordering

**Files:**
- Modify: `agents/reviewer.py`
- Modify: `agents/orchestrator.py`
- Create: `test_fpga_ranking.py`

**Interfaces:**
- Consumes: `hardware_score(evaluation: dict) -> float | None`
- Changes: orchestrator call to `fpga_client.evaluate_molecules(molecules, target=target)`
- Produces: additive `score_breakdown.fpga_hardware` and `ranking_effect` fields

- [ ] **Step 1: Write failing ordering and fallback tests**

```python
def test_valid_hardware_score_can_change_candidate_order(self):
    properties = {
        "lipinski_violations": 0, "lipinski_pass": True, "qed": 0.7,
        "sa_score": 3.0, "molwt": 400.0, "logp": 2.0, "tpsa": 80.0,
    }
    low = {
        "id": "baseline_favored", "smiles": "CCO", "properties": properties,
        "fpga_evaluation": {
            "status": "hardware_complete", "model_profile": "egfr_admet_v1",
            "ranking_effect": "eligible", "ranking_eligible": True,
            "gnn": {"egfr_activity_score": 0.1},
            "tanimoto": {"similarity": 0.1},
            "admet": {"lipophilicity_desirability": 0.2,
                      "oral_bioavailability": 0.1, "herg_block_risk": 0.9,
                      "bbb_permeability": 0.1},
        },
    }
    high = copy.deepcopy(low)
    high["id"], high["smiles"] = "hardware_favored", "CCN"
    high["fpga_evaluation"]["gnn"]["egfr_activity_score"] = 0.95
    high["fpga_evaluation"]["tanimoto"]["similarity"] = 0.9
    high["fpga_evaluation"]["admet"] = {
        "lipophilicity_desirability": 0.9, "oral_bioavailability": 0.9,
        "herg_block_risk": 0.05, "bbb_permeability": 0.9,
    }
    result = ReviewerAgent().review({"generated_molecules": [low, high]})
    self.assertEqual("hardware_favored", result["top_candidates"][0]["id"])
    self.assertIn("fpga_hardware", result["top_candidates"][0]["score_breakdown"])

def test_demo_or_failed_hardware_keeps_baseline_scores(self):
    molecule = {
        "id": "candidate", "smiles": "CCO",
        "properties": {"lipinski_violations": 0, "lipinski_pass": True,
                       "qed": 0.7, "sa_score": 3.0, "molwt": 400.0,
                       "logp": 2.0, "tpsa": 80.0},
    }
    baseline = ReviewerAgent().review({"generated_molecules": [molecule]})
    demo = copy.deepcopy(molecule)
    demo["fpga_evaluation"] = {
        "status": "hardware_complete", "model_profile": "deterministic_demo_q8_8",
        "ranking_effect": "ineligible", "ranking_eligible": False,
    }
    fallback = ReviewerAgent().review({"generated_molecules": [demo]})
    self.assertEqual(baseline["scoring_details"][0]["total_score"],
                     fallback["scoring_details"][0]["total_score"])
```

- [ ] **Step 2: Run ranking tests and verify the valid hardware case fails**

Run: `venv\\Scripts\\python.exe -m unittest test_fpga_ranking.py -v`

Expected: valid hardware currently has no effect on order.

- [ ] **Step 3: Separate baseline calculation from optional hardware blending**

Keep the existing six baseline component weights unchanged. If `hardware_score` returns a value, set `score_breakdown["fpga_hardware"]`, calculate `0.70 * baseline + 0.30 * hardware`, and set `ranking_effect="blended_30_percent"`. If it returns `None`, keep the exact baseline total and expose the existing FPGA fallback reason without changing verdict thresholds.

- [ ] **Step 4: Pass the normalized target into FPGA evaluation**

Change only the backend call site:

```python
generation["fpga_batch"] = fpga_client.evaluate_molecules(
    generation["generated_molecules"], target=target
)
```

- [ ] **Step 5: Run ranking and orchestration tests**

Run: `venv\\Scripts\\python.exe -m unittest test_fpga_ranking.py test_fpga_molecule_inference.py -v`

Expected: hardware can change EGFR ordering only for a validated/reloaded profile, and every fallback retains baseline ordering and scores.

### Task 6: Prove frontend/API compatibility and document operation

**Files:**
- Create: `docs/FPGA_REAL_MODEL.md`
- Modify: `test_core_frontend_contract.py`
- Modify: `test_ready_frontend_contract.py`

**Interfaces:**
- Verifies existing POST pipeline input and output fields
- Documents local training, explicit reload, status checks, and board comparison

- [ ] **Step 1: Record a frontend tree hash before backend work**

Run:

```powershell
Get-ChildItem ..\molrecommender-frontend -File -Recurse |
  Sort-Object FullName |
  Get-FileHash -Algorithm SHA256 |
  ForEach-Object { "$($_.Hash) $($_.Path)" } |
  Set-Content data\frontend-tree-before.txt
```

Expected: a deterministic list of frontend file hashes is saved outside the frontend directory.

- [ ] **Step 2: Extend backend contract tests for additive fields**

Assert the existing status, pipeline, summary, generated molecule, and reviewer fields still exist with the same types when FPGA is disabled and when it is enabled. Do not assert that a frontend change consumes the new fields.

- [ ] **Step 3: Write deployment and scientific-limit documentation**

Document the exact training command, model files, profile validation, explicit `reload_model`/CLI procedure, health checks, expected epoch, output labels, scoring formula, fallback behavior, dataset provenance, metrics, and the non-clinical limitation.

- [ ] **Step 4: Run the complete backend regression suite**

Run: `venv\\Scripts\\python.exe -m unittest discover -p "test*.py" -v`

Expected: all existing and new tests pass.

- [ ] **Step 5: Compare the frontend tree hash**

Run the same hash pipeline to `data\\frontend-tree-after.txt`, then:

```powershell
Compare-Object (Get-Content data\frontend-tree-before.txt) `
               (Get-Content data\frontend-tree-after.txt)
```

Expected: no output, proving the frontend tree is unchanged.

### Task 7: Reload and validate on the connected Z15 board

**Files:**
- Read: `models/fpga/egfr_admet_v1/weights.bin`
- Read: `models/fpga/egfr_admet_v1/manifest.json`
- Read: `D:/FPGA/software/host/mol_tcp_client.py`
- Modify only if evidence requires it: none

**Interfaces:**
- Consumes the existing TCP task `0xFE` and three accelerator task IDs
- Produces an observed reload epoch and board-versus-emulator comparison log

- [ ] **Step 1: Check board health without writing state**

Run: `Invoke-RestMethod http://192.168.1.10/api/fpga/health | ConvertTo-Json`

Expected: `online=true`, `fault=false`, and the TCP service is reachable on port 5001.

- [ ] **Step 2: Reload the generated weight package**

Run:

```powershell
venv\Scripts\python.exe D:\FPGA\software\host\mol_tcp_client.py `
  --host 192.168.1.10 reload `
  models\fpga\egfr_admet_v1\weights.bin
```

Expected: an OK response containing one epoch word greater than the pre-reload epoch.

- [ ] **Step 3: Run a known-molecule board comparison**

Use the backend client to encode gefitinib plus at least two held-out EGFR molecules, run Tanimoto/GNN/ADMET, and compare every returned score with `emulate_q8_graph`/`emulate_q8_admet`.

Expected: raw board words exactly equal emulator words; named probability drift from the stored floating-point reference is at most 0.02.

- [ ] **Step 4: Run one real backend pipeline request without any frontend change**

Submit the existing pipeline request format with target `EGFR`, then verify multiple candidates, a fixed reference ligand, `model_profile=egfr_admet_v1`, `ranking_effect=blended_30_percent`, named GNN/ADMET results, and reviewer ordering based on the blended score.

- [ ] **Step 5: Run the full regression suite once more**

Run: `venv\\Scripts\\python.exe -m unittest discover -p "test*.py" -v`

Expected: all tests pass after live-board validation; the frontend hash comparison remains empty.
