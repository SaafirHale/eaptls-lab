# Draft: portfolio entry update for `8021x-eap-tls-deployment`

Target file: `saafirhale-site/src/content/projects.ts`, the entry with
`slug: "8021x-eap-tls-deployment"`. Nothing in that repo has been edited; this is the
proposed change to apply by hand once the lab repo is public and has been run.

## What changes

1. **`links`**: add the lab repository (it does not exist on GitHub yet; the URL is the
   intended one).
2. **`body`**: one new closing paragraph about the lab. The three existing paragraphs stay
   word for word.
3. **`stack`**: add the tools the lab itself uses.
4. **`status`**: stays `"production"`. The rollout is real work; the lab is a companion
   artifact, not the thing itself. One snag: the `Status` type documents `"production"` as
   *"Real professional work. No public code link."* Adding a link breaks that comment. Either
   update the comment to "No public code link to the production work itself" or accept the
   inconsistency; changing the status to `"live"` would misdescribe the project.

## Proposed entry

```ts
  {
    slug: "8021x-eap-tls-deployment",
    category: "security",
    title: "Enterprise 802.1X / EAP-TLS Deployment",
    blurb:
      "Certificate-based WPA2-Enterprise Wi-Fi across 30 sites, with RADIUS/NPS hosted in Azure.",
    body: [
      "Designed and rolled out certificate-based WPA2-Enterprise Wi-Fi across 30 sites: ADCS certificate autoenrollment via GPO, NPS/RADIUS policy on Azure-hosted domain controllers, and CRL/CDP reachability validation across split-VPN topologies.",
      "The result is centralized, certificate-based network access control — devices authenticate as themselves rather than sharing a pre-shared key, and access can be revoked at the certificate rather than by rotating a password across thirty sites.",
      "The validation work mattered as much as the rollout. In split-VPN topologies a client that cannot reach the CRL distribution point fails authentication in ways that look like a radio problem, so reachability was proven per site rather than assumed.",
      "The production configuration stays private, so the design is rebuilt from scratch as a public lab: PowerShell that stands up a domain controller, an enterprise CA with GPO autoenrollment, NPS with an EAP-TLS network policy and a Windows 11 client on a wired 802.1X port, plus a demo that cuts the RADIUS server's path to the CRL distribution point and shows NPS denying the same certificate it accepted a minute earlier.",
    ],
    stack: ["802.1X", "EAP-TLS", "RADIUS/NPS", "Microsoft Azure", "ADCS", "Group Policy", "PowerShell", "Hyper-V", "hostapd"],
    links: [{ label: "Lab: EAP-TLS rebuilt in Hyper-V", href: "https://github.com/SaafirHale/eaptls-lab" }],
    status: "production",
    featured: true,
  },
```

## Why each claim is safe to publish

| Claim in the new paragraph | Verifiable from |
| --- | --- |
| Production configuration stays private; the lab is built from scratch | The lab repo: lab-only names (`lab.example`, `LAB-ROOT-CA`), no employer or client data |
| PowerShell stands up DC, enterprise CA + GPO autoenrollment, NPS + EAP-TLS policy, Windows 11 client on wired 802.1X | `Build-Lab.ps1` and `roles/` in the repo |
| A demo cuts the RADIUS server's path to the CDP | `demo/Set-LabCdpBlock.ps1`, `demo/Invoke-LabDemo.ps1` |
| NPS denies the same certificate it accepted a minute earlier | **Only after a real run.** Publish this clause once `RUNLOG.md` holds the observed 6272 → 6273 → 6272 sequence. Until then, end the sentence at "...path to the CRL distribution point." |

Nothing in the new text adds a number, a site count, a client name or an outcome from
the production rollout beyond what the entry already says.

## One wording question for the existing third paragraph (not changed above)

The existing text says *"a client that cannot reach the CRL distribution point fails
authentication"*. In EAP-TLS the CRL check on the **client** certificate is done by the
**RADIUS server** (NPS), because the client is still on an unauthorized port with no network
when the decision is made. The lab demonstrates that mechanism: NPS losing its route to the
CDP.

If the production lesson was NPS (on the Azure-hosted DCs) failing to reach the CDP over the
split-VPN routes, a more precise version would be:

> In split-VPN topologies a RADIUS server that cannot reach the CRL distribution point
> rejects perfectly valid certificates, and from the floor it looks like a radio problem, so
> reachability was proven per site rather than assumed.

If the production lesson really was on the client side (clients checking the NPS server
certificate), keep the original wording; that is a different mechanism from the one the lab
shows, and the lab's write-up should then say so. Only Saafir can say which it was.
