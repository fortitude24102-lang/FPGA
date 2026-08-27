# FPGA real-model ranking

`egfr_admet_v1` is a compact, hardware-compatible EGFR/ADMET package. It is used only as a gated input to candidate ranking: it does not replace the existing CPU reviewer and it is not a clinical prediction system.

## Train and package

From `drug-backend`, train from the public source data and write the runtime package with:

```powershell
venv\Scripts\python.exe tools\train_fpga_models.py --cache data\fpga_training_cache --output models\fpga\egfr_admet_v1 --seed 20260826
```

The command downloads or reuses the cache, performs the deterministic Bemis-Murcko scaffold 70/10/20 split, trains the compact models, measures float-versus-Q8.8 drift, and writes:

* `models/fpga/egfr_admet_v1/manifest.json` — schema, dataset provenance, descriptor normalization, labels, metrics, validation state, and weight checksum.
* `models/fpga/egfr_admet_v1/weights.bin` — 9,076 signed Q8.8 little-endian halfwords (18,152 bytes), with the low halfword first.

Before upload, runtime loading requires a valid manifest, the exact 18,152-byte image, and the manifest's CRC32. The shipped image CRC32 is `f6a8fd53`. A package is rank eligible only when `validated` is true, the profile is `egfr_admet_v1`, and the requested target is EGFR.

## Reload and verify a board model

Model upload is explicit by default. Point `FPGA_MODEL_DIR` at a package only when it is outside the default directory; keep `FPGA_AUTOLOAD_MODEL=false` unless a startup write to the board is intentional.

With the backend environment configured for the board, reload through the client:

```powershell
venv\Scripts\python.exe -c "from agents.fpga_client import fpga_client; print(fpga_client.reload_model())"
```

A successful result is `status: reloaded`, `model_profile: egfr_admet_v1`, an integer board `epoch`, and `ranking_eligible: true`. The reload protocol uploads the validated image and reads one returned epoch word; retain that epoch with the board run record. A `profile_unavailable` or `reload_failed` result must not be used for ranking.

Check the running service after reload:

```powershell
Invoke-RestMethod http://127.0.0.1:8000/ready
Invoke-RestMethod http://127.0.0.1:8000/api/fpga/health
Invoke-RestMethod http://127.0.0.1:8000/api/v1/fpga/status
```

When FPGA is enabled, `/ready` reports `fpga: "ready"` only when the health result is online and fault-free. When disabled, readiness remains non-blocking and explains that state in `checks.fpga_reason`; `/api/fpga/health` reports `DISABLED`. Preserve the returned reload epoch, profile name, health response, trace IDs, and candidate `latency_ms` when comparing an actual board run with a reference run.

For a board comparison, reload once, submit the normal `POST /api/v1/pipeline` frontend profile with target `EGFR`, and inspect `data.steps.generator.result.generated_molecules[*].fpga_evaluation`. The batch reload epoch is returned at `data.steps.generator.result.fpga_batch.epoch`. A valid board result has `status: "hardware_complete"`, `model_profile: "egfr_admet_v1"`, `ranking_eligible: true`, the model reference ligand, raw output fields, named predictions, trace IDs, and latency. Compare these fields and `data.steps.generator.result.fpga_batch.epoch` against the reload record; do not compare an unknown target, an unvalidated package, or a fallback result as if it were a valid model run.

## Output labels and ranking

The named GNN outputs are `egfr_activity_score` and `egfr_activity_trace`. The named ADMET outputs are `lipophilicity_desirability`, `oral_bioavailability`, `herg_block_risk`, and `bbb_permeability`. Raw protocol outputs remain available (`raw_output_word`, `raw_q8_8`, and `predictions`) for traceability. The EGFR target reference is gefitinib; its SMILES is recorded in the manifest and is used for the Tanimoto comparison.

For a complete, eligible hardware evaluation, the hardware score is:

```text
100 × (0.35 × EGFR activity + 0.20 × Tanimoto similarity
       + 0.15 × oral bioavailability + 0.10 × BBB permeability
       + 0.10 × lipophilicity desirability + 0.10 × (1 − hERG block risk))
```

The reviewer preserves its existing CPU score and blends only an eligible result:

```text
final score = 0.70 × existing CPU reviewer score + 0.30 × hardware score
```

The blend is therefore additive to the API: existing status, pipeline, summary, generated-molecule, and reviewer fields retain their shapes and types. Hardware details live under the additive `fpga_evaluation` object, and `fpga_hardware` is added to the score breakdown only when the gated score is valid.

## Safe fallbacks

Ranking remains CPU-only, with the prior ordering and scores, when FPGA is disabled; the profile is absent, malformed, CRC-invalid, or unvalidated; the target is not EGFR; a molecule cannot be encoded; model reload fails; transport fails; or any required hardware score is missing, non-finite, or outside `[0, 1]`. These states are recorded as `disabled`, `profile_unavailable`, `target_mismatch`, `not_encodable`, `reload_failed`, or `fallback` as applicable, and are rank ineligible.

## Public-data provenance and held-out metrics

The EGFR activity source is the ChEMBL REST API for target `CHEMBL203`. ADMET sources are Therapeutics Data Commons: `Lipophilicity_AstraZeneca`, `Bioavailability_Ma`, `hERG`, and `BBB_Martins`. The shipped manifest records seed `20260826`, deterministic scaffold splits, per-dataset counts, transformations, and all metrics.

| Label | Held-out metric |
| --- | --- |
| EGFR activity | MAE 0.221952; RMSE 0.270474 |
| Lipophilicity desirability | MAE 0.252277; RMSE 0.284552 |
| Oral bioavailability | AUROC 0.552545; balanced accuracy 0.568044 |
| hERG block risk | AUROC 0.831478; balanced accuracy 0.731602 |
| BBB permeability | AUROC 0.855221; balanced accuracy 0.768268 |

The maximum recorded float-versus-Q8.8 probability drift is `0.011185`, below the package acceptance limit `0.02`.

## Research-only limitation

This is a compact public-data model intended for FPGA ranking research. Its public labels, limited target scope, quantization, and held-out metrics do not establish clinical validity, safety, efficacy, or suitability for patient care. Do not use it for diagnosis, treatment selection, dosing, or any clinical decision; experimental candidates require appropriate scientific validation.
