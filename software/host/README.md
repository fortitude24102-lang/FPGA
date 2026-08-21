# Z15 TCP accelerator client

`mol_tcp_client.py` is a deterministic, standard-library-only Windows client
for the bare-metal service at `192.168.1.10:5001`. Configure the PC Ethernet
adapter to `192.168.1.2`, subnet mask
`255.255.255.0`; no gateway or DNS is required for the direct cable.

## Acceptance commands

```powershell
py -3 software/host/mol_tcp_client.py --host 192.168.1.10 selftest
py -3 software/host/mol_tcp_client.py --host 192.168.1.10 queue-test
py -3 software/host/mol_tcp_client.py --host 192.168.1.10 reload test_data/selftest_weights.bin
py -3 software/host/mol_tcp_client.py --host 192.168.1.10 selftest
```

`selftest` checks three exact Tanimoto results, GNN, all four ADMET outputs,
and the complete Tanimoto-to-GNN-to-ADMET pipeline. `queue-test` opens all five
supported connections, verifies the eight-entry global FIFO order, and
requires at least one immediate busy response.

Other commands expose individual tasks:

```powershell
py -3 software/host/mol_tcp_client.py tanimoto 0xffffffff 0xffffffff
py -3 software/host/mol_tcp_client.py gnn
py -3 software/host/mol_tcp_client.py admet --batch 64
py -3 software/host/mol_tcp_client.py pipeline
py -3 software/host/mol_tcp_client.py reload test_data/reference_weights.bin
```

Every successful request displays its trace ID, result word count, wall-clock
latency, and hexadecimal result words. Server busy and error responses exit
nonzero and report their numeric code and detail.

`selftest_weights.bin` exactly matches the sparse deterministic weights loaded
at service startup, so it is the canonical hot-reload acceptance image.
`reference_weights.bin` contains the synthetic dataset's complete GNN/ADMET
model; loading it intentionally changes GNN, ADMET, and Pipeline outputs and
must not be followed by the fixed-output `selftest`.

## Rebuild the dataset model image

```powershell
py -3 software/host/mol_tcp_client.py pack-weights `
  --output test_data/reference_weights.bin
```

The command validates all source `.mem` element counts before creating exactly
18,152 little-endian bytes: 8,192 GNN signed Q8.8 values followed by, for each
of four ADMET models, 200 hidden weights, 10 hidden biases, 10 output weights,
and one output bias.

Run the local codec suite without a board:

```powershell
py -3 software/host/test_mol_tcp_client.py
```

The suite currently contains 11 deterministic tests, including acceptance of
the documented fallback response flag and rejection of
reserved/inconsistent response flags and mismatched echoed batch sizes.
