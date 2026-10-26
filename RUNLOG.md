# Run log

Each entry records what was run, on what, and what actually happened. "Expected" comes
from the scripts and Microsoft's documentation; "Observed" is filled in only from a real
run, with the evidence file it came from (`C:\Lab\eaptls\out\`). Blank means not run yet.

Host: Windows 11 Pro 10.0.26200, Intel i7-8650U (4 cores / 8 threads), 16 GB RAM.

---

## Run 0: static checks, 2026-10-26 (no Hyper-V)

Hyper-V was not enabled (`Win32_ComputerSystem.HypervisorPresent = False`), so nothing could
boot. Everything that can be checked without a hypervisor was.

| Step | Command | Result |
| --- | --- | --- |
| Lint | `.\tools\Invoke-LabLint.ps1` (PowerShell parser + PSScriptAnalyzer 1.25.0 targeting Windows PowerShell 5.1, `bash -n` on shell scripts) | `Lint clean: 30 PowerShell files parsed and analyzed.` |
| Templates | `.\tools\Test-LabTemplates.ps1` (render with dummy values; unattend as XML, cloud-init as YAML via PyYAML 6.0.3) | 7/7 OK: both answer files parse as XML; user-data, meta-data and network-config parse as YAML; hostapd and eapol_test configs render with no leftover tokens |

Design changes made before any run, from documentation:

- NPS moved to a Desktop Experience DC01: NPAS is on Microsoft's list of roles not available
  on Server Core.
- The NPS network policy is imported from a captured export instead of being built with
  `netsh nps add np`: the EAP-TLS attribute (msEAPConfiguration) is an undocumented blob.
- `radius_auth_req_attr=61:d:15` added to hostapd and `-N61:d:15` to eapol_test: upstream
  source (`src/ap/ieee802_1x.c`, `wpa_supplicant/eapol_test.c`) adds NAS-Port-Type 19
  (802.11) unless that attribute is configured.

---

## Run 1: first build

Fill in as it runs. `Build-Lab.ps1` writes a full transcript to `out\build-<timestamp>.log`.

### Prerequisites

| Step | Expected | Observed |
| --- | --- | --- |
| `.\host\Enable-HyperV.ps1`, reboot | `Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All` reports Enabled | |
| Media in `C:\Lab\iso\` | Three files from README "Media" | |

### Stages

| Stage | Expected | Observed | Time |
| --- | --- | --- | --- |
| Network | `LabNet` (Internal), `LabAccess` (Private), host vNIC 10.20.0.1/24, NAT `LabNat` | | |
| BaseDisks | `ws2025-core.vhdx`, `ws2025-desktop.vhdx`, `win11-ent.vhdx` under `C:\Lab\eaptls\base`, read-only | | |
| Domain | DC01 answers PowerShell Direct; `Get-ADDomain` returns lab.example; OU `Lab Workstations`, group `LAB-8021X-Computers`, CNAME `pki` → CA01 | | |
| Pki | CA01 joined; CDP and AIA list only the local path and `http://pki.lab.example/CertEnroll/...`; every CertEnroll file returns HTTP 200 by that name; templates `LabComputerAuth` and `RASAndIASServer` published | | |
| Nps (first build) | GPO linked; NPS installed, DC01 in `RAS and IAS Servers`, RASAndIASServer certificate in LocalMachine\My; stops with "Network policy ... does not exist" | | |
| One-time GUI step | Policy built per `docs/nps-policy-gui.md` | | |
| NpsCapture | `roles/dc01/nps/nps-config.template.xml` written, contains `{{NPS_CERT_THUMBPRINT}}` and `{{RADIUS_SECRET}}`, no clear-text secret | | |
| Nps | Policy present, RADIUS client AUTH01 10.20.0.40, `PolicyUsesCert = True` | | |
| Client | CLIENT01 in OU `Lab Workstations` and group `LAB-8021X-Computers`; certificate from `LabComputerAuth` with SAN `CLIENT01.lab.example` and CDP `http://pki.lab.example/...`; LAB-ROOT-CA in machine Root store; dot3svc Running; LAN profile added | | |
| Authenticator | cloud-init done; `nftables`, `dot1x-hostapd`, `dot1x-gate` active | | |
| Attach: EAPOL path | `Test-LabEapolPath.ps1`: EAPOL frames from CLIENT01's MAC on AUTH01 `access`, or a clear "use eapol_test" verdict | | |
| Attach: first auth | NPS 6272 for `host/CLIENT01.lab.example` via policy `Lab Wired 802.1X EAP-TLS`; CLIENT01 MAC in `bridge dot1x authorized`; CLIENT01 pings DC01 | | |

Things to look at on the first run whatever happens:

- [ ] `cat /sys/class/dmi/id/chassis_asset_tag` on AUTH01, and `cloud-init status --long`
      (which datasource was used).
- [ ] `netsh lan export profile folder=C:\ProgramData\eaptls-lab` on CLIENT01; diff against
      the profile the script wrote.
- [ ] `certutil -dstemplate LabComputerAuth` on CA01; compare flags with an MMC-duplicated
      Workstation Authentication template.

---

## Run 1: failure demo

`.\demo\Invoke-LabDemo.ps1` (or `-Method EapolTest`). Evidence: `out\demo-*`.

| Phase | Expected | Observed: event, ReasonCode, Reason | Client on network |
| --- | --- | --- | --- |
| 1 Baseline | 6272 Granted | | |
| 2 Break (NPS → CDP blocked, caches cleared) | 6273 Denied, revocation reason code (258 or 259 in Microsoft's table) | | |
| 3 Prove (`certutil -verify -urlfetch` on DC01) | CDP URL fails; `CRYPT_E_REVOCATION_OFFLINE` | | n/a |
| 4 Restore | 6272 Granted | | |

Also worth recording from phase 2:

- [ ] What the client shows: `netsh lan show interfaces` state and the
      Wired-AutoConfig/Operational event IDs and text.
- [ ] How long the client takes to give up, from the evidence timestamps.
- [ ] Optional: phase 2 again **without** clearing caches, to time how long a cached CRL
      masks the outage.
