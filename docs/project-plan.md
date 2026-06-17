# Teleport Take-Home — Project Plan & Working Notes

> Living document for the Teleport SE/TAM take-home. Captures the exercise, the
> decisions made, the architecture, the teaching/build roadmap with status, and
> the talking points for the 15-minute demo + live troubleshooting round.
> Source requirements: `docs/exercise-source.txt`.

---

## 1. The Exercise (requirements)

**Minimum (required to submit):**
- kubeadm cluster — **1 control plane + 2 workers**, standard Kubernetes (NOT Minikube/Kind)
- Static **Nginx** site deployed by a **non-admin user** (role-based access), in its own namespace
- RBAC access granted via the native Kubernetes **CertificateSigningRequest (CSR)** flow
- **cert-manager** issues the site's TLS (Transport Layer Security) cert
- All deployment files in a **GitHub repo, shared 24h before the interview**
- **Design doc** (approaches + tradeoffs) + install/user-mgmt/deploy **runbook**; reproducible in a clean environment

**Optional level-up:** GitOps (Argo CD / Flux / Helm)

**Interview format:** 15-min live demo + **3 escalating live troubleshooting scenarios**. Graded on think-out-loud communication, customer focus, and practical K8s knowledge.

---

## 2. Key Decisions

| Area | Decision |
|---|---|
| Cloud | AWS EC2, 3 instances, one VPC/subnet; **spin up/down** to control cost |
| Sizing | control plane ≥ 2 vCPU / 2 GB (t3.medium); workers t3.small/medium |
| Domain | A-record **`teleportdemotwo.cathlamettowing.com`** → ingress node's **Elastic IP** |
| Ingress exposure | **hostNetwork** on ports 80/443; controller pinned (nodeSelector) to the **worker** holding the Elastic IP |
| TLS | **cert-manager + Let's Encrypt (ACME HTTP-01)**; issue via **staging** first, then flip to **prod** for a trusted padlock |
| Security group | 80/443 from `0.0.0.0/0`; 22 + 6443 from **my IP only**; all traffic within the cluster SG |
| CNI | Calico (pod CIDR `192.168.0.0/16`) |
| Runtime | containerd, **systemd** cgroup driver |
| Access model | non-admin user `dev` (CN=dev, O=web-team) via native CSR; namespaced least-privilege Role in namespace `web` |

---

## 3. Architecture

```
                        DNS A-record: teleportdemotwo.cathlamettowing.com
                                              │  → Elastic IP
                                              ▼
client ──HTTPS──►  [ ingress-nginx controller ]  ◄── hostNetwork 80/443, pinned to worker-1
   (trusted             │  terminates TLS (cert from Secret, issued by cert-manager)
    LE cert)            │  routes by host/path (Ingress rule, ingressClassName=nginx)
                        ▼
                 [ Service: nginx-svc (ClusterIP) ]
                        │  selector → pod labels
                        ▼
                 [ nginx Deployment pods ]  ◄── static HTML from a ConfigMap

Cluster: kubeadm | control-plane (apiserver, etcd, scheduler, controller-mgr, CA)
                 | worker-1 (ingress + app) | worker-2 (app)
                 | CNI: Calico | runtime: containerd
```

---

## 4. Roadmap & Status

**Teaching (concepts first, then build):**
1. kubeadm cluster anatomy — ✅ DONE
2. cert auth model + CSR flow — ✅ DONE
3. RBAC least-privilege design — ✅ DONE
4. cert-manager + ingress + Nginx TLS — ✅ DONE (issuer = Let's Encrypt)
5. AWS infra & lifecycle — ✅ DONE
6. demo narrative — ✅ DONE
7. live troubleshooting methodology + failure catalog — ✅ DONE
8. (optional) GitOps — not started
9. Live mock troubleshooting drills — recommended before building

**Build phases:**
- **Phase 0** — provision 3 EC2 nodes (scripted/reproducible) + security group + Elastic IP + DNS A-record
- **Phase 1** — kubeadm cluster (prep, `init`, Calico, `join`, verify Ready)
- **Phase 2** — non-admin user via CSR; namespace + Role + RoleBinding
- **Phase 3** — install cert-manager + ingress-nginx (hostNetwork); deploy Nginx **as the dev user**; Let's Encrypt staging → prod
- **Phase 4** — deliverables (design doc, runbook), clean-environment test, push to GitHub
- **Phase 5 (optional)** — GitOps (Argo CD)

---

## 5. Key Technical Talking Points

### Identity & authentication
- Kubernetes has **no user objects**; the API server trusts **any client cert signed by the cluster CA**. Cert **CN → username**, **O → group(s)**.
- The cluster CA (`/etc/kubernetes/pki/ca.{crt,key}`) is the **root of trust**. `admin.conf` = a cert in the `system:masters` (god) group; that's the "default admin" we must NOT deploy as.
- **401 Unauthorized = authentication failed** (cert bad/expired/unknown CA). **403 Forbidden = authenticated but RBAC denied.** Read which one FIRST when triaging access issues.
- **Native CSR flow:** `genrsa` → `openssl req` (CN/O) → `CertificateSigningRequest` (signerName `kubernetes.io/kube-apiserver-client`, usages `[client auth]`, `expirationSeconds`) → `kubectl certificate approve` → extract `status.certificate` → build kubeconfig. The **CA private key never leaves the control plane** (vs. naive local openssl signing).
- **No revocation:** Kubernetes has no CRL/OCSP for client certs. A signed cert is valid until expiry. "Revoke" = delete the RBAC binding (removes permissions, NOT authentication) or rotate the CA (nuclear). → the headline weakness, and the core Teleport pitch.

### RBAC
- **Additive only** (no deny rules). A namespaced **Role** keeps blast radius to one namespace by construction.
- Decompose "deploy / access / monitor" → verbs. **apiGroups matter:** core = `""`; deployments = `apps`; ingresses = `networking.k8s.io`. **Subresources** (`pods/log`, `pods/portforward`, `pods/exec`) are SEPARATE grants. "Access" is ambiguous — ask; default to read + port-forward, omit `exec`.
- **Prove least privilege** with `kubectl auth can-i <verb> <resource> --as=dev -n web` (and `--list`).

### App layer
- **Two "nginx"es:** the ingress-nginx **controller** (edge proxy, terminates TLS) vs. the Nginx **app** (workload). Don't conflate them.
- Static content via a **ConfigMap** mounted at `/usr/share/nginx/html` (declarative, in-repo).
- cert-manager: **Issuer/ClusterIssuer → Certificate → Secret** (type `tls`). **ingress-shim:** annotate the Ingress (`cert-manager.io/cluster-issuer`) and the Certificate is auto-created → the dev user needs **no cert-manager permissions**.
- **Bare-metal LB gotcha:** on kubeadm (no cloud controller) a `type=LoadBalancer` Service stays `<pending>` forever. We use **hostNetwork** (80/443) instead. (MetalLB is the production bare-metal answer.)
- **Let's Encrypt:** test on the **staging** issuer (loose rate limits, untrusted cert) to prove the HTTP-01 flow, then flip the Ingress annotation to the **prod** issuer for a trusted padlock.

### Teleport tie-in (the demo win)
Built access "the hard way"; each pain maps to a Teleport capability:

| Pain (hand-rolled certs) | Teleport answer |
|---|---|
| No cert revocation (no CRL/OCSP) | Short-lived certs tied to a live SSO session |
| Manual kubeconfig distribution | `tsh login` mints creds on demand; keys never emailed |
| No SSO / identity / MFA | RBAC mapped to live IdP groups + MFA enforced |
| Weak audit | Identity-correlated audit + session recording |
| Doesn't scale across clusters | One identity, many clusters, central RBAC |
| No just-in-time access | Access Requests / JIT approval workflows |

**Land line:** *"Teleport doesn't replace Kubernetes RBAC — it governs access to it."*

---

## 6. Troubleshooting (Module 7)

**Methodology (any scenario):** 1) Scope — ask what/when/changed/blast-radius. 2) Locate the layer + hypothesize. 3) Observe before touching: `get → describe (read Events!) → logs → events`. 4) Bisect the path (site down: client→DNS→ingress→service→endpoints→pod→container). 5) Confirm, change ONE thing, re-test. 6) Explain to the customer: what/why/fix/prevention.

**Four-command reflex:** `kubectl get pods -A -o wide` · `kubectl describe <obj>` (Events at bottom) · `kubectl logs <pod> -p -c <ctr>` · `kubectl get events --sort-by=.lastTimestamp`. Specialists: `get nodes`, `get endpoints <svc>`, `auth can-i <verb> <res> --as=<user> -n <ns>`.

**Comms overlay (interviewer runs commands):** be directive ("please run X and read the Events"), state hypothesis BEFORE each command, narrate what you rule OUT, give confidence levels.

**Catalog by layer:**

| Layer | Symptom | Likely cause → move |
|---|---|---|
| Node | `NotReady` | CNI not installed; kubelet down; cgroup mismatch → `describe node`, `journalctl -u kubelet` |
| Node | Pod `Pending` | no CNI / resources / taint / nodeSelector → `describe pod` (FailedScheduling) |
| Pod | `ImagePullBackOff` | wrong image/tag; registry auth; no egress → `describe pod` Events |
| Pod | `CrashLoopBackOff` | app exits; bad config; missing mount → `logs -p` |
| Pod | `CreateContainerConfigError` | missing ConfigMap/Secret → `describe pod` |
| Pod | `OOMKilled` / not Ready | memory limit low / readiness probe failing → `describe pod` |
| Net | Service unreachable | **endpoints empty** = selector≠labels or pods not Ready → `get endpoints` |
| Net | in-cluster DNS fails | CoreDNS down (CNI) → debug pod `nslookup` |
| Net | cross-node pod traffic | SG intra-cluster rule / CNI encap port → check self-ref SG |
| Ingress | 404 | host/path/`ingressClassName`; controller down → `describe ingress` |
| Ingress | 502/503 | backend endpoints unhealthy → `get endpoints`, controller logs |
| Ingress | no address | kubeadm `LoadBalancer` pending (no cloud LB) / hostNetwork port conflict |
| TLS | cert not `Ready` | HTTP-01: port 80 closed, A-record not on EIP, wrong solver class, prod rate limit, issuer not Ready → walk `certificate→certificaterequest→order→challenge` |
| TLS | browser untrusted | still on **staging** issuer → flip to prod |
| Auth | `401 Unauthorized` | cert expired / wrong CA / wrong cluster / clock skew → check `notAfter`, CA |
| Auth | `403 Forbidden` | missing verb/resource/**apiGroup**; wrong ns; CN/O mismatch; subresource (`pods/log`) not granted → `auth can-i --as=` |
| AWS | `kubectl` hangs | 6443 not open to your IP; public IP changed (no EIP); instance stopped |
| AWS | stale after restart | public IP moved → use EIP/DNS in kubeconfig |
| AWS | LE can't validate | port 80 closed to 0.0.0.0/0; A-record not on EIP |

**3-scenario shape (escalating, ~5 min each):** (1) warm-up = one pod (ImagePull/CrashLoop); (2) medium = endpoints-empty or RBAC 403; (3) complex = cross-layer "site down" (ingress 502 / cert not issued / node NotReady) — use the path-walk. Don't rabbit-hole; referencing docs is fine.

---

## 7. Working Preferences
- Teach concepts deeply **before** commands. Pitch HIGH (solid on K8s; new to kubeadm + cert-based RBAC).
- **Spell out every acronym on first use.**
- Always connect technical points back to Teleport's value prop.
- User works in **WSL bash**, repo at `/mnt/c/dev/teleport`. Give bash commands, never PowerShell. AWS creds bridged from Windows via `~/.bashrc` env vars (`AWS_SHARED_CREDENTIALS_FILE=/mnt/c/Users/sepde/.aws/credentials`, `AWS_CONFIG_FILE=/mnt/c/Users/sepde/.aws/config`, `AWS_REGION=us-east-1`).
- AWS account **962926952736**, IAM user `claude-cli`, region **us-east-1** (all build defaults set to us-east-1).
- Deliverable docs in plain human voice: no em dashes, max 2 commas per sentence, no AI tells. project-plan.md itself stays as internal study notes.
