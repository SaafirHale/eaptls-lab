# One-time step: build the EAP-TLS network policy in nps.msc

The EAP-TLS settings of an NPS network policy are stored as an undocumented binary blob, and
the NPS PowerShell module has no network-policy cmdlets. NPS's own answer for repeatable
deployments is export/import, so the policy is built by hand **once**, captured into
`roles/dc01/nps/nps-config.template.xml`, and imported by script on every rebuild after that.
Once the template is committed, nobody has to do this again.

Prerequisite: `.\Build-Lab.ps1 -Stage Nps` has run once and stopped with "Network policy ...
does not exist". At that point NPS is installed, registered in AD, has its server certificate,
and the RADIUS client for AUTH01 exists.

1. Open DC01's console: `vmconnect.exe localhost DC01`, sign in as `LAB\Administrator`
   (password: `Import-Clixml C:\Lab\eaptls\secrets\AdminPassword.clixml` on the host).
2. Run `nps.msc`. Expand **Policies > Network Policies**, right-click, **New**.
3. **Policy name:** `Lab Wired 802.1X EAP-TLS` (must match `Radius.PolicyName` in
   `lab.config.psd1`). Type of network access server: **Unspecified**. Next.
4. **Conditions**, add two:
   - **Windows Groups:** `LAB\LAB-8021X-Computers`
   - **NAS Port Type:** under Common 802.1X connection tunnel types, tick **Ethernet** only
5. **Access Permission:** Access granted.
6. **Authentication Methods:**
   - Untick every box under "Less secure authentication methods" (MS-CHAP-v2, MS-CHAP, CHAP,
     PAP, unauthenticated).
   - **Add...** under EAP Types: **Microsoft: Smart Card or other certificate**. Select it,
     **Edit...**, and pick the certificate issued by **LAB-ROOT-CA** to `DC01.lab.example`
     (the RAS and IAS Server certificate). OK.
7. **Constraints:** none. **Settings:** leave the defaults. Finish.
8. Move the new policy to **processing order 1** (right-click, Move Up) so the two built-in
   deny policies never get evaluated first.

Then, on the host:

```powershell
.\Build-Lab.ps1 -Stage NpsCapture
```

That exports the configuration, replaces the server certificate thumbprint, the RADIUS
secret, AUTH01's address and the domain SID with tokens, refuses to save if the policy does
not actually reference the server certificate, and writes the template into the repo.
Commit it. From then on, `-Stage Nps` on a fresh build imports it with no GUI at all.
