# Teleport Take Home

A kubeadm Kubernetes cluster on AWS that serves a static Nginx site over HTTPS. A non admin user deploys and manages the app through certificate based access control. TLS is issued by cert-manager and Let's Encrypt. Argo CD provides a GitOps path for the same app.

## What gets built

- Three EC2 nodes. One control plane and two workers.
- A kubeadm cluster with the Calico network plugin.
- A namespace plus a Role and a RoleBinding that give one user least privilege access.
- A user identity created through the Kubernetes CertificateSigningRequest flow.
- cert-manager with a Let's Encrypt issuer for a trusted certificate.
- ingress-nginx on host network ports 80 and 443.
- Argo CD syncing the Nginx app from this repository.

## Repository layout

```
infra/terraform   AWS network, security group, three nodes, Elastic IPs
infra/scripts     node-prep.sh that prepares each node at first boot
scripts           start, stop and status helpers for the nodes
manifests         Kubernetes YAML added in later phases
docs              runbook and design notes
```

## Prerequisites

- An AWS account with credentials set up for the AWS CLI.
- Terraform 1.5 or newer.
- The AWS CLI version 2.
- An SSH client and kubectl on your machine.
- A DNS A record you control. This build uses teleportdemotwo.cathlamettowing.com.

## Cost and lifecycle

Three small nodes cost a few cents per hour while running. Stop them when idle and you pay only for storage and the two Elastic IPs. The helpers in the scripts folder stop and start the nodes. The cluster survives a stop and start because the disks and private IPs persist. Run terraform destroy when the project is finished.

On the AWS free tier the micro instances have 1 GB of memory, which is below what the kubeadm control plane needs. The control plane runs on a small paid instance instead. Keeping each root volume at 10 GB fits the 30 GB EBS free tier. Stopping the nodes when idle keeps the total to a few dollars. The full cost notes are in docs/design.md.

## Build phases

0. Infrastructure with spin up and spin down. See docs/runbook.md.
1. Bootstrap the kubeadm cluster.
2. Create the non admin user and the access control.
3. Install cert-manager, ingress-nginx and the Let's Encrypt issuer.
4. Deploy the Nginx app as the user.
5. Add Argo CD and manage the app from Git.
6. Break the cluster on purpose and practice troubleshooting.

Start with docs/runbook.md.
