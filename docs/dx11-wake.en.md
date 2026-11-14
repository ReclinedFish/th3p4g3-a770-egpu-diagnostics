# Native Direct3D 11 wake retest

[中文](dx11-wake.md) · [Main report](../README.en.md)

After reconnecting the TH3P4G3 dock and confirming that Windows recognized the Intel Arc A770, native Direct3D 11 initialized successfully in all four runs. No Thunderbolt disconnect or new `LiveKernelEvent 141` appeared during the runs or the final idle observation.

Kryptex stayed closed. Before each launch, the A770's most recent device power state reported by Windows via `DEVPKEY_Device_PowerData` was **D3**. The test created a Feature Level 11_0 device on the A770, used a GPU fence to confirm each batch completed, and read back and checked four output values at the end of each run.

| Run | Idle before launch | Runtime | Completed GPU dispatches | Readback |
|---|---:|---:|---:|---|
| First run after reconnect | Already in D3 | 300.02 s | 2,181,248 | 4/4 passed |
| First launch after idle | 2 min | 30.02 s | 219,072 | 4/4 passed |
| Second launch after idle | 2 min | 30.01 s | 218,816 | 4/4 passed |
| Third launch after idle | 2 min | 30.02 s | 218,880 | 4/4 passed |

Monitoring continued for two minutes after the final run. The logs showed no Thunderbolt disconnect, related PnP surprise removal, new WATCHDOG dump, or `141`. The A770 and dock remained online, and the A770's device problem code was `0` at the final check.

This test covered one machine. The cable and port used for the retest were not recorded. The previously observed intermittent DX11 initialization failure did not recur in these four runs, and its cause remains unresolved.

On Windows, install the .NET 10 SDK and PowerShell 7. Connect the A770, close Kryptex, and verify automatic discovery as described in the [main report](../README.en.md). Configure local instance paths only if an explicit override is needed. Run these commands from the repository root:

```powershell
dotnet build .\tools\Dx11ArcBatched\Dx11ArcBatched.csproj -c Release
.\tools\Test-Dx11Wake.ps1
```

The [test runner](../tools/Test-Dx11Wake.ps1) defaults to the durations in the table and writes local results to `tools/captures/`. In `run.tsv`, a run covers D3 wake-up when it records `PrePower=D3`. The exit code indicates the DX11 test outcome. Review `timeline.tsv` and `events.jsonl` for disconnect and 141 records, matching device paths and dump filenames. If you have multiple A770s, leave only the target A770 online. Redact local logs before sharing.
