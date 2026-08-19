# Installation and Deployment Runbook

## Purpose

This runbook describes how to provision, configure, deploy, validate, and remove the EKS Kubernetes CI/CD platform.

The platform includes:

- AWS networking and EKS infrastructure
- Amazon ECR
- Jenkins
- Ansible host configuration through AWS Systems Manager
- Kubernetes application resources
- AWS Load Balancer Controller
- Metrics Server
- Horizontal Pod Autoscaler
- Cluster Autoscaler
- GitHub Actions OIDC
- Argo CD
- Prometheus
- Grafana

Commands assume execution from the repository root unless stated otherwise.

Related docs: [Architecture](architecture.md) · [CI/CD](cicd-pipeline.md) · [GitOps](gitops.md) · [Security model](security-model.md) · [NHI inventory](nhi-governance-inventory.md) · [Autoscaling](autoscaling.md) · [Observability](observability.md)

### Runbook phases

| Phase | Sections | Focus |
| ----- | -------- | ----- |
| A — Infrastructure | 1–6 | Prerequisites, AWS auth, Terraform bootstrap + platform, core validation |
| B — Jenkins | 7–16 | Ansible, Git deploy key, RBAC, app deploy + live validation |
| C — Scaling | 17–18 | HPA and Cluster Autoscaler validation |
| D — GitOps | 19–24 | `gitops` branch, OIDC, Argo CD, reconciliation ownership |
| E — Monitoring | 25–27 | Prometheus / Grafana install and access |
| F — Closeout | 28–33 | Security checks, evidence, teardown, identity offboarding |

---

## 1. Prerequisites

The operator workstation requires:

```text
Git
AWS CLI
AWS Vault
Terraform
kubectl
Helm
Ansible
Docker
SSH key generation tools
```

The operator also requires:

```text
AWS account access
GitHub repository access
Permission to assume the Terraform execution role
Permission to assume the Ansible execution role
```

AWS region used by the project:

```text
us-east-1
```

---

## 2. Clone the Repository

Clone the private repository using an authorized human Git credential:

```bash
git clone git@github.com:uzobola/eks-kubernetes-cicd-platform.git

cd eks-kubernetes-cicd-platform
```

Confirm the branch:

```bash
git branch --show-current
```

Primary infrastructure and Jenkins documentation work is maintained from:

```text
main
```

GitOps desired state is maintained separately on:

```text
gitops
```

---

## 3. AWS Authentication

The project uses AWS Vault rather than placing long-lived AWS credentials in shell environment files.

Validate the Terraform identity:

```bash
aws-vault exec terraform -- \
  aws sts get-caller-identity
```

Expected administrative role:

```text
TerraformExecutionRole
```

Validate the Ansible execution identity when host configuration is required:

```bash
aws-vault exec ansible -- \
  aws sts get-caller-identity
```

The expected role is:

```text
eks-kubernetes-cicd-ansible-execution-role
```

---

## 4. Terraform State Bootstrap

Terraform state is stored remotely in Amazon S3.

The bootstrap layer creates the remote-state infrastructure before the main platform configuration uses it.

The state design includes:

```text
S3 remote state
Versioning
Public-access blocking
Encryption
TLS-only access
Terraform native state locking
Lifecycle controls
```

Run bootstrap from `terraform/bootstrap` first.

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/bootstrap init

aws-vault exec terraform -- \
  terraform -chdir=terraform/bootstrap plan

aws-vault exec terraform -- \
  terraform -chdir=terraform/bootstrap apply
```

After the state bucket exists, point the infrastructure backend at that remote state (see `terraform/infrastructure/backend.tf`).

Do not delete the state bucket while managed infrastructure still exists.

---

## 5. Provision AWS Infrastructure

Run platform Terraform from `terraform/infrastructure`.

Copy and edit `terraform/infrastructure/terraform.tfvars` from `terraform.tfvars.example` (at least `admin_cidr` and `terraform_admin_principal_arn`) before the first apply.

Initialize:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure init
```

Review the plan:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan
```

Apply:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure apply
```

Terraform provisions resources including:

```text
VPC
Public subnets
Private subnets
Internet Gateway
NAT Gateways
Route tables
EKS cluster
EKS managed node group
ECR repository
IAM roles
IRSA roles
Security groups
Jenkins EC2 infrastructure
SSM access
Logging
Terraform-related storage
```

The worker-node group is configured with:

```text
Instance type: t3.small
Minimum:       1
Desired:       1
Maximum:       4
```

Worker nodes run in private subnets.

---

## 6. Validate Core Infrastructure

Confirm AWS identity:

```bash
aws-vault exec terraform -- \
  aws sts get-caller-identity
```

Configure Kubernetes access:

```bash
aws-vault exec terraform -- \
  aws eks update-kubeconfig \
  --region us-east-1 \
  --name eks-kubernetes-cicd-cluster
```

Validate the cluster:

```bash
aws-vault exec terraform -- \
  kubectl get nodes
```

Expected initial state:

```text
1 Ready worker node
```

Validate namespaces:

```bash
aws-vault exec terraform -- \
  kubectl get namespaces
```

---

## 7. Configure Jenkins with Ansible

Jenkins host configuration is performed through Ansible.

The design intentionally avoids inbound SSH.

Connection path:

```text
Operator
   |
   v
Ansible execution role
   |
   v
AWS Systems Manager
   |
   v
Jenkins EC2
```

The Jenkins security group does not expose TCP 22.

From `ansible/`, run the configure playbook with the `ansible` AWS Vault profile (inventory discovers the Jenkins instance via EC2 tags over SSM):

```bash
cd ansible
aws-vault exec ansible -- \
  ansible-playbook playbooks/configure-jenkins.yml -v
```

On Windows with WSL, an equivalent pattern used in this project is:

```bash
aws-vault exec ansible -- \
  wsl.exe bash -lc \
  'cd /mnt/c/Users/<you>/projects/1-percent-university/tech-challenge-2/ansible && ansible-playbook playbooks/configure-jenkins.yml -v'
```

The playbook configures the Jenkins host with the project toolchain, including:

```text
Jenkins
Docker
AWS CLI
kubectl
Helm
Checkov
Trivy
```

Validate Ansible idempotence by running the configuration again and confirming that already-correct resources do not produce unnecessary changes.

---

## 8. Validate Jenkins Host Management

Confirm the Jenkins instance is managed by Systems Manager.

Example:

```bash
aws-vault exec ansible -- \
  aws ssm describe-instance-information
```

The Jenkins EC2 instance should appear as an SSM-managed instance.

SSH ingress is not required.

---

## 9. Configure Jenkins Git Authentication

The private GitHub repository uses a dedicated read-only Jenkins deploy key.

Generate a key pair if one does not already exist:

```bash
ssh-keygen \
  -t ed25519 \
  -C "jenkins-eks-kubernetes-cicd-platform" \
  -f ~/.ssh/jenkins_eks_cicd \
  -N ""
```

Display the public key:

```bash
cat ~/.ssh/jenkins_eks_cicd.pub
```

In GitHub:

```text
Repository
-> Settings
-> Deploy keys
-> Add deploy key
```

Configure:

```text
Title:
Jenkins read-only checkout

Write access:
Disabled
```

Store the corresponding private key in the Jenkins credential store.

Do not commit the private key to Git.

---

## 10. Jenkins Kubernetes Authorization

Jenkins authenticates to EKS through its IAM role and an EKS access entry.

The identity maps to:

```text
jenkins-deployers
```

Apply the application namespace and Jenkins RBAC if they are not already present:

```bash
aws-vault exec terraform -- \
  kubectl apply -f platform/namespaces/challenge-app.yaml

aws-vault exec terraform -- \
  kubectl apply -f platform/rbac/jenkins-deployer.yaml
```

The RBAC configuration lives under:

```text
platform/rbac/
```

Validate authorization **as the Jenkins IAM principal** (not the Terraform admin role). From the Jenkins host (or any shell using Jenkins instance credentials):

```bash
kubectl auth can-i update deployments \
  --namespace challenge-app
```

Expected:

```text
yes
```

Validate a forbidden cluster-level action:

```bash
kubectl auth can-i delete nodes
```

Expected:

```text
no
```

Running these checks only as the Terraform admin proves little about Jenkins least privilege.

Jenkins must not require cluster-admin authority for application deployment.

---

## 11. Kubernetes Application

The Flask application source is stored under:

```text
eks-kubernetes-cicd-platform/app/
```

The container listens on:

```text
8080
```

Application endpoints:

```text
/        Main application
/health  Health check
```

The application is deployed through the Helm chart:

```text
helm/challenge-app/
```

The chart creates resources such as:

```text
ServiceAccount
Deployment
ClusterIP Service
Ingress
HorizontalPodAutoscaler
```

---

## 12. Application Security Controls

Before deployment, confirm the chart retains the expected workload controls:

```text
Non-root UID/GID 10001
Privilege escalation disabled
Read-only root filesystem
All Linux capabilities dropped
RuntimeDefault seccomp
Writable /tmp volume
ServiceAccount token automount disabled
No AWS IAM role for the application
```

The Flask workload does not require AWS API access.

Do not add an AWS role unless an application requirement appears that requires one.

---

## 13. AWS Load Balancer Controller

The AWS Load Balancer Controller uses a dedicated IRSA identity.

IAM role:

```text
eks-kubernetes-cicd-load-balancer-controller-role
```

Kubernetes ServiceAccount:

```text
kube-system/aws-load-balancer-controller
```

Validate the controller:

```bash
aws-vault exec terraform -- \
  kubectl get pods \
  -n kube-system \
  -l app.kubernetes.io/name=aws-load-balancer-controller
```

The controller should be in `Running` state.

The application Ingress causes an internet-facing Application Load Balancer to be provisioned.

---

## 14. Metrics Server

Metrics Server provides CPU and memory telemetry used by the HPA.

Validate:

```bash
aws-vault exec terraform -- \
  kubectl top nodes
```

Then:

```bash
aws-vault exec terraform -- \
  kubectl top pods -n challenge-app
```

If these commands return resource metrics, Metrics Server is functioning.

---

## 15. Application Deployment

The Jenkins pipeline performs the primary `main`-branch deployment.

Its stages are:

```text
Checkout
AWS Identity Preflight
Checkov IaC Security
Build Metadata
Docker Build
Trivy Security Gate
ECR Push
EKS Authentication
Helm Deploy
Rollout Verification
Live Application Test
Post Actions
```

A successful run should finish with every stage green.

The pipeline deploys an immutable ECR image tag with:

```bash
helm upgrade --install challenge-app \
  helm/challenge-app \
  --namespace challenge-app \
  --set image.repository="<ECR_REPOSITORY>" \
  --set image.tag="<IMAGE_TAG>" \
  --atomic \
  --wait \
  --timeout 5m
```

The exact repository and tag are supplied by the pipeline.

---

## 16. Validate the Application

Inspect Kubernetes resources:

```bash
aws-vault exec terraform -- \
  kubectl get deployment,pods,svc,ingress,hpa \
  -n challenge-app
```

Retrieve the Ingress address:

```bash
aws-vault exec terraform -- \
  kubectl get ingress \
  -n challenge-app
```

Test health:

```bash
curl http://<ALB-DNS>/health
```

Expected:

```json
{"status":"healthy"}
```

Test the application:

```bash
curl http://<ALB-DNS>/
```

Expected page content includes:

```text
Congratulations Challenge Completed !
```

---

## 17. Horizontal Pod Autoscaling Validation

Inspect the HPA:

```bash
aws-vault exec terraform -- \
  kubectl get hpa \
  -n challenge-app
```

Configuration:

```text
Minimum replicas: 1
Maximum replicas: 3
CPU target:       50%
Memory target:    50%
```

During load testing, watch:

```bash
aws-vault exec terraform -- \
  kubectl get hpa,pods \
  -n challenge-app \
  -w
```

Expected scale-out:

```text
1 -> 2 -> 3 pods
```

After load stops, the HPA should eventually return to:

```text
1 pod
```

Scale-in may take several minutes.

---

## 18. Cluster Autoscaler Validation

Cluster Autoscaler uses:

```text
eks-kubernetes-cicd-cluster-autoscaler-role
```

through IRSA.

Validate the workload:

```bash
aws-vault exec terraform -- \
  kubectl get pods \
  -n kube-system \
  -l app.kubernetes.io/name=aws-cluster-autoscaler
```

Watch nodes during scheduling pressure:

```bash
aws-vault exec terraform -- \
  kubectl get nodes -w
```

Expected tested behavior:

```text
Scale out:
1 -> 2 nodes

Scale in:
2 -> 1 node
```

Terraform ignores runtime `desired_size` changes so Cluster Autoscaler can own that value.

---

## 19. GitOps Branch

Switch to the GitOps branch when working with the GitOps delivery model:

```bash
git checkout gitops
git pull origin gitops
```

The GitOps workflow is located under:

```text
.github/workflows/
```

It builds the application, scans the image, authenticates to AWS through OIDC, publishes the artifact to ECR, and updates:

```text
helm/challenge-app/values.yaml
```

with the new immutable image tag.

The workflow does not deploy directly to EKS.

---

## 20. GitHub Actions OIDC

GitHub Actions assumes:

```text
eks-kubernetes-cicd-github-actions-role
```

through GitHub OIDC and AWS STS.

No AWS access key or secret access key is stored in GitHub.

Validate a workflow run by confirming:

```text
OIDC authentication succeeds
AWS identity preflight succeeds
Trivy passes
ECR image is published
Desired-state commit is created
```

The GitHub Actions role must not receive EKS deployment authority.

---

## 21. Argo CD Installation

Argo CD is installed into:

```text
argocd
```

Create the namespace if needed:

```bash
aws-vault exec terraform -- \
  kubectl create namespace argocd
```

The project installation used a pinned upstream Argo CD install manifest (operational source of truth for this runbook).

Example project command:

```bash
aws-vault exec terraform -- \
  kubectl apply \
  -n argocd \
  --server-side \
  --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.0/manifests/install.yaml
```

Validate:

```bash
aws-vault exec terraform -- \
  kubectl get pods -n argocd
```

All core Argo CD components should be `Running`.

---

## 22. Configure Argo CD Repository Authentication

Argo CD uses a deploy key separate from Jenkins.

Generate it:

```bash
ssh-keygen \
  -t ed25519 \
  -C "argocd-eks-kubernetes-cicd-platform" \
  -f ~/.ssh/argocd_eks_gitops \
  -N ""
```

Add the public key to the GitHub repository as:

```text
Argo CD read-only GitOps
```

Do not enable write access.

Create the repository credential without committing the private key:

```bash
aws-vault exec terraform -- \
  kubectl -n argocd create secret generic \
  argocd-repo-eks-kubernetes-cicd \
  --from-literal=type=git \
  --from-literal=url=git@github.com:uzobola/eks-kubernetes-cicd-platform.git \
  --from-file=sshPrivateKey="$HOME/.ssh/argocd_eks_gitops"
```

Label the Secret:

```bash
aws-vault exec terraform -- \
  kubectl -n argocd label secret \
  argocd-repo-eks-kubernetes-cicd \
  argocd.argoproj.io/secret-type=repository
```

Never print the Secret contents into logs or screenshots.

---

## 23. Bootstrap the Argo CD Application

The Application definition is stored under:

```text
platform/argocd/
```

Apply it:

```bash
aws-vault exec terraform -- \
  kubectl apply \
  -f platform/argocd/challenge-app.yaml
```

Inspect:

```bash
aws-vault exec terraform -- \
  kubectl -n argocd get application \
  challenge-app-gitops
```

Expected:

```text
SYNC STATUS:   Synced
HEALTH STATUS: Healthy
```

Verify the live image:

```bash
aws-vault exec terraform -- \
  kubectl -n challenge-app get deployment challenge-app \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

The image should match the tag recorded in the `gitops` branch Helm values.

---

## 24. GitOps Controller Ownership

Once automated Argo CD reconciliation is active, Git is the desired-state authority for the GitOps path.

Avoid repeatedly running Jenkins against the same release while testing Argo self-healing.

The two deployment models exist to demonstrate separate approaches:

```text
Jenkins
    -> direct Helm deployment

GitHub Actions + Argo CD
    -> GitOps reconciliation
```

Running both controllers against the same release can cause them to compete over desired state.

---

## 25. Prometheus and Grafana

The observability configuration is stored under:

```text
platform/observability/
```

Add the Prometheus Community Helm repository:

```bash
helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts

helm repo update
```

Install the project monitoring profile:

```bash
aws-vault exec terraform -- \
  helm upgrade --install monitoring \
  prometheus-community/kube-prometheus-stack \
  --version 88.3.0 \
  --namespace monitoring \
  --create-namespace \
  -f platform/observability/kube-prometheus-stack-values.yaml \
  --wait \
  --timeout 10m
```

Validate:

```bash
aws-vault exec terraform -- \
  kubectl get pods -n monitoring
```

Monitoring components should include:

```text
Prometheus
Prometheus Operator
Grafana
kube-state-metrics
node-exporter
```

---

## 26. Access Grafana

Grafana is not exposed publicly.

Retrieve the generated administrator password locally:

```bash
aws-vault exec terraform -- \
  kubectl -n monitoring get secret monitoring-grafana \
  -o jsonpath='{.data.admin-password}' \
  | base64 --decode

echo
```

Do not capture the password in evidence.

Start port forwarding:

```bash
aws-vault exec terraform -- \
  kubectl -n monitoring port-forward \
  svc/monitoring-grafana \
  3000:80
```

Open:

```text
http://localhost:3000
```

Use the Kubernetes compute-resource dashboards to verify live CPU and memory telemetry.

---

## 27. Monitoring Validation

Validate resource telemetry from Kubernetes:

```bash
aws-vault exec terraform -- \
  kubectl top pods -n monitoring
```

Validate Prometheus:

```bash
aws-vault exec terraform -- \
  kubectl get prometheus -n monitoring
```

Validate services:

```bash
aws-vault exec terraform -- \
  kubectl get svc -n monitoring
```

Grafana should display live metrics from actual EKS workloads.

---

## 28. Security Validation

Before considering the environment complete, validate the primary security claims.

### Terraform

Run Checkov against the Terraform configuration.

Expected project baseline:

```text
Passed:  276
Failed:  0
Skipped: 17
```

Skipped findings should have documented dispositions.

### Container

Run Trivy against the application image.

Expected gate:

```text
HIGH:     0 unresolved findings accepted by gate
CRITICAL: 0 unresolved findings accepted by gate
```

### Application identity

Confirm no AWS role is attached to the application ServiceAccount.

Confirm the application pod does not receive an automatically mounted Kubernetes API token.

### Container runtime

Confirm:

```text
Non-root
Read-only root filesystem
Writable /tmp
Privilege escalation disabled
```

### Jenkins authorization

Confirm:

```text
Application Deployment update: allowed
Node deletion:                 denied
kube-system modification:      denied
```

### Git identities

Confirm the private repository has two independent read-only deploy keys:

```text
Jenkins read-only checkout
Argo CD read-only GitOps
```

---

## 29. Final Platform Validation

A successful platform validation should demonstrate:

```text
Terraform infrastructure applies successfully

EKS node is Ready

Application pods are Running

ALB health check is healthy

Public application responds

HPA scales 1 -> 3 -> 1

Cluster Autoscaler scales node capacity

Jenkins pipeline completes successfully

Checkov gate passes

Trivy gate passes

GitHub Actions authenticates through OIDC

GitHub Actions publishes immutable ECR image

Git desired state receives new image tag

Argo CD reports Synced / Healthy

Live EKS image matches Git desired state

Prometheus collects metrics

Grafana displays live Kubernetes telemetry
```

---

## 30. Evidence

Validation evidence is stored under `docs/evidence/`.

Categories:

- `docs/evidence/infrastructure/`
- `docs/evidence/application/`
- `docs/evidence/security/`
- `docs/evidence/autoscaling/`
- `docs/evidence/cicd/`
- `docs/evidence/gitops/`
- `docs/evidence/observability/`

Evidence should demonstrate a claim, not simply show that a command was executed.

---

## 31. Teardown Order

Teardown should follow dependency order.

A safe high-level sequence is:

```text
1. Stop application delivery activity
2. Remove Argo CD-managed application state
3. Remove monitoring stack
4. Remove Argo CD
5. Remove Kubernetes application resources
6. Remove Kubernetes controllers where not Terraform-managed
7. Remove Jenkins application deployment activity
8. Remove GitHub deploy keys and stored private credentials
9. Remove GitHub Actions OIDC role/trust if retiring the project
10. Run Terraform destroy for managed infrastructure
11. Remove bootstrap state infrastructure only after state is no longer required
```

Before deleting identities, confirm no active workload still depends on them.

---

## 32. Terraform Destroy

Review the destroy plan first:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan -destroy
```

Then destroy managed infrastructure:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure destroy
```

The Terraform state bucket may have deletion protection and should be handled separately.

Do not manually delete the state store before Terraform-managed infrastructure has been removed.

---

## 33. Identity Offboarding Check

After teardown, verify that project identities have been removed or intentionally retained.

Review:

```text
Terraform execution access
Ansible execution role
Jenkins IAM role
Jenkins EKS access entry
Jenkins Kubernetes RBAC
Jenkins Git deploy key
GitHub Actions IAM role
GitHub OIDC trust
Argo CD Git deploy key
Argo repository credential Secret
IRSA roles
Kubernetes ServiceAccounts
EKS worker-node role
```

The final offboarding question is:

> Can a retired workload or automation system still authenticate to anything?

If yes, identity teardown is incomplete.