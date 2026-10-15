#!/bin/bash
# Bootstrap for the StreamingApp Jenkins / build server
# Ubuntu 24.04 LTS, ap-southeast-2. Runs once at first boot as EC2 user data.
# Log: /var/log/jenkins-bootstrap.log
set -euxo pipefail
exec > >(tee -a /var/log/jenkins-bootstrap.log) 2>&1

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg unzip git fontconfig openjdk-21-jre

# 2 GB swap as a safety net for React builds on smaller instances
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# ---------- Docker Engine (official repo) ----------
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list

# ---------- Jenkins LTS (2026 signing key) ----------
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key -o /etc/apt/keyrings/jenkins-keyring.asc
echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
  > /etc/apt/sources.list.d/jenkins.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin jenkins

# Jenkins and the ubuntu user can run docker without sudo
usermod -aG docker jenkins
usermod -aG docker ubuntu
systemctl enable --now docker
systemctl restart jenkins

# ---------- AWS CLI v2 ----------
cd /tmp
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip && ./aws/install --update && rm -rf aws awscliv2.zip

# ---------- kubectl, Helm, eksctl (used in the EKS steps) ----------
KVER=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

curl -fsSL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C /usr/local/bin

echo "BOOTSTRAP COMPLETE"
