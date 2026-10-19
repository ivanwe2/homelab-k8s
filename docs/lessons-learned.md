# Lessons learned

Real problems I hit while building this cluster. Each one: what I saw, why it happened, how I fixed it, and what stops it happening again.

---

## 1. Certificates "from the future" took the API server down

**Date:** 2026-10-17 · **Area:** k3s, PKI, time

**Symptom.** After booting the server from a Windows session, every `kubectl` command from my laptop failed with `ServiceUnavailable`. The k3s log was full of `x509: certificate has expired or is not yet valid: current time 21:40 is before 23:21`. `systemctl status k3s` reported the service as started "2h 41min **left**" instead of "ago".

**Root cause.** The machine dual-boots Windows. Windows keeps the hardware clock in *local* time (UTC+3); Linux and Proxmox read it as *UTC*. So the host and its auto-started VMs booted three hours in the future. k3s issued fresh kubelet certificates at that wrong time. Minutes later NTP corrected the clock, and those certificates were no longer valid yet ("not before" was in the future).

**Fix.** A restart wasn't enough: k3s only renews certificates that are expired or close to expiring on startup, and a not-yet-valid certificate is neither. The fix was stopping k3s, running `k3s certificate rotate` to issue new leaf certificates with the correct time, starting it again, restarting the agents, and re-copying the admin kubeconfig, which had been rotated too.

**Prevention.**
- A systemd drop-in makes Proxmox wait for `chronyc waitsync` before auto-starting VMs.
- Windows now stores the hardware clock in UTC (`RealTimeIsUniversal`).

**What I learned.** Clocks are infrastructure. TLS, tokens and node heartbeats all assume the time is right, and a wrong clock produces confusing, indirect symptoms. Reading the exact timestamps in the error, rather than the error type, is what cracked it.

---

## 2. One invalid manifest blocked every sync of an app

**Date:** 2026-10-17 · **Area:** Argo CD

**Symptom.** After a commit with a typo (`apiVersion: v2` on a ConfigMap), the app stayed `OutOfSync` with the sync stuck in `Running`: `one or more synchronization tasks are not valid`. A follow-up commit fixing the typo wasn't picked up either.

**Root cause.** Before applying anything, Argo CD resolves every manifest to an API type. There's no core API version `v2`, so the whole sync plan was invalid and nothing was applied (validation is all-or-nothing). Argo CD also runs **one sync operation at a time per application**, and the broken one kept retrying, so the fix commit couldn't start.

**Fix.** Terminated the running operation in the UI; the next automated sync picked up the fixed commit.

**Prevention.**
- `syncPolicy.retry.refresh: true`: while a sync is retrying, Argo CD now checks Git for newer commits and switches to them.
- Every change is validated with `kubectl apply --dry-run=server` before it's pushed.

**What I learned.** Self-heal repairs drift in the *cluster*. It can't fix a broken *commit*, because the commit is what it's healing towards.

---

## 3. "Sync OK", yet permanently out of sync

**Date:** 2026-10-17 · **Area:** Argo CD, Kubernetes API

**Symptom.** After adding a retry policy to an Application, every sync of the parent app reported success, but its status stayed `OutOfSync`, and the retry settings never appeared on the live object.

**Root cause.** The `retry` block was indented one level too deep (under `automated:`). The Application type has a schema, and the API server silently drops fields it doesn't recognise at that position. So the apply succeeded, the stored object lacked the field, Git still had it, and the two never matched.

**Fix.** Moved `retry` to its correct place (a sibling of `automated`) and confirmed with the Application's diff view in Argo CD.

**Prevention.** `kubectl apply --dry-run=server` rejects unknown fields (`unknown field "spec.syncPolicy.automated.retry"`), so it catches this before the push. The dry run now covers every changed file, including the Application definitions in `apps/`, not only the app manifests.

**What I learned.** "The last apply succeeded" and "the cluster matches Git" are different questions. When they disagree, the cluster stored something other than what was sent.

---

## 4. A change that never happened

**Date:** 2026-10-17 · **Area:** Argo CD

**Symptom.** I deleted a Service in Git, then reverted the deletion, and Argo CD never showed the Service being removed.

**Root cause.** Argo CD polls Git every 2 to 3 minutes and syncs to the **newest commit it sees**, not to every commit in between. Both pushes landed within one polling interval, so Argo CD went straight from "Service exists" to "Service exists".

**Prevention.** One change, one push, one manual refresh, then observe. Argo CD's sync history shows exactly which commits were ever applied.

---

## 5. An Application Argo CD couldn't see

**Date:** 2026-10-19 · **Area:** Argo CD

**Symptom.** A new Application file was committed and the parent `root` app was `Synced`, but the new app never appeared in Argo CD.

**Root cause.** An Application manifest has two `namespace` fields. `metadata.namespace` is where the Application object itself is stored, and Argo CD only watches its own namespace. `spec.destination.namespace` is where the app's resources go. I changed the first one instead of the second, so the object was created somewhere Argo CD doesn't look.

**Fix.** Corrected the file. The stray copy then hung in `Terminating`, because its finalizer is only ever removed by Argo CD, which wasn't watching that namespace. I removed the finalizer by hand.

**What I learned.** A finalizer is a promise that some controller will clean up before deletion completes. If no controller is watching, the deletion waits forever. That's the usual reason for resources (and whole namespaces) stuck in `Terminating`.

---

## Smaller tooling gotchas

- **Windows PowerShell 5.1 writes files as UTF-16** when you use `>`. kubectl and kubeseal expect UTF-8, so I use PowerShell 7 for anything that writes YAML or certificates.
- **A PATH change doesn't reach terminals that are already open,** including new tabs of an already-running VS Code or Windows Terminal. Reloading `$env:Path` in the current shell avoids restarting everything.
- **Changing an Argo CD Helm install** (bootstrapped by hand) means `helm upgrade` with the *same* chart version, so a config change doesn't silently become an Argo CD upgrade too.