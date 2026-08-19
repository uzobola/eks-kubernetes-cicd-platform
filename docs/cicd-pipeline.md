# Jenkins CI/CD Pipeline

## Purpose

The Jenkins pipeline implements the project's traditional CI/CD delivery path.

It takes application source code from GitHub, validates infrastructure and container security, builds an immutable container image, publishes that image to Amazon ECR, deploys it to Amazon EKS with Helm, verifies the Kubernetes rollout, and tests the live application through the public Application Load Balancer.

The pipeline is designed so that each stage proves a distinct delivery or security claim.

Related docs: [Architecture](architecture.md) · [GitOps](gitops.md) · [Security model](security-model.md) · [NHI inventory](nhi-governance-inventory.md) · [Installation](installation.md)

This document covers the **Jenkins** delivery path only (`main` branch). The GitOps path on `gitops` (GitHub Actions + Argo CD) is intentionally separate.

---

## Pipeline Flow

```text
GitHub
   |
   v
Jenkins
   |
   +--> Checkout
   |
   +--> AWS Identity Preflight
   |
   +--> Checkov IaC Security
   |
   +--> Build Metadata
   |
   +--> Docker Build
   |
   +--> Trivy Security Gate
   |
   +--> ECR Push
   |
   +--> EKS Authentication
   |
   +--> Helm Deploy
   |
   +--> Rollout Verification
   |
   +--> Live Application Test
   |
   +--> Workspace Credential Cleanup
```

A deployment is considered successful only after the image has passed security gates, reached ECR, rolled out successfully in Kubernetes, and responded through the public application endpoint.

### Pipeline Guarantees

- `disableConcurrentBuilds()` — only one Jenkins delivery runs at a time
- Checkov and Trivy are fail-closed (non-zero exit stops the pipeline)
- Helm uses `--atomic --wait` so a failed deploy rolls back
- Success requires live ALB `/health` and the expected home-page string

---

## Prerequisites

### Source Control Authentication

Jenkins reads the private GitHub repository with a repository-specific SSH deploy key.

```text
Identity: Jenkins Git deploy key
Repository: eks-kubernetes-cicd-platform
Access: Read-only
Purpose: Source checkout
```

The key is separate from the deploy key used by Argo CD.

This gives Jenkins and Argo CD independent Git identities rather than sharing one credential across automation systems.

The private key is stored in Jenkins credentials and is not stored in the repository.

---

### Jenkins Host

Jenkins runs on a dedicated Amazon EC2 instance.

The host is configured with Ansible rather than EC2 user data.

The toolchain includes:

```text
Jenkins
Docker
AWS CLI
kubectl
Helm
Checkov
Trivy
```

Administrative access to the Jenkins host uses AWS Systems Manager Session Manager.

The Jenkins security group has no inbound SSH rule.

This removes the need to expose TCP port 22 for host administration.

---

### AWS Identity

Jenkins receives AWS permissions through its EC2 instance profile:

```text
eks-kubernetes-cicd-jenkins-role
```

No long-lived AWS access keys are stored in Jenkins.

The pipeline begins with an AWS identity preflight so the execution identity is visible before AWS operations occur.

Conceptually:

```text
Jenkins process
      |
      v
EC2 instance metadata
      |
      v
Jenkins IAM role
      |
      v
Temporary AWS credentials
```

The role receives only the AWS permissions required for the Jenkins delivery path.

#### ECR Permissions

Jenkins can authenticate to Amazon ECR and interact with the project application repository.

Repository-scoped permissions include the actions required to:

- Check image layers
- Upload image layers
- Publish image manifests
- Read image layers
- Read image metadata
- Verify the published image

`ecr:GetAuthorizationToken` uses `Resource: "*"`, as AWS does not support repository-level resource scoping for that action.

Application image operations are scoped to:

```text
eks-kubernetes-cicd-app
```

The pipeline does not receive broad access to unrelated ECR repositories.

---

## Pipeline Stages

### Stage 1: Checkout

The pipeline checks out the private repository using the Jenkins read-only deploy key.

A successful checkout proves:

```text
Jenkins credential valid
        +
Deploy key registered to correct repository
        +
Repository readable
```

The deploy key has no repository write authority.

---

### Stage 2: AWS Identity Preflight

Before cloud operations, Jenkins verifies:

```text
aws sts get-caller-identity
aws eks describe-cluster ...
aws ecr get-login-password ...
```

This confirms:

```text
Expected Jenkins IAM role
        +
Permission to discover the EKS cluster
        +
Permission to obtain an ECR auth token
```

The stage provides a clear identity boundary for troubleshooting and audit evidence.

Cluster *authentication* is still not the same as Kubernetes *authorization*. Deploy rights are checked later via RBAC (`kubectl auth can-i`).

---

### Stage 3: Checkov IaC Security

Checkov scans the Terraform configuration before application deployment.

The final project scan reached:

```text
Passed checks: 276
Failed checks: 0
Skipped checks: 17
```

Scanner findings were reviewed rather than automatically suppressed.

Findings fell into three categories:

```text
Actual security gap
    -> fix configuration


AWS or scanner resource-model limitation
    -> document scoped exception


Intentional architecture decision
    -> document risk and compensating controls
```

Examples include:

- Public Jenkins IP accepted for the challenge while inbound access remains closed and SSM is used for administration
- ECR AES-256 encryption retained instead of replacing the repository to introduce a customer-managed key
- AWS APIs that require wildcard resource scope kept at `Resource: "*"` where the service authorization model requires it

A skipped Checkov rule does not mean the underlying risk was ignored.

---

### Stage 4: Build Metadata

The pipeline generates an immutable image tag using source revision and build metadata.

Example:

```text
d205651-5
```

The resulting image URI follows:

```text
421438965568.dkr.ecr.us-east-1.amazonaws.com/eks-kubernetes-cicd-app:<immutable-tag>
```

The pipeline does not deploy `latest`.

This makes each release traceable to a source/build event.

---

### Stage 5: Docker Build

The Flask application is built from:

```text
eks-kubernetes-cicd-platform/app
```

The application image uses:

```text
python:3.13-alpine
```

The runtime container:

```text
Runs as UID/GID 10001
Uses Gunicorn
Listens on port 8080
Runs without root privileges
```

The image exposes:

```text
/        Application
/health  Health endpoint
```

#### Runtime package reduction (Trivy finding)

During pipeline development, Trivy reported HIGH findings for msgpack and setuptools.

Inspection of the built image showed that the application did not install either package as an application dependency.

Further inspection found:

```text
pip/_vendor/msgpack
pip/_vendor/bom.cdx.json
```

The vulnerable msgpack code came from pip's vendored runtime content.

The application does not require pip after dependencies have been installed, so pip and its bootstrap artifacts were removed from the final runtime image.

The security response was:

```text
Do not suppress finding
        |
        v
Inspect built artifact
        |
        v
Trace vulnerable component
        |
        v
Remove unnecessary runtime component
        |
        v
Re-run security gate
```

This reduced runtime attack surface while keeping the Trivy gate strict.

---

### Stage 6: Trivy Security Gate

Trivy scans the built application image for:

```text
HIGH
CRITICAL
```

vulnerabilities.

The pipeline uses a non-zero exit code as a hard gate.

```text
Vulnerability accepted by gate
    -> continue


HIGH/CRITICAL vulnerability
    -> stop pipeline
```

The project does not use `--ignore-unfixed` to bypass findings.

The Trivy stage must pass before the image is published.

---

### Stage 7: ECR Push

After the image passes Trivy, Jenkins authenticates Docker to Amazon ECR and pushes the immutable image.

The pipeline then calls `ecr:DescribeImages` to verify that the expected tag and image digest exist in the repository.

This verifies more than a successful `docker push` process exit.

The delivery claim becomes:

```text
Pipeline built image
        |
        v
Security gate passed
        |
        v
ECR contains expected immutable tag
        |
        v
ECR returns image digest
```

---

### Stage 8: EKS Authentication

Jenkins generates a temporary kubeconfig in the Jenkins workspace.

The AWS identity authenticates to EKS through an EKS access entry.

The Jenkins access entry maps the IAM role to:

```text
jenkins-deployers
```

Kubernetes RBAC then determines what Jenkins can do after authentication.

This separates two security decisions:

```text
AWS IAM
    -> Who may authenticate to EKS?


Kubernetes RBAC
    -> What may that identity do inside the cluster?
```

#### Kubernetes Authorization

Jenkins receives namespace-scoped deployment permissions in:

```text
challenge-app
```

The pipeline validates both an allowed and a denied action.

Expected behavior:

```text
Update deployment in challenge-app    YES
Delete cluster nodes                   NO
```

This proves that Jenkins can deploy the application without receiving cluster-administrator authority.

The distinction matters:

> AWS IAM authentication is not Kubernetes authorization.

#### Private EKS API Connectivity

The EKS API has private endpoint access enabled.

Jenkins reaches that private API over TCP 443.

A security-group-to-security-group rule permits:

```text
Jenkins security group
        |
        | TCP 443
        v
EKS cluster security group
```

The rule does not open the private EKS endpoint to an entire broad network range.

---

### Stage 9: Helm Deployment

Jenkins deploys the application with:

```text
helm upgrade --install
```

The pipeline passes the exact ECR image repository and immutable tag generated during the build.

The Helm release is:

```text
challenge-app
```

The deployment uses:

```text
--atomic
--wait
```

If the Helm operation cannot complete successfully, the release is rolled back instead of leaving a partially applied deployment.

---

### Stage 10: Rollout Verification

After Helm completes, Jenkins waits for the Kubernetes Deployment rollout.

The pipeline then retrieves the image from the live Deployment and compares it with the image produced by the pipeline.

Conceptually:

```text
Expected image
     |
     | compare
     v
Live Deployment image
```

A mismatch fails the pipeline.

This prevents a green deployment stage from masking an unexpected image version.

---

### Stage 11: Live Application Test

The final delivery stage retrieves the hostname from the Kubernetes Ingress.

Jenkins then tests:

```text
GET /health
```

Expected response:

```json
{"status":"healthy"}
```

The pipeline retries briefly while the Application Load Balancer completes target registration.

After health succeeds, Jenkins tests the live application response and verifies that it contains:

```text
Congratulations Challenge Completed !
```

The final CI/CD success condition is:

```text
Source checked out
        |
        v
AWS identity verified
        |
        v
IaC security passed
        |
        v
Container built
        |
        v
Container security passed
        |
        v
Image stored in ECR
        |
        v
Kubernetes authorization verified
        |
        v
Helm deployment completed
        |
        v
Correct image running
        |
        v
Public application responding
```

---

### Credential Cleanup

The kubeconfig created during the pipeline is stored only in the Jenkins workspace.

A post action removes:

```text
$WORKSPACE/.kube
```

after the pipeline completes.

This limits persistence of generated Kubernetes authentication configuration.

---

## Delivery Security Boundaries

The Jenkins path separates authority across several identities:

```text
Jenkins Git deploy key
    -> private GitHub repository read only


Jenkins EC2 IAM role
    -> ECR publishing
    -> EKS cluster discovery


EKS access entry
    -> cluster authentication


Kubernetes Role / RoleBinding
    -> challenge-app deployment authority
```

No single source-control credential grants AWS or Kubernetes authority.

### Explicit Non-Permissions

Jenkins is intentionally **not** able to:

- Write to the GitHub repository (read-only deploy key)
- Act as Kubernetes cluster-admin
- Delete cluster nodes
- Publish to arbitrary ECR repositories (scoped to `eks-kubernetes-cicd-app`)
- Administer the host over SSH (SSM only)

---

## Evidence

Primary evidence for the Jenkins delivery path:

- `docs/evidence/cicd/jenkins-full-pipeline-success.png`
- `docs/evidence/cicd/jenkins-private-repo-pipeline-success.png`
- `docs/evidence/security/jenkins-kubernetes-rbac-boundary.png`
- `docs/evidence/security/cicd-git-identity-separation.png`

The strongest pipeline screenshot shows all stages green through the live application test.
