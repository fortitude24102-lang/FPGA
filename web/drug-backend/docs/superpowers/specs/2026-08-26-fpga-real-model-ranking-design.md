# FPGA Real-Model Ranking Design

## Objective

Replace the deterministic FPGA demonstration weights with reproducible, public-data-trained weights and make successful hardware inference affect candidate ranking, while preserving every existing frontend file and request contract.

## Non-negotiable constraints

- Do not modify anything under `molrecommender-frontend/`.
- Do not change existing frontend request paths, HTTP methods, or required request fields.
- Existing response fields remain present with their current types; new model and score details are additive only.
- Do not modify the current FPGA RTL, register map, TCP framing, or DMA weight-reload protocol.
- Production runtime dependencies remain limited to the packages already listed in `requirements.txt`.
- FPGA failure, disabled mode, an unknown target, or an unvalidated model must preserve the current CPU-only ranking behavior.
- Version 1 supports a trained target-activity model only for EGFR. Other targets continue through the current ranking path.

## Selected architecture

The implementation reuses the programmed hardware shapes exactly:

- Tanimoto: 1024-bit Morgan fingerprint similarity against a target-specific reference ligand.
- GNN: one `50 x 64 -> 128` Q8.8 message-passing layer. Node 0 becomes a virtual graph node, real atoms occupy nodes 1 through 49, and row 0 of the adjacency matrix connects the virtual node to every atom. The first returned hidden value is trained as a bounded EGFR activity score.
- ADMET: four independent `20 -> 10 -> 1` Q8.8 networks mapped to lipophilicity, oral bioavailability, hERG block risk, and blood-brain-barrier penetration.

No hardware architecture change is required. Training is intentionally compact and hardware-native rather than presented as a state-of-the-art molecular foundation model.

## Data and training

- EGFR activity records are downloaded from the ChEMBL REST API for target `CHEMBL203`. Only canonical SMILES with finite standardized activity values are retained; duplicate structures are reduced to a median label.
- ADMET records use the public TDC datasets `Lipophilicity_AstraZeneca`, `Bioavailability_Ma`, `hERG`, and `BBB_Martins`.
- Dataset acquisition is a training-time operation. Raw downloaded datasets are cached outside the runtime package and are not required to start the API.
- Molecules are split by Bemis-Murcko scaffold into train, validation, and test partitions with a deterministic seed.
- Training uses NumPy and RDKit already present in the environment. It does not add PyTorch, TensorFlow, scikit-learn, or a production dependency.
- Continuous targets are mapped to a documented bounded `[0, 1]` range because the current ADMET output activation is sigmoid. Binary endpoints use probabilities.

## Feature and numeric contract

- All FPGA inputs and weights use signed Q8.8; Tanimoto results remain unsigned Q16.16.
- Atom features keep the current atomic-number, degree, formal-charge, and aromatic indicators.
- The virtual graph node uses the currently unused feature positions for a constant term and normalized graph descriptors. This gives the no-bias GNN layer a reproducible graph-level readout without changing RTL.
- Molecules with more than 49 real atoms are not hardware-encodable in this profile and follow the existing fallback path.
- Descriptor centers and scales are learned from the training split and stored in the model manifest. Backend encoding must use the manifest values, not hard-coded demo scaling.
- Quantization saturates to signed 16-bit Q8.8 and weight order matches the existing 9,076-halfword image: 8,192 GNN weights followed by four groups of 221 ADMET parameters.

## Model package

`models/fpga/egfr_admet_v1/` contains:

- `manifest.json`: profile name, schema version, target, reference ligand, descriptor order, normalization values, output labels, target transforms, dataset provenance, split seed, metrics, Q8.8 format, expected word counts, and weight CRC32.
- `weights.bin`: exactly 18,152 bytes in the existing low-halfword-first reload order.

The profile becomes rank-eligible only when the manifest validates, the weight image length and CRC match, the target is EGFR, and the board reports a successful reload epoch. Otherwise inference metadata may be returned, but it cannot alter ranking.

## Reference ligand

EGFR uses a fixed, canonical gefitinib reference SMILES stored in the model manifest. The first generated candidate is never used as its own reference. This removes the guaranteed 1.0 similarity artifact and makes all candidates comparable across requests.

## Ranking integration

The existing reviewer score remains the baseline. When and only when a validated `egfr_admet_v1` hardware result is present:

1. Build a hardware score on a 0-100 scale:
   - EGFR activity score: 35%
   - Tanimoto similarity: 20%
   - oral bioavailability probability: 15%
   - BBB probability: 10%
   - lipophilicity desirability: 10%
   - inverse hERG block risk: 10%
2. Set `total_score = 0.70 * baseline_score + 0.30 * hardware_score`.
3. Re-sort candidates using `total_score` and apply the existing PASS/CONDITIONAL/REJECT thresholds.

The candidate receives additive fields in its existing result object:

- `score_breakdown.fpga_hardware`
- `fpga_evaluation.model_profile`
- `fpga_evaluation.ranking_effect`
- named GNN and ADMET predictions while retaining raw values

If hardware ranking is ineligible, `total_score` is byte-for-byte equivalent to the previous formula and `ranking_effect` explains the fallback reason.

## Loading and lifecycle

- A backend method validates and uploads `weights.bin` through task `0xFE`, using CRC32 in the existing protocol.
- Loading is explicit at deployment/startup configuration time and is idempotent for the same validated profile.
- A failed upload leaves the previous active FPGA bank untouched and disables hardware ranking for the process.
- Health/status responses may expose additive model profile, epoch, and rank-eligibility fields; existing fields are unchanged.

## Verification and acceptance

- Unit tests lock the frontend-facing request/response contracts and assert the frontend tree is unchanged by this work.
- Encoder tests verify the virtual-node placement, 49-atom limit, fingerprint reference, descriptor normalization, and exact payload sizes.
- Model-package tests verify manifest schema, 18,152-byte image length, parameter order, signed Q8.8 saturation, and CRC32.
- Ranking tests prove that valid hardware results can change ordering and that disabled, failed, demo, unknown-target, or malformed results leave ordering unchanged.
- Numeric tests compare floating-point training inference with a bit-accurate Q8.8 software emulator. Maximum probability drift must be at most 0.02 on the held-out samples included in the package report.
- Dataset reports include scaffold-split sample counts and predictive metrics: MAE/RMSE for continuous endpoints and AUROC plus balanced accuracy for binary endpoints. Metrics are reported honestly rather than used to claim clinical validity.
- Board acceptance reloads the package, runs known molecules through all three accelerators, verifies the epoch/CRC, and compares board outputs with the Q8.8 emulator.

## Explicit exclusions

- No frontend redesign or frontend source edit.
- No RTL graph-pooling layer, wider network, or new accelerator.
- No claim that these compact public-data models are suitable for clinical decisions.
- No hardware-derived ranking when the model/profile validation chain is incomplete.
