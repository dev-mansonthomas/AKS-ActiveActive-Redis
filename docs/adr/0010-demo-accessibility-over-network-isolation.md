# ADR 0010 — Prefer reachability over network isolation; secure with auth + TLS, not firewalls

- **Status:** Accepted
- **Date:** 2026-09-04
- **Decided by:** the repo owner, explicitly, during the documentation migration
- **Supersedes:** the initial reading of the `0.0.0.0/0` GCP firewall rule as a straightforward
  defect

## Context

A prior review flagged `providers/gcp/main.tf`'s `redis-allow-redis-ports` firewall — which opens
TCP `8001`, `8443`, `9443` and `10000-19999` (the Redis Enterprise **database endpoint** range) to
`0.0.0.0/0` — as the highest-severity issue in the repository, and recommended scoping it to the
VPC CIDR plus known client IPs.

That recommendation was **wrong for this product**. The stated requirements are:

- **One command to set up the demo; one command to tear it down.**
- Connecting to the **database**, the **management UI**, or the **status console** **from
  anywhere** is a *must* — an SA demos from a customer site, a hotel, a phone tether.
- A demo may live **two hours, or several weeks**.
- *"We must implement security, but not at the cost of usability."*

Scoping the firewall to fixed client IPs, or making the K8s control plane private, would satisfy a
generic hardening checklist while **breaking the product**. A demo an SA cannot reach is worthless.

## Decision

**Keep the endpoints publicly reachable. Move the security boundary from the network layer to
authentication, authorisation and encryption.**

Concretely:

1. **Public reachability is a feature.** Do not scope the DB endpoint or ingress to fixed source
   IPs. Do not enable GKE `private_cluster_config` / `master_authorized_networks`, nor EKS private
   endpoints.
2. **Compensate at the application layer:**
   - TLS everywhere (`rediss://…:443` through the HAProxy ingress — already the case).
   - A strong, generated database password; never a default or blank one.
   - **Redis ACLs** granting the demo user only what the demo needs.
   - Drop `8001` (Redis Insight) and `9443` (internal operator/UI) from the *public* rule; keep
     `443` and the database endpoint range. Only expose ports a remote demo actually uses.
3. **Compensate with lifetime and blast radius:** the rig holds no real data, is disposable, and
   is tagged `owner`/`skip_deletion` so it is attributable and reapable (ADR 0006).
4. **Reliable teardown is a security control here**, not just cost hygiene — the strongest
   mitigation for a weeks-long public endpoint is that one command removes it completely. This
   makes `TODO.md` A3/A7 (GCP teardown is currently *broken*) security-relevant, not merely
   operational.

## Consequences

**Positive** — the demo works from anywhere with one command, which is the whole point; security
effort goes into controls that survive the requirement (auth, TLS, ACLs, short lifetime) rather
than ones that contradict it; the trade-off is explicit and reviewable instead of an unexamined
`0.0.0.0/0`.

**Negative / accepted risks**
- Redis Enterprise database endpoints are **internet-reachable for the life of the demo**. Password
  strength and ACLs are therefore load-bearing, not defence-in-depth.
- Exposed endpoints are discoverable by internet-wide scanners; expect background probing. Ensure
  nothing sensitive is ever loaded into a demo database.
- A leaked teardown (GCP currently cannot destroy — `TODO.md` A3) means a **public** endpoint left
  running, not merely a billing leak. Fixing teardown is the top mitigation.
- **`flask/app.py`'s `app.run(debug=True)` is incompatible with this ADR.** A publicly reachable
  Werkzeug debugger is remote code execution. Debug mode must be off by default
  (`TODO.md` B2) — this is the one place where "reachable from anywhere" makes an existing defect
  *more* severe, not less.
- Not suitable if a customer ever asks to run this against real or regulated data. At that point
  this ADR must be revisited, and private clusters + a VPN become the right answer.

## Follow-up

`TODO.md` **B1** (rewritten as *harden, do not close*), **B2** (Flask debug — now elevated),
**B5** (pin the operator), and **A3**/**A7** (teardown, now security-relevant).

**B4 was reversed on 2026-09-07**: step 05 prints the database password by default again.
Masking it followed the same generic-hardening instinct this ADR rejects — the operator needs
the credential in hand to run the demo, and the credential belongs to a throwaway cluster that
holds no real data. `--hide-secrets` exists for a shared screen. The logs land in `debug/`,
which is gitignored.
