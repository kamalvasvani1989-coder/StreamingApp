# StreamingApp on AWS EKS: Orchestration and Scaling

A MERN video-streaming application (StreamFlix) containerised as five microservices, built by Jenkins into Amazon ECR, deployed to Amazon EKS with Helm, monitored with CloudWatch Container Insights, and wired to SNS for alerting and build notifications.

**Live app:** https://streamapp.kamalvasvani.com
**Repository:** https://github.com/kamalvasvani1989-coder/StreamingApp (fork of `UnpredictablePrashant/StreamingApp`)
**Region:** `ap-southeast-2` (Sydney) &nbsp;|&nbsp; **AWS account:** `926375049914`

---

## Contents

1. [Architecture](#architecture)
2. [What is in this repository](#what-is-in-this-repository)
3. [Step-by-step build](#step-by-step-build)
4. [Application validation](#application-validation)
5. [Monitoring and alerting (CloudWatch + SNS)](#monitoring-and-alerting-cloudwatch--sns)
6. [CI/CD: automated deploy and notifications](#cicd-automated-deploy-and-notifications)
7. [Security and least privilege](#security-and-least-privilege)
8. [Operations incident: Jenkins outage](#operations-incident-jenkins-outage)
9. [Design decisions](#design-decisions)
10. [Cost and teardown](#cost-and-teardown)

---

## Architecture

```mermaid
flowchart LR
  dev["Developer laptop"] -- "git push" --> gh["GitHub fork"]
  gh -- "webhook" --> jenkins["Jenkins on EC2<br/>(instance role)"]
  jenkins -- "docker push<br/>tag = commit SHA" --> ecr["Amazon ECR<br/>5 repositories"]
  jenkins -- "helm upgrade --atomic" --> eks
  jenkins -- "sns publish" --> sns["SNS topic<br/>streamingapp-alerts"]

  user["Browser"] -- "HTTPS" --> cf["Cloudflare<br/>DNS + TLS"]
  cf -- "HTTP" --> alb["Application Load Balancer<br/>(AWS LB Controller)"]

  subgraph eks["EKS cluster streamingapp-eks (k8s 1.34, 2 nodes)"]
    direction TB
    fe["frontend x2<br/>nginx :8080"]
    auth["auth x2"]
    stream["streaming x2"]
    admin["admin x1"]
    chat["chat x1<br/>Socket.IO"]
    cwa["CloudWatch agent +<br/>Fluent Bit (per node)"]
  end

  alb -- "/" --> fe
  alb -- "/api" --> auth
  alb -- "/api/streaming" --> stream
  alb -- "/api/admin" --> admin
  alb -- "/api/chat, /socket.io<br/>(sticky)" --> chat

  auth & stream & admin & chat --> atlas[("MongoDB Atlas<br/>Sydney")]
  admin -- "PutObject<br/>(Pod Identity)" --> s3[("S3 bucket<br/>private")]
  stream -- "GetObject, range<br/>(Pod Identity)" --> s3
  ecr -. "image pull" .-> eks
  cwa --> cw["CloudWatch<br/>metrics, logs, alarms"]
  cw --> sns
  sns --> mail["Email"]
```

Static version for viewers that don't render Mermaid: [`docs/architecture.png`](docs/architecture.png)

**Request paths**

| Path | Service | Notes |
|---|---|---|
| `/` | frontend | React SPA on `nginx-unprivileged` (:8080) with SPA fallback and `/healthz` |
| `/api` | auth | Register, login, JWT issuance |
| `/api/streaming` | streaming | Video catalogue; proxies playback from S3 with HTTP range requests (206) |
| `/api/admin` | admin | Video management; receives multipart uploads and writes them to S3 |
| `/api/chat`, `/socket.io` | chat | Live chat per video over WebSocket; ALB stickiness; history in MongoDB |

**Scaling:** HPAs (CPU 70%) on auth, streaming, frontend and admin. Chat is pinned to one replica because Socket.IO rooms are held in memory; scaling it out would need the Redis adapter.

---

## What is in this repository

| Path | Purpose |
|---|---|
| `backend/*/Dockerfile`, `frontend/Dockerfile` | Node 22 multi-stage builds, non-root (uid 1000), per-service build context |
| `frontend/nginx.conf` | SPA fallback and `/healthz` |
| `Jenkinsfile` | CI/CD: build, push, Helm deploy, smoke test, SNS notification |
| `helm/streamingapp/` | Helm chart: Deployments, Services, HPAs, Ingress (ALB), ServiceAccount |
| `infra/eks-cluster.yaml` | eksctl cluster config (no NAT, public nodes, Pod Identity) |
| `infra/jenkins-userdata.sh` | EC2 bootstrap for the Jenkins/build host |
| `infra/ecr-lifecycle-policy.json` | Keep the last 10 images per repository |
| `infra/s3-cors.json` | S3 CORS rules |
| `infra/cloudwatch-setup.sh` | Container Insights add-on, log retention, SNS topic, alarms (idempotent) |
| `infra/jenkins-role-policy.json` | Least-privilege inline policy for the Jenkins role |
| `infra/needrestart-jenkins.conf` | Stops unattended upgrades from restarting Jenkins |
| `docs/screenshots/` | Evidence for every step below |

Secrets (`MONGO_URI`, `JWT_SECRET`) are never in Git. `.gitignore` excludes `*.pem`, `*.ppk`, `*accessKeys*.csv` and `*.env`; `.gitattributes` forces LF line endings.

---

## Step-by-step build

> Commands below are abridged to the essentials. Values such as the account ID, bucket and cluster names match this deployment.

### 1. Fork and remotes

```bash
git clone https://github.com/kamalvasvani1989-coder/StreamingApp.git
cd StreamingApp
git remote add upstream https://github.com/UnpredictablePrashant/StreamingApp.git
git remote set-url --push upstream DISABLED      # never push to the original repo
```

<details>
<summary>Screenshots (3)</summary>

**Fork under kamalvasvani1989-coder**

![Fork under kamalvasvani1989-coder](docs/screenshots/01-fork/01-fork-on-github.png)

**origin = fork, upstream = original repo**

![origin = fork, upstream = original repo](docs/screenshots/01-fork/02-git-remotes.png)

**Upstream fetch/merge; upstream push URL set to DISABLED**

![Upstream fetch/merge; upstream push URL set to DISABLED](docs/screenshots/01-fork/03-upstream-sync-push-disabled.png)

</details>


### 2. Dockerfiles

Each service got a multi-stage Node 22 Dockerfile running as a non-root user, a `.dockerignore`, and the frontend is served by `nginx-unprivileged` on port 8080 with an SPA fallback and a `/healthz` endpoint (commit `f1ab8fd`).

<details>
<summary>Screenshots (2)</summary>

**Rewritten Dockerfiles, .dockerignore, nginx.conf, .gitattributes**

![Rewritten Dockerfiles, .dockerignore, nginx.conf, .gitattributes](docs/screenshots/02-dockerfiles/01-dockerfiles-staged.png)

**Commit f1ab8fd pushed**

![Commit f1ab8fd pushed](docs/screenshots/02-dockerfiles/02-dockerfiles-commit-push.png)

</details>


### 3. AWS CLI

A CLI profile `streamingapp` on the laptop for one-time setup work.

```bash
aws configure --profile streamingapp     # region ap-southeast-2
aws sts get-caller-identity --profile streamingapp
```

<details>
<summary>Screenshots (3)</summary>

**IAM user kamal-admin**

![IAM user kamal-admin](docs/screenshots/03-aws-cli/01-iam-user-review.png)

**IAM user created**

![IAM user created](docs/screenshots/03-aws-cli/02-iam-user-created.png)

**CLI profile streamingapp in ap-southeast-2**

![CLI profile streamingapp in ap-southeast-2](docs/screenshots/03-aws-cli/03-cli-caller-identity.png)

</details>


### 4. Amazon ECR

```bash
for s in auth streaming admin chat frontend; do
  aws ecr create-repository --repository-name streamingapp/$s \
    --image-scanning-configuration scanOnPush=true --encryption-configuration encryptionType=AES256
  aws ecr put-lifecycle-policy --repository-name streamingapp/$s \
    --lifecycle-policy-text file://infra/ecr-lifecycle-policy.json
done
```

<details>
<summary>Screenshots (3)</summary>

**5 repos, scan-on-push, AES256**

![5 repos, scan-on-push, AES256](docs/screenshots/04-ecr/01-create-ecr-repos.png)

**Lifecycle policy: keep last 10 images**

![Lifecycle policy: keep last 10 images](docs/screenshots/04-ecr/02-lifecycle-policy.png)

**Repository URIs**

![Repository URIs](docs/screenshots/04-ecr/03-ecr-repos-table.png)

</details>


### 5. Jenkins / build server on EC2

Ubuntu 24.04 on `m7i-flex.large` with the instance role `streamingapp-jenkins-role` (no access keys on the box), IMDSv2 required, bootstrapped by `infra/jenkins-userdata.sh` with Docker, AWS CLI, kubectl, Helm and eksctl.

<details>
<summary>Screenshots (6)</summary>

**Instance role streamingapp-jenkins-role**

![Instance role streamingapp-jenkins-role](docs/screenshots/05-jenkins-ec2/01-iam-role-review.png)

**Role created**

![Role created](docs/screenshots/05-jenkins-ec2/02-iam-role-created.png)

**Trust policy for ec2.amazonaws.com**

![Trust policy for ec2.amazonaws.com](docs/screenshots/05-jenkins-ec2/03-iam-role-trust-policy.png)

**m7i-flex.large, role attached, IMDSv2 required**

![m7i-flex.large, role attached, IMDSv2 required](docs/screenshots/05-jenkins-ec2/04-ec2-instance-summary.png)

**SSH into Ubuntu 24.04**

![SSH into Ubuntu 24.04](docs/screenshots/05-jenkins-ec2/05-ssh-login.png)

**User data: Docker, AWS CLI, kubectl, Helm, eksctl**

![User data: Docker, AWS CLI, kubectl, Helm, eksctl](docs/screenshots/05-jenkins-ec2/06-bootstrap-verified.png)

</details>


### 6. Manual build and push (sanity check before CI)

```bash
TAG=$(git rev-parse --short HEAD)
REG=926375049914.dkr.ecr.ap-southeast-2.amazonaws.com
aws ecr get-login-password --region ap-southeast-2 | docker login --username AWS --password-stdin $REG
docker build --provenance=false -t $REG/streamingapp/auth:$TAG backend/authService
docker push $REG/streamingapp/auth:$TAG      # repeated for each service
```

Checks: containers run as uid 1000, frontend `/healthz` returns 200, SPA routes return 200, and the streaming image contains no sample `.mp4` files.

<details>
<summary>Screenshots (5)</summary>

**Clone on EC2, tag = commit SHA**

![Clone on EC2, tag = commit SHA](docs/screenshots/06-manual-build-push/01-clone-and-tag.png)

**docker login to ECR via instance role**

![docker login to ECR via instance role](docs/screenshots/06-manual-build-push/02-ecr-login.png)

**5 images; uid 1000; frontend /healthz and SPA route OK**

![5 images; uid 1000; frontend /healthz and SPA route OK](docs/screenshots/06-manual-build-push/03-images-and-sanity-checks.png)

**Images in ECR tagged SHA + latest**

![Images in ECR tagged SHA + latest](docs/screenshots/06-manual-build-push/04-ecr-images.png)

**Streaming image has no bundled .mp4 files**

![Streaming image has no bundled .mp4 files](docs/screenshots/06-manual-build-push/05-no-video-in-image.png)

</details>


### 7. Jenkins setup

Elastic IP `3.104.137.60`, suggested plugins plus the GitHub plugins, Jenkins URL set to the Elastic IP.

<details>
<summary>Screenshots (6)</summary>

**Elastic IP 3.104.137.60**

![Elastic IP 3.104.137.60](docs/screenshots/07-jenkins-setup/01-elastic-ip.png)

**Setup wizard**

![Setup wizard](docs/screenshots/07-jenkins-setup/02-install-suggested-plugins.png)

**Suggested plugins installing**

![Suggested plugins installing](docs/screenshots/07-jenkins-setup/03-plugins-installing.png)

**Jenkins URL**

![Jenkins URL](docs/screenshots/07-jenkins-setup/04-jenkins-url.png)

**Dashboard**

![Dashboard](docs/screenshots/07-jenkins-setup/05-jenkins-dashboard.png)

**GitHub plugins**

![GitHub plugins](docs/screenshots/07-jenkins-setup/06-github-plugins-installed.png)

</details>


### 8. CI pipeline and webhook

Job `streamingapp-ci`: *Pipeline script from SCM*, branch `*/main`, script path `Jenkinsfile`, trigger *GitHub hook trigger for GITScm polling*. GitHub webhook: `http://3.104.137.60:8080/github-webhook/`.

The initial pipeline: Checkout → Prepare (account ID, registry, short SHA) → ECR Login → five parallel `docker build` + `push` (tags: SHA and `latest`) → prune and logout. The deploy stages were added later (see [CI/CD](#cicd-automated-deploy-and-notifications)).

<details>
<summary>Screenshots (10)</summary>

**GitHub project + hook trigger**

![GitHub project + hook trigger](docs/screenshots/08-ci-pipeline/01-job-general-and-trigger.png)

**Pipeline script from SCM, */main**

![Pipeline script from SCM, */main](docs/screenshots/08-ci-pipeline/02-job-scm.png)

**Script path Jenkinsfile**

![Script path Jenkinsfile](docs/screenshots/08-ci-pipeline/03-job-script-path.png)

**Commit 33f2be9**

![Commit 33f2be9](docs/screenshots/08-ci-pipeline/04-jenkinsfile-commit-push.png)

**Build #2 success**

![Build #2 success](docs/screenshots/08-ci-pipeline/05-build2-success.png)

**Stages incl. 5 parallel builds**

![Stages incl. 5 parallel builds](docs/screenshots/08-ci-pipeline/06-build2-stages.png)

**Webhook to /github-webhook/**

![Webhook to /github-webhook/](docs/screenshots/08-ci-pipeline/07-github-webhook-config.png)

**Ping delivered, HTTP 200**

![Ping delivered, HTTP 200](docs/screenshots/08-ci-pipeline/08-webhook-ping-200.png)

**Test commit 02a4ab0**

![Test commit 02a4ab0](docs/screenshots/08-ci-pipeline/09-trigger-test-commit.png)

**Build #3 started by GitHub push**

![Build #3 started by GitHub push](docs/screenshots/08-ci-pipeline/10-build3-started-by-github-push.png)

</details>


### 9. Data layer

- **MongoDB Atlas:** free cluster in Sydney, dedicated database user `streamingapp`, database `streamingapp`. The access list includes `0.0.0.0/0` because the EKS nodes use public IPs without a NAT gateway; see [Design decisions](#design-decisions).
- **S3:** `streamingapp-videos-926375049914`, all Block Public Access settings on, CORS from `infra/s3-cors.json`.

<details>
<summary>Screenshots (5)</summary>

**MongoDB Atlas free cluster, Sydney**

![MongoDB Atlas free cluster, Sydney](docs/screenshots/09-data-layer/01-atlas-cluster.png)

**IP access list**

![IP access list](docs/screenshots/09-data-layer/02-atlas-network-access.png)

**Dedicated DB user**

![Dedicated DB user](docs/screenshots/09-data-layer/03-atlas-db-user.png)

**S3 bucket, Block Public Access on**

![S3 bucket, Block Public Access on](docs/screenshots/09-data-layer/04-s3-bucket-private.png)

**S3 CORS**

![S3 CORS](docs/screenshots/09-data-layer/05-s3-cors.png)

</details>


### 10. Helm chart

`helm/streamingapp` renders 17 resources: five Deployments and Services, four HPAs, the ALB Ingress and the `streamingapp-s3` ServiceAccount (commit `c000d0f`).

```bash
helm lint helm/streamingapp
helm template streamingapp helm/streamingapp | grep '^kind:' | sort | uniq -c
```

<details>
<summary>Screenshots (3)</summary>

**Chart structure**

![Chart structure](docs/screenshots/10-helm-chart/01-chart-files.png)

**Commit c000d0f**

![Commit c000d0f](docs/screenshots/10-helm-chart/02-chart-commit-push.png)

**helm lint passes; 17 resources**

![helm lint passes; 17 resources](docs/screenshots/10-helm-chart/03-helm-lint-template.png)

</details>


### 11. EKS cluster

```bash
eksctl create cluster -f infra/eks-cluster.yaml
```

`infra/eks-cluster.yaml` creates Kubernetes 1.34 across three AZs with **no NAT gateway** (nodes in public subnets), a managed nodegroup of 2× `m7i-flex.large` (min 2, max 3), the add-ons `vpc-cni`, `coredns`, `kube-proxy`, `eks-pod-identity-agent` and `metrics-server`, and two **EKS Pod Identity** associations:

- `kube-system/aws-load-balancer-controller` → the well-known Load Balancer Controller policy
- `streamingapp/streamingapp-s3` → `s3:GetObject`, `PutObject`, `DeleteObject` and `ListBucket` on the video bucket **only**

AdministratorAccess was attached to the Jenkins role **temporarily** for this step and removed later (see [least privilege](#security-and-least-privilege)).

<details>
<summary>Screenshots (6)</summary>

**Temporary admin on instance role for eksctl**

![Temporary admin on instance role for eksctl](docs/screenshots/11-eks-cluster/01-role-temp-admin.png)

**eksctl create cluster (k8s 1.34, 3 AZs)**

![eksctl create cluster (k8s 1.34, 3 AZs)](docs/screenshots/11-eks-cluster/02-eksctl-create-start.png)

**infra/eks-cluster.yaml**

![infra/eks-cluster.yaml](docs/screenshots/11-eks-cluster/03-cluster-config-yaml.png)

**Control plane + add-ons**

![Control plane + add-ons](docs/screenshots/11-eks-cluster/04-eksctl-progress.png)

**Cluster ready**

![Cluster ready](docs/screenshots/11-eks-cluster/05-cluster-ready.png)

**2 nodes Ready, 5 add-ons, 2 Pod Identity associations**

![2 nodes Ready, 5 add-ons, 2 Pod Identity associations](docs/screenshots/11-eks-cluster/06-nodes-addons-pod-identity.png)

</details>


### 12. Deploy the application

```bash
# AWS Load Balancer Controller (service account created by eksctl with Pod Identity)
helm repo add eks https://aws.github.io/eks-charts && helm repo update
VPC_ID=$(aws eks describe-cluster --name streamingapp-eks --query cluster.resourcesVpcConfig.vpcId --output text)
helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --set clusterName=streamingapp-eks --set region=ap-southeast-2 --set vpcId=$VPC_ID \
  --set serviceAccount.create=false --set serviceAccount.name=aws-load-balancer-controller

# Secrets typed in, never echoed or committed
kubectl create namespace streamingapp
read -s MONGO_URI; read -s JWT_SECRET
kubectl -n streamingapp create secret generic streamingapp-secrets \
  --from-literal=MONGO_URI="$MONGO_URI" --from-literal=JWT_SECRET="$JWT_SECRET"

# Application
helm upgrade --install streamingapp helm/streamingapp -n streamingapp --set image.tag=c000d0f
kubectl -n streamingapp get pods,hpa,ingress
```

The controller install needed `--disable-openapi-validation` once, because the brand-new API server briefly returned an OpenAPI 503. Result: 8 pods Running, 4 HPAs reading live CPU, and the ALB `streamingapp-alb-2035881929.ap-southeast-2.elb.amazonaws.com` routing every path correctly.

<details>
<summary>Screenshots (6)</summary>

**AWS Load Balancer Controller via Helm**

![AWS Load Balancer Controller via Helm](docs/screenshots/12-deploy/01-lb-controller-install.png)

**Controller 2/2 ready**

![Controller 2/2 ready](docs/screenshots/12-deploy/02-lb-controller-ready.png)

**Secret streamingapp-secrets (keys only)**

![Secret streamingapp-secrets (keys only)](docs/screenshots/12-deploy/03-k8s-secret.png)

**helm upgrade --install, 8 pods Running**

![helm upgrade --install, 8 pods Running](docs/screenshots/12-deploy/04-helm-deploy-pods-running.png)

**ALB address + 4 HPAs**

![ALB address + 4 HPAs](docs/screenshots/12-deploy/05-ingress-and-hpa.png)

**Path routing through ALB**

![Path routing through ALB](docs/screenshots/12-deploy/06-alb-route-tests.png)

</details>


### 13. DNS and TLS

Cloudflare CNAME `streamapp.kamalvasvani.com` → ALB, proxied. Cloudflare terminates HTTPS for the browser. Registration and login work, and the test user was promoted to `admin` in Atlas.

<details>
<summary>Screenshots (5)</summary>

**CNAME streamapp to ALB, proxied**

![CNAME streamapp to ALB, proxied](docs/screenshots/13-validation/01-cloudflare-dns.png)

**Cloudflare SSL mode**

![Cloudflare SSL mode](docs/screenshots/13-validation/02-cloudflare-ssl-flexible.png)

**Home page**

![Home page](docs/screenshots/13-validation/03-app-home-page.png)

**Registered + logged in**

![Registered + logged in](docs/screenshots/13-validation/04-app-logged-in-browse.png)

**User role set to admin in Atlas**

![User role set to admin in Atlas](docs/screenshots/13-validation/05-atlas-user-role-admin.png)

</details>


---

## Application validation

End-to-end tests through `https://streamapp.kamalvasvani.com`, with browser DevTools and pod logs open.

| Test | Result |
|---|---|
| Admin role | After re-login the new JWT carries `role: admin` and the **Admin Studio** link appears |
| Upload | Browser POSTs multipart to `/api/admin/videos/upload/thumbnail` and `/upload/video`; adminService writes both to S3 using **Pod Identity**; `POST /api/admin/videos` → 201; status `ready` |
| Storage | `aws s3 ls` shows `videos/…-streamflix-test.mp4` (3.5 MiB) and `thumbnails/…jpg` |
| Playback | Thumbnail 200; video served as several **206 Partial Content** chunks; seeking works |
| Chat (single user) | WebSocket upgrade **101** through Cloudflare + ALB; `chat:join` → history; `chat:message` saved to MongoDB (has `_id`) and acknowledged |
| Chat (two users) | A normal user in a second session sees the history and sends a message, which appears **instantly** in the admin session without refresh |
| Keep-alive | Engine.IO ping/pong stays healthy for minutes, with no idle disconnects at the ALB |

> Upload design note: files go **through** adminService rather than straight from the browser to S3 with presigned URLs. Uploads therefore pass through Cloudflare (100 MB request limit on the free plan), the ALB and the pod; S3 CORS is not involved in uploads.

<details>
<summary>Screenshots (11)</summary>

**Admin Studio link after re-login (role in new JWT)**

![Admin Studio link after re-login (role in new JWT)](docs/screenshots/14-app-tests/01-admin-studio-link.png)

**Admin panel, Manage Videos**

![Admin panel, Manage Videos](docs/screenshots/14-app-tests/02-admin-panel.png)

**Upload form**

![Upload form](docs/screenshots/14-app-tests/03-upload-form.png)

**Upload: thumbnail + video POSTs, record 201, status ready**

![Upload: thumbnail + video POSTs, record 201, status ready](docs/screenshots/14-app-tests/04-upload-success-network.png)

**adminService logs for the upload**

![adminService logs for the upload](docs/screenshots/14-app-tests/05-admin-pod-logs.png)

**Objects written to private S3 bucket via Pod Identity**

![Objects written to private S3 bucket via Pod Identity](docs/screenshots/14-app-tests/06-s3-objects.png)

**Thumbnail served on Browse**

![Thumbnail served on Browse](docs/screenshots/14-app-tests/07-browse-thumbnail.png)

**Playback: 206 Partial Content range requests, WebSocket 101**

![Playback: 206 Partial Content range requests, WebSocket 101](docs/screenshots/14-app-tests/08-playback-206.png)

**Chat: join, history, message, ack frames**

![Chat: join, history, message, ack frames](docs/screenshots/14-app-tests/09-chat-websocket-frames.png)

**Second user (normal role): history from Atlas, playback, send**

![Second user (normal role): history from Atlas, playback, send](docs/screenshots/14-app-tests/10-chat-second-user.png)

**Message delivered in real time to the admin session**

![Message delivered in real time to the admin session](docs/screenshots/14-app-tests/11-chat-realtime-admin.png)

</details>


The eksctl config was then committed from the laptop (`bffd002`). The Jenkins host deliberately has **no GitHub credentials**.

<details>
<summary>Screenshots (3)</summary>

**infra/eks-cluster.yaml contents**

![infra/eks-cluster.yaml contents](docs/screenshots/15-repo-sync/01-eks-cluster-yaml.png)

**Committed from laptop (bffd002); no Git credentials on Jenkins host**

![Committed from laptop (bffd002); no Git credentials on Jenkins host](docs/screenshots/15-repo-sync/02-eks-yaml-commit-push.png)

**EC2 clone synced**

![EC2 clone synced](docs/screenshots/15-repo-sync/03-ec2-sync.png)

</details>


---

## Monitoring and alerting (CloudWatch + SNS)

Everything in this section is scripted in **`infra/cloudwatch-setup.sh`**.

**Container Insights:** the `amazon-cloudwatch-observability` add-on (v6.7.0) deploys a CloudWatch agent (metrics) and Fluent Bit (logs) on every node. Both use the node role, which already has `CloudWatchAgentServerPolicy` (`cloudWatch: true` in the nodegroup).

`eksctl create addon` failed: its OIDC pre-check (`iam:GetOpenIDConnectProvider`) is blocked by an **explicit deny in an AWS Organizations SCP** on this account. Creating the add-on through the EKS API (`aws eks create-addon`) avoids that check and works. The same SCP is why the cluster uses **Pod Identity rather than IRSA**.

**Logs:** four log groups under `/aws/containerinsights/streamingapp-eks/` (`application`, `dataplane`, `host`, `performance`) with **7-day retention**. Every application log line carries Kubernetes metadata, including the exact ECR image and digest, so a log line can be traced to the build that produced it.

**Alarms** (all notify `streamingapp-alerts` on ALARM **and** OK):

| Alarm | Metric | Condition |
|---|---|---|
| `streamingapp-node-cpu-high` | `node_cpu_utilization` | avg > 80% for 10 min |
| `streamingapp-node-failed` | `cluster_failed_node_count` | > 0 for 3 min |
| `streamingapp-pods-below-min` | `namespace_number_of_running_pods` | < 8 (sum of HPA minimums) for 3 min; missing data = breaching |
| `streamingapp-restarts-<svc>` ×5 | `pod_number_of_container_restarts` | > 3 |
| `streamingapp-alb-5xx` | ALB `HTTPCode_Target_5XX_Count` | > 5 in 5 min |

**Verification:** `aws cloudwatch set-alarm-state` forced `streamingapp-node-failed` into ALARM. The email arrived within seconds, and the alarm returned to OK on the next real evaluation, which sent a second email.

<details>
<summary>Screenshots (11)</summary>

**eksctl blocked by Organization SCP (OIDC)**

![eksctl blocked by Organization SCP (OIDC)](docs/screenshots/17-cloudwatch/01-eksctl-scp-deny.png)

**Add-on ACTIVE; agent + Fluent Bit per node**

![Add-on ACTIVE; agent + Fluent Bit per node](docs/screenshots/17-cloudwatch/02-addon-active-pods.png)

**Log groups created (one-off startup races only)**

![Log groups created (one-off startup races only)](docs/screenshots/17-cloudwatch/03-log-groups-created.png)

**App logs with Kubernetes metadata; 7-day retention**

![App logs with Kubernetes metadata; 7-day retention](docs/screenshots/17-cloudwatch/04-app-logs-retention.png)

**Container Insights metrics; SNS topic**

![Container Insights metrics; SNS topic](docs/screenshots/17-cloudwatch/05-metrics-sns-topic.png)

**Alarm dimensions verified**

![Alarm dimensions verified](docs/screenshots/17-cloudwatch/06-alarm-dimensions.png)

**9 alarms OK**

![9 alarms OK](docs/screenshots/17-cloudwatch/07-alarms-ok.png)

**Subscription confirmed; test alarm**

![Subscription confirmed; test alarm](docs/screenshots/17-cloudwatch/08-sns-confirmed-test-alarm.png)

**Alert emails received**

![Alert emails received](docs/screenshots/17-cloudwatch/09-gmail-alert-list.png)

**ALARM email**

![ALARM email](docs/screenshots/17-cloudwatch/10-email-alarm.png)

**OK email**

![OK email](docs/screenshots/17-cloudwatch/11-email-ok.png)

</details>


---

## CI/CD: automated deploy and notifications

The final `Jenkinsfile` runs on every push:

```
Checkout → Prepare → ECR Login → Build & Push (5 parallel) → Deploy to EKS → Smoke Test → Post: SNS email
```

- **Deploy to EKS:** `helm upgrade streamingapp helm/streamingapp --set image.tag=<SHA> --atomic --timeout 5m`. The release was installed with only `image.tag` overridden, so chart defaults come from Git and every deploy is reproducible. `--atomic` waits for all rollouts and **rolls back automatically** on failure.
- **Smoke Test:** `/healthz` and `/api/streaming/videos` must return 200 through Cloudflare and the ALB.
- **Notifications (bonus ChatOps):** success, failure or skip is published to SNS. The email includes the job, commit SHA and message, duration, build link and app link.
- **`[skip ci]`** in a commit message skips build and deploy, used for documentation commits.

Build #6 (commit `3192a57`) ran the whole path in **1 min 9 s**. Helm moved to revision 2, all five Deployments rolled to `:3192a57` with zero restarts, and the success email arrived.

<details>
<summary>Screenshots (7)</summary>

**jenkins user can reach the cluster**

![jenkins user can reach the cluster](docs/screenshots/18-cicd-deploy/01-jenkins-user-cluster-access.png)

**Release values: only image.tag**

![Release values: only image.tag](docs/screenshots/18-cicd-deploy/02-helm-values.png)

**Jenkinsfile with Deploy, Smoke Test, SNS (3192a57)**

![Jenkinsfile with Deploy, Smoke Test, SNS (3192a57)](docs/screenshots/18-cicd-deploy/03-jenkinsfile-commit-push.png)

**Build #6: all stages green**

![Build #6: all stages green](docs/screenshots/18-cicd-deploy/04-build6-stages.png)

**helm upgrade revision 2; all images on 3192a57**

![helm upgrade revision 2; all images on 3192a57](docs/screenshots/18-cicd-deploy/05-deploy-stage-log.png)

**Pods replaced by rolling update**

![Pods replaced by rolling update](docs/screenshots/18-cicd-deploy/06-pods-after-rollout.png)

**Build success email**

![Build success email](docs/screenshots/18-cicd-deploy/07-sns-build-email.png)

</details>


---

## Security and least privilege

**Jenkins role, final permissions:**

| Need | Permission |
|---|---|
| Push images | `AmazonEC2ContainerRegistryPowerUser` (managed) |
| `aws eks update-kubeconfig` | `eks:DescribeCluster` on `streamingapp-eks` only |
| Build notifications | `sns:Publish` on `streamingapp-alerts` only |
| kubectl / Helm | No IAM permission. Kubernetes RBAC comes from the EKS access entry the role received as cluster creator |

`infra/jenkins-role-policy.json` was added as an inline policy, **then** AdministratorAccess was detached, so access never dropped. Verification: `iam:ListUsers` → AccessDenied, while `eks describe-cluster` and `kubectl get nodes` still work. Build #7 re-ran the full pipeline successfully under the restricted role.

**Other controls**

- No AWS keys on the build host; instance role only, with IMDSv2 required.
- App pods reach S3 through a Pod Identity role scoped to one bucket. The bucket is private, with all Block Public Access settings on.
- Containers run as non-root (uid 1000); the frontend uses `nginx-unprivileged`.
- Secrets live only in a Kubernetes Secret created with `read -s`; nothing in Git or in Helm values.
- ECR scan-on-push and a lifecycle policy; unattended security upgrades stay enabled on the host.
- Upstream remote push disabled; no Git credentials on the Jenkins host.

**Known trade-offs (lab scope)**

- **Cloudflare SSL "Flexible":** browser↔Cloudflare is HTTPS, Cloudflare↔ALB is HTTP. Production would use an ACM certificate on the ALB with Cloudflare **Full (strict)**.
- **Atlas `0.0.0.0/0`:** needed because nodes have changing public IPs and there is no NAT. Production would use private subnets + NAT (a fixed egress IP) or Atlas PrivateLink.
- **Jenkins on HTTP :8080** with a public Elastic IP. Production would put it behind TLS and restrict the security group to GitHub's webhook ranges and admin IPs.
- **Laptop IAM user with AdministratorAccess** for setup. Production would use IAM Identity Center with short-lived credentials.

<details>
<summary>Screenshots (4)</summary>

**IAM denied; EKS and kubectl still work**

![IAM denied; EKS and kubectl still work](docs/screenshots/19-least-privilege/01-admin-removed-verify.png)

**Role: ECR PowerUser + scoped inline policy**

![Role: ECR PowerUser + scoped inline policy](docs/screenshots/19-least-privilege/02-role-permissions-console.png)

**Build #7 green under least privilege**

![Build #7 green under least privilege](docs/screenshots/19-least-privilege/03-build7-green.png)

**Build #7 email**

![Build #7 email](docs/screenshots/19-least-privilege/04-build7-email.png)

</details>


---

## Operations incident: Jenkins outage

**Symptom:** after pushing `bffd002`, Jenkins refused connections on :8080 and the GitHub webhook delivery failed ("failed to connect to host").

**Diagnosis**

- `systemctl status jenkins`: `failed (Result: start-limit-hit)`, exit `143` (SIGTERM), a clean shutdown after only 57 s of uptime. Not a crash, and memory was healthy (6.8 GiB available).
- `/var/log/apt/history.log` and the journal: **unattended-upgrades** patched `libssl3t64`/`openssl`, `zlib1g`, `libfreetype6` and others at 06:38–06:39 UTC. After each library upgrade, **needrestart** restarted the services using it. Jenkins was restarted repeatedly, exceeded systemd's start limit, and stayed down.

**Fix**

```bash
sudo systemctl reset-failed jenkins && sudo systemctl start jenkins
sudo cp infra/needrestart-jenkins.conf /etc/needrestart/conf.d/90-jenkins.conf
sudo perl -c /etc/needrestart/conf.d/90-jenkins.conf      # syntax OK
```

Security updates stay enabled; Jenkins is now restarted only deliberately. The failed webhook delivery was **redelivered** from GitHub (HTTP 200), which triggered build #5 for `bffd002`. That build took about 3 s because no application code changed and every Docker layer was cached.

<details>
<summary>Screenshots (9)</summary>

**Jenkins unreachable**

![Jenkins unreachable](docs/screenshots/16-jenkins-incident/01-connection-refused.png)

**SIGTERM then start-limit-hit**

![SIGTERM then start-limit-hit](docs/screenshots/16-jenkins-incident/02-start-limit-hit.png)

**Root cause: unattended-upgrades**

![Root cause: unattended-upgrades](docs/screenshots/16-jenkins-incident/03-unattended-upgrades.png)

**Service restarts in journal; Jenkins back on 8080**

![Service restarts in journal; Jenkins back on 8080](docs/screenshots/16-jenkins-incident/04-journal-and-recovered.png)

**needrestart exclusion for jenkins.service**

![needrestart exclusion for jenkins.service](docs/screenshots/16-jenkins-incident/05-needrestart-exclusion.png)

**Webhook failed while Jenkins was down**

![Webhook failed while Jenkins was down](docs/screenshots/16-jenkins-incident/06-webhook-failed-delivery.png)

**Redelivered, HTTP 200**

![Redelivered, HTTP 200](docs/screenshots/16-jenkins-incident/07-webhook-redeliver-200.png)

**Build #4 (c000d0f)**

![Build #4 (c000d0f)](docs/screenshots/16-jenkins-incident/08-build4-c000d0f.png)

**Build #5 from redelivery**

![Build #5 from redelivery](docs/screenshots/16-jenkins-incident/09-build5-bffd002.png)

</details>


---

## Design decisions

| Decision | Why |
|---|---|
| **EKS Pod Identity** instead of IRSA | IRSA needs an IAM OIDC provider, and `iam:GetOpenIDConnectProvider` is denied by an Organizations SCP on this account. Pod Identity needs no OIDC and is simpler to manage. |
| **No NAT gateway**, nodes in public subnets | Saves about US$1/day on a lab cluster. Nodes are still protected by security groups; the trade-off is Atlas `0.0.0.0/0`. |
| **Chat fixed at 1 replica + ALB stickiness** | Socket.IO rooms are in memory. Horizontal scaling would need the Socket.IO Redis adapter (for example ElastiCache). |
| **HPAs** on auth, streaming, frontend, admin | CPU target 70%, backed by metrics-server. |
| **Images tagged with the commit SHA** (+ `latest`) | Every deployment maps to an exact commit; `latest` is never deployed. |
| **`helm upgrade --atomic`** in CI | A failed rollout rolls back automatically instead of leaving the site half-deployed. |
| **Helm values = chart defaults + `image.tag`** | The cluster state can be reproduced from Git alone. |
| **`--provenance=false`** on builds | Avoids the extra attestation manifests that clutter ECR listings. |
| **CloudWatch add-on via EKS API** | Bypasses eksctl's OIDC pre-check that the SCP blocks. |

---

## Cost and teardown

While running, the stack costs roughly **US$12–15/day**: EKS control plane, 3× `m7i-flex.large` (2 nodes + Jenkins), the ALB, public IPv4 addresses and CloudWatch. Jenkins can be stopped once no more builds are needed; the app does not depend on it.

**Teardown (after grading).** These steps need broader permissions than the Jenkins role has, so run them from an admin profile or re-attach AdministratorAccess temporarily.

```bash
R=ap-southeast-2
# 1. App first, so the Load Balancer Controller deletes the ALB
helm uninstall streamingapp -n streamingapp
aws elbv2 describe-load-balancers --region $R --query 'LoadBalancers[].LoadBalancerName'   # wait until gone

# 2. Cluster (nodegroup, add-ons, Pod Identity roles, VPC)
eksctl delete cluster -f infra/eks-cluster.yaml --wait
#    If eksctl hits the same SCP/OIDC deny, delete the eksctl-streamingapp-eks-* CloudFormation
#    stacks in the console (nodegroup and pod identity stacks first, cluster stack last).

# 3. Monitoring and alerting
aws cloudwatch delete-alarms --region $R --alarm-names $(aws cloudwatch describe-alarms --region $R \
  --alarm-name-prefix streamingapp- --query 'MetricAlarms[].AlarmName' --output text)
for g in application dataplane host performance; do
  aws logs delete-log-group --region $R --log-group-name /aws/containerinsights/streamingapp-eks/$g
done
aws sns delete-topic --region $R --topic-arn arn:aws:sns:ap-southeast-2:926375049914:streamingapp-alerts

# 4. Images and video storage
for s in auth streaming admin chat frontend; do
  aws ecr delete-repository --region $R --repository-name streamingapp/$s --force
done
aws s3 rm s3://streamingapp-videos-926375049914 --recursive
aws s3 rb s3://streamingapp-videos-926375049914

# 5. Jenkins host (terminate the instance, then release the Elastic IP)
#    EC2 console: terminate "streamingapp-jenkins", release 3.104.137.60,
#    then delete the instance profile and role streamingapp-jenkins-role.
```

Also, outside AWS:

- **Cloudflare:** delete the `streamapp` and `myjenkins` DNS records **at the same time as releasing the Elastic IP**, so the hostnames never point at an IP that AWS has reassigned to someone else.
- **MongoDB Atlas:** remove the `0.0.0.0/0` access entry and the `streamingapp` user, or delete the cluster.
- **IAM:** deactivate or delete the access keys of the setup user `kamal-admin`.
