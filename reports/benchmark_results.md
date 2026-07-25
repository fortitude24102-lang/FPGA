# FPGA accelerator benchmark

## Python baseline

| Workload | Mean time |
|---|---:|
| Tanimoto, per molecule | 0.006110 ms |
| GNN, one 50-node graph | 13.470600 ms |
| ADMET four-model prediction, per molecule | 0.031905 ms |
| End-to-end, per molecule | 13.508615 ms |

## FPGA measurement

Not supplied. Run again with `--fpga-results timings.json`.
The timing JSON must contain `tanimoto_ms`, `gnn_ms`, `admet_ms`, and `end_to_end_ms`.
