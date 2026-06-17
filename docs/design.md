# Design Document

This document covers the design of the cluster, the access model, and the main tradeoffs. Read it alongside the runbook, which has the step by step instructions.

## What this builds

A three node Kubernetes cluster on AWS that serves a static Nginx site over HTTPS. A non admin user deploys and runs the site through a certificate based identity that is limited to one namespace. cert-manager and Let's Encrypt handle TLS. Argo CD adds an optional GitOps path.

## Components

- Three EC2 nodes built with kubeadm. One control plane and two workers.
- Calico for pod networking.
- A namespace called web with a least privilege Role and a RoleBinding.
- A user named dev whose access comes from a client certificate signed through the Kubernetes CertificateSigningRequest flow.
- ingress-nginx on host network ports 80 and 443, pinned to the worker that holds a static IP.
- cert-manager with a Let's Encrypt issuer.
- Argo CD watching this repository.

## Request path

```
        DNS teleportdemotwo.cathlamettowing.com -> ingress Elastic IP # I utilized this url as I already owned it. I wanted to show using "hostNetwork" instead of "NodePort"
                                  |
 client --HTTPS--> ingress-nginx (host network 80/443 on worker 1)
                                  |  terminates TLS, routes by host
                                  v
                       Service nginx (ClusterIP)
                                  |
                       nginx pods (static HTML from a ConfigMap)

 cluster: control plane (apiserver, etcd, CA) + worker 1 + worker 2
 TLS cert issued by cert-manager from Let's Encrypt
 app reconciled from Git by Argo CD
```

## Design decisions and tradeoffs

### Cluster on kubeadm and AWS EC2
The exercise asks for kubeadm and standard Kubernetes, so the cluster is built that way on real Linux nodes. EC2 matches how a customer would run it. The tradeoff is cost. The control plane needs at least 2 GB of memory and 2 CPUs, which is more than the AWS free tier instances provide. The cost section covers how this is kept small.

### Calico for networking
kubeadm does not install a pod network, so one has to be added. Calico is a common choice that works well with kubeadm and has clear docs. Any CNI would do. Calico was picked for familiarity.

### Access through a signed certificate and a scoped Role
The dev user creates a private key and a certificate request. The cluster signs it through the CertificateSigningRequest API. The CN on the certificate becomes the username and the O becomes the group. A Role in the web namespace then grants only the verbs needed to deploy and watch the app. Nothing outside that namespace is reachable. This is the approach the exercise asks for. Its weak points are listed under pluses and minuses.

### Ingress on host network rather than a load balancer
On plain EC2 there is no cloud controller, so a Service of type LoadBalancer never gets an address. The ingress controller runs on host network and binds ports 80 and 443 on one worker. A static Elastic IP and a DNS record point at that worker. The tradeoff is that the controller is tied to one node. A production setup would use a real load balancer or a bare metal option such as MetalLB.

### TLS with cert-manager and Let's Encrypt
A public domain and an open port 80 let the Let's Encrypt HTTP-01 challenge work, which returns a real trusted certificate. The flow runs against the staging issuer first to avoid the production rate limits. It then switches to the production issuer. A self signed issuer would skip the domain step but would show a browser warning. The trusted certificate was worth the small extra work.

### GitOps with Argo CD
Argo CD is the optional objective. It watches the repo and keeps the cluster matching it. This changes the operating model. A direct kubectl change gets reverted, and the way to change the cluster becomes a commit. Access then depends on who can merge and who can reach Argo CD.

### Secrets and the repository
Real values stay out of the repo. Keys and kubeconfigs are ignored. The filled cluster config and the issuer files that carry an email are ignored too. The repo ships .example templates with placeholders. An operator copies each template to its real name and fills it in. This is a deliberate answer to the proof of concept question about secrets. The repo holds sanitized templates instead of real secret data.

## Pluses and minuses of this access model

Pluses:
- A strong identity based on a key pair with no shared password.
- No outside dependency. The cluster signs its own certificates.
- The namespaced Role limits the user to one namespace by design.
- The access can be proven in one command with kubectl auth can-i.

Minuses:
- A certificate cannot be revoked. Kubernetes has no revocation list for client certificates. Once signed, a certificate works until it expires. Removing the RoleBinding takes away permissions, but the certificate still proves who you are.
- The kubeconfig is built and handed out by hand, so key material moves around.
- The identity is not linked to a company login. There is no single sign on and no second factor. Group membership is set when the certificate is signed.
- The audit trail is thin. Nothing ties an action to a real person and there is no session recording.
- It does not scale across clusters. Each cluster has its own signing authority.

These minuses are the reason teams adopt an identity aware access platform. Short lived certificates tied to a login remove the revocation problem, because access ends when the session ends. The same layer adds single sign on, an audit trail tied to a person, and access granted just in time. Teleport is one such platform, and this certificate based model is the baseline it improves on.

## Cost and free tier

This build uses small paid instances. The control plane needs at least 2 GB of memory and 2 CPUs, so it runs on a t3.small or t3.medium. The AWS free tier only covers t2.micro and t3.micro at 1 GB of memory, which is below what the control plane needs. A pure free tier control plane is not possible.

Where the free tier still helps:
- The workers can run on a free tier t3.micro if the workload stays light. A t3.small is safer.
- The EBS free tier covers 30 GB. Setting each root volume to 10 GB keeps all three nodes inside it.
- Stopping the nodes when idle means you pay for compute only while you work.

What still costs money:
- A public IPv4 address bills at about half a cent per hour now, including Elastic IPs, even on the free tier.
- The control plane is paid instance time at a few cents per hour.

Small instances and a stop when idle habit keep the whole exercise to a few dollars. A fully free option would be local virtual machines or a provider with a larger always free tier.

## What I would change for production

- Replace hand issued certificates with short lived credentials from an identity aware proxy.
- Use a real load balancer or MetalLB for the ingress.
- Bring cert-manager, ingress, and the issuers under GitOps as well.
- Add etcd backups and a second control plane for resilience.


