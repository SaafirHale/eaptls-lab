---
title: An unreachable CRL looks like a radio problem
date: 2026-10-26
summary: Rebuilding a certificate-based 802.1X rollout in a Hyper-V lab, then breaking it the way production broke: one blocked route to the CRL, and a valid certificate stops working.
tags: [802.1x, eap-tls, pki, lab]
draft: true
---

<!--
  Draft for saafirhale-site/src/content/notes. Two [brackets] below are filled from
  RUNLOG.md after the lab's first run; do not publish with them in place.
  Check the "split-VPN" paragraph against what actually happened in production.
-->

The certificate-based Wi-Fi rollout I ran across 30 sites has no public artifact: the
configuration belongs to the job. So I rebuilt it from scratch, in miniature, as a
[lab anyone can run](/work/8021x-eap-tls-deployment): a domain controller running NPS, an
enterprise CA handing out machine certificates through Group Policy autoenrollment, a
Windows 11 client, and a small Linux VM playing the switch port. Every piece is a PowerShell
script; nothing comes from the real environment.

The point of the lab is not that it works. It is how it fails.

## Who checks the CRL

In EAP-TLS the device proves who it is with a certificate, and the RADIUS server decides
whether to believe it. Part of believing it is checking that the certificate has not been
revoked, which means fetching the CA's certificate revocation list from the URL printed
inside the certificate.

The detail that matters: the device is not the one fetching it. When the decision is made,
the device is sitting on a closed port with no network at all. The fetch that decides
everything is made by the RADIUS server, from wherever the RADIUS server sits. Microsoft's
default is strict: if NPS cannot retrieve the CRL, the certificate fails the revocation check
and authentication fails.

## Breaking it on purpose

The demo changes exactly one thing. The client, its certificate, the CA, the switch port and
the policy stay as they were. A firewall rule stops the NPS server from reaching the CRL's
web host, the way a split-tunnel VPN route can quietly leave the PKI host out.

| | NPS decision | Reason code | Client |
| --- | --- | --- | --- |
| Before | 6272, granted | | on the network |
| CRL unreachable | 6273, denied | [code and text from RUNLOG] | no network |
| Route restored | 6272, granted | | on the network |

From the client's side there is nothing to see except that the network does not work. From
the floor, that is a radio problem. The Security log on the RADIUS server is the only place
the real cause is written down.

## The delay that hides it

NPS caches a CRL until it expires. Cut the route today and authentication keeps working,
right up until the cached CRL runs out days later. By then nobody connects the outage to the
change that caused it. The lab has to purge that cache on every phase just to make the
failure show up on cue. [Time-to-failure without the purge, from RUNLOG.]

## What I took from it

Reachability of the CDP is a property of the RADIUS server's network path, not of the CA and
not of the client. It has to be proven from the server that does the checking, per site,
before anyone touches an access point. `certutil -verify -urlfetch`, run on the RADIUS server
against a real client certificate, answers that in one command. In the rollout, reachability
was proven per site rather than assumed. The lab is where I can show why that mattered.
