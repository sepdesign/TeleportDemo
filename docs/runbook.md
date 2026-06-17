# Runbook

This runbook builds the project step by step. It is organized in phases.

## Before you start

Some files hold private or environment specific values. The repo ships them as .example templates. Copy each one to its real name and fill in your values. The real names are gitignored so they never get committed.

- cluster/kubeadm-config.yaml.example
- manifests/cluster-issuer-staging.yaml.example
- manifests/cluster-issuer-prod.yaml.example
- infra/terraform/terraform.tfvars.example

The copy command is shown at the step where each file is first used.

## Phase 0. Infrastructure with spin up and spin down

Goal. Stand up three EC2 nodes that are ready for kubeadm. Confirm you can stop and start them to control cost.

### 0.1 Install the tools

Install Terraform, the AWS CLI version 2 and kubectl. Confirm each one works.

```
terraform version
aws --version
kubectl version --client
```

Set up your AWS credentials.

```
aws configure
```

### 0.2 Set your variables

Find your public IP.

```
curl ifconfig.me
```

Copy the example variables file and edit it.

```
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
```

Set my_ip_cidr to your public IP followed by /32. Set the region if you do not want us-east-1.

### 0.3 Pick the Kubernetes version

Open infra/scripts/node-prep.sh. The K8S_MINOR value sets the package repo. The default is v1.35 which is current stable. Change it if you want another supported version. The list is at kubernetes.io/releases.

### 0.4 Build the infrastructure

```
terraform init
terraform plan
terraform apply
```

Terraform creates the network and the security group. It creates three nodes and two Elastic IPs. It also writes a private key file named teleport-key.pem in the terraform folder.

### 0.5 Read the outputs

```
terraform output
```

Note these values.

- control_plane_public_ip is the Elastic IP for the API server and for SSH.
- ingress_public_ip is the Elastic IP for worker 1. The DNS A record points here in a later phase.
- control_plane_private_ip and worker_private_ips are used by kubeadm in Phase 1.

### 0.6 Lock down the key file

SSH refuses to use a private key that other users can read. Restrict it to you.

```
chmod 400 infra/terraform/teleport-key.pem
```

### 0.7 Confirm the nodes are ready

First boot setup takes about three minutes. Then SSH into the control plane.

```
ssh -i infra/terraform/teleport-key.pem ubuntu@CONTROL_PLANE_PUBLIC_IP
```

Check that the prep script finished and the tools are present.

```
sudo tail -n 40 /var/log/cloud-init-output.log
which kubeadm kubelet kubectl
sudo systemctl is-active containerd
```

You want to see the line node-prep complete near the end of the log. You want kubeadm, kubelet and kubectl on the path. You want containerd active. Repeat for each worker if you want to confirm all three.

### 0.8 Spin down to save money

Run these from the repository root. Stop the nodes when you are done for the day.

```
bash scripts/cluster-stop.sh
```

Check the state.

```
bash scripts/cluster-status.sh
```

Start them again next time.

```
bash scripts/cluster-start.sh
```

If you changed the region, set AWS_REGION first so the scripts look in the right place.

```
export AWS_REGION=us-east-1
```

You can also stop and start by instance ID without the scripts.

```
aws ec2 stop-instances --instance-ids ID1 ID2 ID3
aws ec2 start-instances --instance-ids ID1 ID2 ID3
```

The cluster comes back on its own after a start. The two Elastic IPs stay the same so DNS and your kubeconfig keep working. The public IP of worker 2 does change on a stop and start.

### 0.9 Tear down when finished

When the whole project is done, destroy everything so billing stops.

```
cd infra/terraform
terraform destroy
```

That removes the nodes, the network and the Elastic IPs.

## Phase 1. Bootstrap the kubeadm cluster

Goal. Turn the three prepared nodes into a working cluster. We run kubeadm init on the control plane. We install Calico for pod networking. We join the two workers.

Note. The values CP_EIP, CP_PRIVATE and WORKER_IP below are placeholders. Replace each one with your real value from terraform output before you run the command.

### 1.1 Read your values

From the terraform folder, print the outputs.

```
terraform output
```

Note three things.

- control_plane_public_ip is the control plane Elastic IP. This guide calls it CP_EIP.
- control_plane_private_ip is the control plane private IP. This guide calls it CP_PRIVATE.
- worker_private_ips are the two worker private IPs.

### 1.2 Confirm first boot finished

SSH into the control plane.

```
chmod 400 infra/terraform/teleport-key.pem
ssh -i infra/terraform/teleport-key.pem ubuntu@CP_EIP
```

Check the prep script and the tools.

```
sudo tail -n 5 /var/log/cloud-init-output.log
which kubeadm kubelet kubectl
```

You want the line node-prep complete and all three tools on the path. If the log is still going, wait a minute and check again. Then log out with exit.

### 1.3 Fill in the cluster config

Copy the template to its real name. The real file is gitignored.

```
cp cluster/kubeadm-config.yaml.example cluster/kubeadm-config.yaml
```

The file has two placeholders. Replace them with your real values from step 1.1. Edit the file in an editor, or use sed.

```
sed -i "s/CONTROL_PLANE_PRIVATE_IP/CP_PRIVATE/" cluster/kubeadm-config.yaml
sed -i "s/CONTROL_PLANE_EIP/CP_EIP/" cluster/kubeadm-config.yaml
```

Copy the file to the control plane.

```
scp -i infra/terraform/teleport-key.pem cluster/kubeadm-config.yaml ubuntu@CP_EIP:~/
```

### 1.4 Initialize the control plane

SSH back into the control plane and run init.

```
sudo kubeadm init --config kubeadm-config.yaml
```

This runs for a couple of minutes. At the end it prints a kubeadm join command with a token and a hash. Copy that whole command and keep it. You run it on the workers in step 1.7.

### 1.5 Set up kubectl on the control plane

Still on the control plane.

```
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
kubectl get nodes
```

The control plane appears with status NotReady. That is expected because there is no pod network yet.

### 1.6 Install Calico

Still on the control plane.

```
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.5/manifests/calico.yaml
```

Give it about a minute. The control plane turns Ready and the CoreDNS pods start.

```
kubectl get nodes
kubectl get pods -n kube-system
```

### 1.7 Join the workers

Find each worker public IP from the AWS console or by running scripts/cluster-status.sh from your laptop. SSH into each worker and run the join command you saved in step 1.4. It needs sudo.

```
ssh -i infra/terraform/teleport-key.pem ubuntu@WORKER_IP
sudo kubeadm join CP_PRIVATE:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

The join talks to the control plane private IP, so the traffic stays inside the VPC.

### 1.8 Confirm the cluster

Back on the control plane.

```
kubectl get nodes -o wide
```

You want all three nodes with status Ready. The workers show the role <none>, which is normal.

### 1.9 Drive the cluster from your laptop

This step lets you run kubectl from WSL instead of SSH. On the control plane, make a readable copy.

```
sudo cp /etc/kubernetes/admin.conf /home/ubuntu/admin.conf
sudo chown ubuntu:ubuntu /home/ubuntu/admin.conf
```

From your laptop in the repo root, pull it down and point it at the Elastic IP.

```
scp -i infra/terraform/teleport-key.pem ubuntu@CP_EIP:/home/ubuntu/admin.conf ./kubeconfig
sed -i "s#server: https://[0-9.]*:6443#server: https://CP_EIP:6443#" kubeconfig
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes
```

This works because CP_EIP is listed in the API server certificate from the config in step 1.3. The kubeconfig file is already in .gitignore, so keep it there.

## Phase 2. Create the non admin user with RBAC

Goal. Make a user named dev that can deploy and watch the Nginx app in one namespace and nothing else. The user gets in with a client certificate from the CertificateSigningRequest flow. Run these from your laptop with the admin kubeconfig active.

Confirm the admin kubeconfig is the one in use first.

```
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes
```

### 2.1 Create the namespace and the access rules

```
kubectl apply -f manifests/rbac.yaml
```

This creates the web namespace, a Role called nginx-app-manager and a RoleBinding that ties the user dev to that Role. The Role lists only the verbs needed to deploy and watch the app. There is no access to secrets, to other namespaces or to anything cluster wide.

### 2.2 Mint the user identity

```
bash scripts/create-user.sh
```

The script makes a private key and sends a CSR to the cluster. It approves the CSR, reads back the signed certificate and writes a ready to use kubeconfig at user-dev/dev.kubeconfig. The whole user-dev folder is ignored by git.

### 2.3 Prove the access is limited

Use impersonation to check what dev can and cannot do. You stay as admin for this.

```
kubectl auth can-i create deployments --as=dev -n web
kubectl auth can-i get secrets --as=dev -n web
kubectl auth can-i get pods --as=dev -n kube-system
kubectl auth can-i --list --as=dev -n web
```

You want yes for the first one. You want no for the next two. The last command prints the full set of things dev is allowed, scoped to the web namespace.

### 2.4 Use the user kubeconfig for real

```
KUBECONFIG=user-dev/dev.kubeconfig kubectl get pods
KUBECONFIG=user-dev/dev.kubeconfig kubectl get nodes
```

The first works and shows the web namespace. The second is refused with a Forbidden error, because the Role grants nothing outside the namespace. That Forbidden is the authorization gate doing its job.

## Phase 3. cert-manager, ingress and a trusted certificate

Goal. Serve the site at a custom url (We will be using https://teleportdemotwo.cathlamettowing.com as I own it ) with a real certificate. The admin installs the platform. The dev user deploys the app.

Run these from the repo root. The admin kubeconfig is ./kubeconfig. The dev kubeconfig is ./user-dev/dev.kubeconfig.

Note about ingress-nginx. The project was archived in March 2026. It still runs on Kubernetes 1.35 and is fine for this build. The forward looking replacement is the Gateway API. This is a good point to raise in the demo.

### 3.0 Install Helm

If Helm is not installed yet, install it.

```
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

### 3.1 Point DNS at the ingress node

Get the ingress Elastic IP.

```
terraform -chdir=infra/terraform output ingress_public_ip
```

In your DNS provider for your custom url (I will be using cathlamettowing.com as I own it), create an A record for teleportdemotwo that points at that IP. Set a low TTL like 300 while you work. Confirm it resolves.

```
nslookup subdomain.url.com
ex: nslookup teleportdemotwo.cathlamettowing.com
```

You want the answer to be the ingress Elastic IP.

### 3.2 Label the ingress node

The ingress controller must run on worker 1, the node that holds the ingress Elastic IP. Find that node by its private IP from worker_private_ips, then label it.

```
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes -o wide
kubectl label node WORKER1_NODE_NAME ingress=true
```

Match the INTERNAL-IP column to the first worker private IP to find WORKER1_NODE_NAME.

### 3.3 Install ingress-nginx

```
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --version 4.14.3 \
  --namespace ingress-nginx --create-namespace \
  -f cluster/ingress-nginx-values.yaml
```

Wait for the controller and confirm it landed on worker 1.

```
kubectl get pods -n ingress-nginx -o wide
```

Confirm it answers on port 80 from the internet. A 404 from nginx is the right answer here. It means the controller is listening but has no route yet.

```
curl http://teleportdemotwo.cathlamettowing.com
```

### 3.4 Install cert-manager

```
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.19.5/cert-manager.yaml
kubectl get pods -n cert-manager
```

Wait until all three cert-manager pods are Running before moving on.

### 3.5 Create the Let's Encrypt issuers

Copy the templates to their real names first. The real files are gitignored.

```
cp manifests/cluster-issuer-staging.yaml.example manifests/cluster-issuer-staging.yaml
cp manifests/cluster-issuer-prod.yaml.example manifests/cluster-issuer-prod.yaml
```

Set your email in both files. Then apply them. Issuers are cluster wide, so only the admin can create them.

```
sed -i "s/your-email@example.com/YOU@EXAMPLE.COM/" manifests/cluster-issuer-staging.yaml manifests/cluster-issuer-prod.yaml
kubectl apply -f manifests/cluster-issuer-staging.yaml
kubectl apply -f manifests/cluster-issuer-prod.yaml
kubectl get clusterissuer
```

You want both issuers to show READY True.

### 3.6 Deploy the app as the dev user

Switch to the dev kubeconfig. The dev user creates the app objects in the web namespace. It never touches secrets or issuers.

```
export KUBECONFIG=$PWD/user-dev/dev.kubeconfig
kubectl apply -f manifests/app/configmap.yaml
kubectl apply -f manifests/app/deployment.yaml
kubectl apply -f manifests/app/service.yaml
kubectl apply -f manifests/app/ingress.yaml
kubectl get pods
```

The Ingress starts on the staging issuer from the annotation in the file.

### 3.7 Watch the staging certificate issue

cert-manager sees the Ingress and requests a certificate. Watch it with the admin kubeconfig.

```
export KUBECONFIG=$PWD/kubeconfig
kubectl get certificate -n web
kubectl describe certificate nginx-tls -n web
```

Within a minute the certificate shows Ready True. If it is slow, follow the chain.

```
kubectl get order,challenge -n web
```

The site now answers over HTTPS. The browser warns because staging is not trusted. That warning is expected and proves the flow works.

### 3.8 Switch to the production issuer

Edit the Ingress annotation to the prod issuer, then re-apply as the dev user.

```
export KUBECONFIG=$PWD/user-dev/dev.kubeconfig
sed -i "s/letsencrypt-staging/letsencrypt-prod/" manifests/app/ingress.yaml
kubectl apply -f manifests/app/ingress.yaml
```

cert-manager notices the issuer changed and requests a new certificate. Watch it with the admin kubeconfig.

```
export KUBECONFIG=$PWD/kubeconfig
kubectl describe certificate nginx-tls -n web
```

If it does not refresh on its own, the admin can delete the old secret to force a clean reissue.

```
kubectl delete secret nginx-tls -n web
```

### 3.9 Confirm the trusted site

Open https://teleportdemotwo.cathlamettowing.com in a browser. You want a green padlock and the page served from the cluster. This is the moment for the demo.

## Phase 4. GitOps with Argo CD

Goal. Put the app under Git control. Argo CD watches the repo and keeps the cluster in sync with it. This also gets the repo onto GitHub, which is the deliverable.

### 4.0 Put the repo on GitHub

Initialize git and make the first commit.

```
cd /mnt/c/dev/teleport
git init -b main
git add .
git commit -m "kubeadm cluster, certificate based RBAC, cert-manager, ingress"
```

The .gitignore already keeps your keys, kubeconfigs and filled in configs out of the commit. Run git status first if you want to be sure.

Install the GitHub CLI, then create the repo and push in one step.

```
sudo mkdir -p -m 755 /etc/apt/keyrings
wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt update && sudo apt install gh -y
gh auth login
gh repo create teleport --public --source=. --remote=origin --push
```

Use a public repo for this demo. Argo CD then reads it with no credentials, and the repo holds no secrets. A private repo would need repo credentials added to Argo CD.

### 4.1 Install Argo CD

Use the admin kubeconfig.

```
export KUBECONFIG=$PWD/kubeconfig
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.3/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server
```

### 4.2 Reach the Argo CD UI

Get the first time admin password.

```
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

Forward the UI to your laptop.

```
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Open https://localhost:8080 and log in as admin with that password. The browser warns about the Argo self signed cert. That is fine for the console.

### 4.3 Point Argo CD at your repo

Set repoURL in manifests/argocd/application.yaml to your GitHub repo. Then apply it with the admin kubeconfig.

```
kubectl apply -f manifests/argocd/application.yaml
kubectl -n argocd get application nginx-site
```

Argo CD finds the manifests under manifests/app, adopts the running resources and reports Synced and Healthy. The site keeps serving the whole time.

### 4.4 See GitOps work

Change the app in Git and watch the cluster follow. Bump the replicas in manifests/app/deployment.yaml from 2 to 3.

```
sed -i "s/replicas: 2/replicas: 3/" manifests/app/deployment.yaml
git commit -am "scale nginx to 3"
git push
```

Within a minute Argo CD syncs and a third pod appears.

```
export KUBECONFIG=$PWD/kubeconfig
kubectl get pods -n web -w
```

Now show self heal. As admin, scale the Deployment by hand and watch Argo CD put it back.

```
kubectl scale deployment nginx -n web --replicas=5
```

Argo CD sees the drift from Git and returns it to 3. Direct changes do not stick anymore. The way to change the cluster is now a Git commit.

## Next

The build is complete. What remains is to review the design document, then break the cluster on purpose to practice the live troubleshooting round.
