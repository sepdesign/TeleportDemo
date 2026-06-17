#!/bin/bash
# Runs once at first boot through EC2 user data. Prepares an Ubuntu 22.04 node for kubeadm.
# Logs go to /var/log/cloud-init-output.log on the node.
# Set the Kubernetes minor version below. Current stable is listed at kubernetes.io/releases.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

K8S_MINOR="v1.35"

# 1. Turn off swap. The kubelet expects swap to be off.
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# 2. Kernel modules for the container network.
cat <<EOF >/etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# 3. Sysctl so bridged traffic is seen by iptables and forwarding is on.
cat <<EOF >/etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# 4. Container runtime. Install containerd and set the systemd cgroup driver.
apt-get update
apt-get install -y containerd apt-transport-https ca-certificates curl gpg
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# 5. Kubernetes packages from pkgs.k8s.io.
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" >/etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet

echo "node-prep complete"
