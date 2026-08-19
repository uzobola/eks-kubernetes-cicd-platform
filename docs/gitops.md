# GitOps Delivery

## Purpose

The project implements a second application delivery model using GitHub Actions and Argo CD.

This path separates artifact creation from cluster reconciliation.

GitHub Actions builds, scans, and publishes the container image.

Git stores the desired application state.

Argo CD reads that desired state and reconciles the Kubernetes cluster.

The GitHub Actions workflow file lives on the **`gitops`** branch at `.github/workflows/gitops.yml`.

Related docs: [Architecture](architecture.md) · [Jenkins CI/CD](cicd-pipeline.md) · [Security model](security-model.md) · [NHI inventory](nhi-governance-inventory.md) · [Installation](installation.md)

---

## Compared to Jenkins

| Concern | Jenkins ([cicd-pipeline.md](cicd-pipeline.md)) | GitOps (this doc) |
| ------- | --------------------------------------------- | ----------------- |
| Source branch | `main` | `gitops` |
| Build / scan / push | Jenkins on EC2 | GitHub Actions |
| AWS auth | EC2 instance role | GitHub OIDC → STS |
| Cluster change | Direct `helm upgrade` | Argo CD reconciliation |
| Desired state in Git | No | Yes (`values.yaml`) |

Jenkins **deploys**. GitHub Actions **publishes and updates Git**; Argo CD **reconciles**.

---

## GitOps Flow

```text
gitops branch
      |
      v
GitHub Actions
      |
      | GitHub OIDC token
      v
AWS STS
      |
      v
GitHub Actions IAM Role
      |
      +--> Docker Build
      |
      +--> Trivy Security Gate
      |
      +--> ECR Push
      |
      v
Update Helm Desired State
      |
      v
Commit to gitops branch
      |
      v
Argo CD
      |
      v
Helm Rendering
      |
      v
Amazon EKS
```

The GitHub Actions runner does not execute `kubectl`, `helm upgrade`, or direct EKS deployment commands.

Cluster deployment authority belongs to Argo CD.

---

## Branch Model

The repository uses two delivery paths:

```text
main
    -> Jenkins CI/CD


gitops
    -> GitHub Actions
    -> Git desired state
    -> Argo CD
```

The GitOps workflow is triggered from the `gitops` branch.

Argo CD tracks the same branch as the source of desired application state.

---

## GitHub Actions

### Trigger Contract

The workflow runs on push to `gitops` when these paths change:

```text
eks-kubernetes-cicd-platform/app/**
.github/workflows/gitops.yml
```

It does **not** trigger on changes to:

```text
helm/challenge-app/values.yaml
```

That exclusion is intentional. The workflow’s own desired-state commit updates `values.yaml`. Keeping that path out of the trigger set prevents an automatic build loop.

### Concurrency and Sync Mechanics

The workflow uses:

```text
concurrency:
  group: gitops-image-publish
  cancel-in-progress: false
```

Runs in that group are serialized so two publishes do not rewrite desired state at the same time. In-progress image publishing is not cancelled mid-push.

Before pushing the desired-state commit, the workflow runs:

```text
git pull --rebase origin gitops
git push origin HEAD:gitops
```

That rebases onto the latest remote `gitops` tip and reduces non-fast-forward races.

### Authentication to AWS

GitHub Actions does not store long-lived AWS access keys.

The workflow requests a GitHub OIDC token and exchanges it through AWS STS for temporary credentials.

```text
GitHub Actions runner
        |
        v
GitHub OIDC token
        |
        v
AWS IAM trust policy
        |
        v
STS temporary credentials
        |
        v
GitHub Actions IAM role
```

The AWS role is:

```text
eks-kubernetes-cicd-github-actions-role
```

### OIDC Trust Boundary

The IAM role trust is restricted to the GitHub OIDC provider and the exact repository / branch identity used by the GitOps workflow.

The bound subject is:

```text
repo:uzobola@173111719/eks-kubernetes-cicd-platform@1333767654:ref:refs/heads/gitops
```

The trust also requires:

```text
aud = sts.amazonaws.com
```

This means the role can be assumed only when the GitHub OIDC token represents the expected repository and the `gitops` branch.

A workflow from another repository or ref does not satisfy the trust conditions.

A token from another repository, branch, or unrelated GitHub workflow context cannot assume the role through this trust relationship.

### AWS Permissions

The GitHub Actions role can:

```text
Authenticate to ECR
Push application image layers
Publish application images
Read application image metadata
```

Image operations are scoped to the project ECR repository.

The role does not receive EKS deployment permissions.

It has no EKS access entry.

This is deliberate.

The build system can produce artifacts, but it cannot directly deploy them into the cluster.

### Workflow Stages

```text
Checkout gitops branch
        |
        v
Generate build metadata
        |
        v
Build application image
        |
        v
Trivy security gate
        |
        v
Configure AWS credentials through OIDC
        |
        v
Verify AWS identity
        |
        v
Authenticate Docker to ECR
        |
        v
Push immutable image
        |
        v
Update Git desired state
        |
        v
Commit desired state
```

Trivy runs **before** OIDC credential assumption. A HIGH/CRITICAL image fails the job without the runner ever assuming the AWS role or touching ECR / Git desired state.

### Immutable Image Publishing

The workflow creates an image tag derived from Git source and workflow run metadata.

Example:

```text
c3df150-1
```

The image is published to:

```text
421438965568.dkr.ecr.us-east-1.amazonaws.com/eks-kubernetes-cicd-app
```

The workflow verifies the image in ECR after publication.

### Container Security Gate

The GitOps build path uses Trivy with the same security expectation as Jenkins:

```text
Severity:
HIGH
CRITICAL

Failure behavior:
non-zero exit
```

A failing image does not proceed to ECR publication or desired-state modification.

The security gate therefore sits before both artifact release and Git reconciliation — and before AWS credentials are obtained.

### Desired State Update

After publishing the image, GitHub Actions updates:

```text
helm/challenge-app/values.yaml
```

The image section contains the desired immutable ECR artifact.

Example:

```yaml
image:
  repository: "421438965568.dkr.ecr.us-east-1.amazonaws.com/eks-kubernetes-cicd-app"
  tag: "c3df150-1"
  pullPolicy: IfNotPresent
```

Git records the deployment intent.

The cluster is not modified by this step.

### Workflow Loop Prevention

The automated desired-state commit modifies `helm/challenge-app/values.yaml`, which is outside the build-trigger paths listed above.

The bot commit does not immediately trigger another image build.

### Git Write Identity

The workflow uses the GitHub Actions repository token for the automated desired-state commit.

Its repository write access exists for the workflow operation.

AWS permissions remain separate from Git permissions.

```text
GitHub token
    -> repository desired-state write


AWS OIDC role
    -> ECR artifact publishing
```

One credential does not represent both trust domains.

### What GitHub Actions Cannot Do

The GitHub Actions AWS role intentionally has no EKS deployment authority.

The workflow does not perform:

```text
aws eks update-kubeconfig
kubectl apply
kubectl set image
helm upgrade
```

This is one of the main security distinctions between the traditional pipeline and the GitOps pipeline.

Traditional pipeline:

```text
Jenkins
    -> directly deploys
```

GitOps pipeline:

```text
GitHub Actions
    -> publishes artifact
    -> updates Git

Argo CD
    -> deploys
```

---

## Argo CD

### Installation

Argo CD is installed in the `argocd` namespace using the pinned upstream Argo CD `v3.5.0` installation manifest.

```bash
aws-vault exec terraform -- \
  kubectl apply \
  -n argocd \
  --server-side \
  --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.0/manifests/install.yaml
```

A pinned release is used rather than the moving `stable` manifest so the installed platform version is explicit and reproducible.

These are two separate concerns:

```text
Argo CD installation:
Pinned upstream v3.5.0 install.yaml

Application deployment through Argo CD:
Helm chart at helm/challenge-app/
```

Argo CD itself was **not** installed with Helm. Argo CD uses the application's Helm chart as the Git desired-state source.

The installation was validated by confirming the Argo CD components were running:

```bash
aws-vault exec terraform -- \
  kubectl get pods -n argocd
```

Validated components included:

```text
argocd-application-controller
argocd-applicationset-controller
argocd-dex-server
argocd-notifications-controller
argocd-redis
argocd-repo-server
argocd-server
```

The Application definition for this workload is kept at:

```text
platform/argocd/challenge-app.yaml
```

Argo CD UI access for this challenge uses local `kubectl port-forward` rather than a public load balancer.

### Git Repository Access

Argo CD reads the private repository through a dedicated repository deploy key:

```text
Argo CD read-only GitOps
```

The key is read-only.

It is separate from:

```text
Jenkins read-only checkout
```

This creates two independent machine identities for Git access:

```text
Jenkins
    -> Git read only
    -> traditional CI/CD


Argo CD
    -> Git read only
    -> reconciliation
```

The Argo CD private key is stored as a Kubernetes Secret in the `argocd` namespace.

The private key is not committed to Git.

### Application

The Argo CD Application is:

```text
challenge-app-gitops
```

It tracks:

```text
Repository:
eks-kubernetes-cicd-platform

Revision:
gitops

Path:
helm/challenge-app

Destination namespace:
challenge-app
```

Helm renders the Kubernetes desired state from the repository.

### Automated Reconciliation

Argo CD is configured with automated synchronization.

The Application uses:

```text
automated sync
prune
self-heal
```

These settings mean:

```text
Git change
    -> Argo detects drift
    -> cluster reconciled


Git resource removed
    -> obsolete managed resource pruned


Live managed resource changed
    -> Argo restores Git state
```

Git becomes the desired-state authority for this delivery path.

The two delivery models are for demonstration and comparison. Do not treat Jenkins Helm deploys and Argo CD auto-sync as simultaneous owners of the same release — they can compete over desired state. See [Architecture](architecture.md) and [Installation](installation.md) section 24.

### Proven Reconciliation

The final Argo CD Application state was:

```text
SYNC STATUS:   Synced
HEALTH STATUS: Healthy
```

The live Deployment image was queried directly from Kubernetes.

Observed image:

```text
421438965568.dkr.ecr.us-east-1.amazonaws.com/eks-kubernetes-cicd-app:c3df150-1
```

That matched the image tag committed by GitHub Actions to the `gitops` branch.

The tested chain was:

```text
GitHub Actions
      |
      v
ECR image c3df150-1
      |
      v
Git values.yaml
tag: c3df150-1
      |
      v
Argo CD
Synced / Healthy
      |
      v
Live EKS Deployment
image: c3df150-1
```

This proves that Git desired state reached the Kubernetes workload through Argo CD.

---

## Identity Separation

The GitOps path contains distinct non-human identities with different jobs.

```text
GitHub Actions OIDC identity
    -> authenticate to AWS


GitHub Actions IAM role
    -> publish image to ECR


GitHub Actions repository token
    -> update desired state


Argo CD deploy key
    -> read private Git repository


Argo CD service accounts
    -> reconcile Kubernetes resources
```

This separation reduces shared credentials and makes ownership and authority easier to reason about.

---

## Offboarding Model

The GitOps identities have different retirement actions.

If GitHub Actions is retired:

```text
Remove IAM trust
Remove GitHub Actions role/policy
Remove workflow
```

If Argo CD Git access is retired:

```text
Remove GitHub deploy key
Delete Argo repository credential Secret
```

If the Argo-managed workload is retired:

```text
Remove desired state from Git
Allow Argo to prune managed resources
Remove Application if no longer required
```

Offboarding the identity is not the same action as deleting the workload.

Each trust relationship has its own lifecycle.

---

## Evidence

Primary GitOps evidence:

- `docs/evidence/gitops/github-actions-gitops-success.png`
- `docs/evidence/gitops/argocd-components-running.png`
- `docs/evidence/gitops/argocd-synced-healthy.png`
- `docs/evidence/security/cicd-git-identity-separation.png`
