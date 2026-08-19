# Security Model

## Purpose

This document describes the security model for the EKS Kubernetes CI/CD platform.

The design applies security controls across:

- AWS infrastructure
- Network boundaries
- Kubernetes authorization
- Non-human identities
- Container runtime
- CI/CD and GitOps pipelines
- Artifact security
- Secrets and credentials
- Administrative access
- Logging and evidence

The central security question used throughout the project is:

> Who or what needs authority, why does it need that authority, and what authority can be withheld?

The platform does not treat every technical component as automatically entitled to AWS, Kubernetes, Git, or host access.

Related docs: [Architecture](architecture.md) · [CI/CD](cicd-pipeline.md) · [GitOps](gitops.md) · [Autoscaling](autoscaling.md) · [Observability](observability.md) · [NHI inventory](nhi-governance-inventory.md)

---

## Security Principles

The implementation follows several core principles.

```text
Least privilege
    -> grant only required authority

Identity separation
    -> independent identities for independent automation systems

Private-by-default infrastructure
    -> worker nodes remain in private subnets

Short-lived cloud credentials
    -> IAM roles and OIDC instead of static AWS access keys

Explicit authorization
    -> AWS authentication and Kubernetes authorization are separate

Artifact verification
    -> security gates and immutable images before deployment

Minimal workload authority
    -> application receives no AWS permissions

Restricted administration
    -> SSM instead of inbound SSH

Evidence-driven controls
    -> validate controls rather than assuming configuration equals protection
```

---

## Trust Boundaries

The platform contains several distinct trust boundaries.

```text
                         Human Administrator
                                |
                                v
                       TerraformExecutionRole
                                |
               +----------------+----------------+
               |                                 |
               v                                 v
          AWS Resources                      Amazon EKS
                                                   |
                                                   v
                                          Kubernetes RBAC


GitHub
   |
   +-----------------------------+
   |                             |
   v                             v
Jenkins                       GitHub Actions
deploy key                       OIDC
   |                             |
   v                             v
Jenkins EC2                   AWS STS
   |                             |
   v                             v
Jenkins IAM Role            GitHub Actions Role
   |                             |
   +----------> ECR <-------------+
   |
   v
EKS authentication
   |
   v
Kubernetes RBAC


GitHub gitops branch
        |
        v
Argo CD deploy key
        |
        v
Argo CD
        |
        v
Kubernetes reconciliation
```

No single credential crosses every boundary.

---

## AWS Infrastructure Security

### VPC

The EKS environment spans two Availability Zones.

The VPC contains:

```text
Public subnets
    -> internet-facing infrastructure


Private subnets
    -> EKS worker nodes


Internet Gateway
    -> public-subnet Internet connectivity


NAT Gateways
    -> outbound connectivity for private workloads
```

Worker nodes do not receive public IP addresses.

Application traffic enters through the Application Load Balancer rather than directly reaching worker nodes.

### EKS API Endpoint

The EKS cluster has:

```text
Private endpoint access: enabled
Public endpoint access:  enabled but restricted
```

The public endpoint is limited to the administrator CIDR.

Jenkins reaches the private EKS API endpoint through a security-group-to-security-group TCP 443 rule.

The Jenkins rule is conceptually:

```text
Jenkins security group
        |
        | TCP 443
        v
EKS cluster security group
```

This is narrower than opening the private EKS API to the full VPC CIDR.

### EKS Worker Nodes

The managed node group runs in private subnets.

Configuration boundaries include:

```text
Instance type: t3.small
Capacity:      ON_DEMAND

Minimum nodes: 1
Maximum nodes: 4
```

The node IAM role contains worker-node and ECR image-pull authority.

The VPC CNI AWS permissions are not attached to the node role.

Instead, the CNI receives its own dedicated IAM role through IRSA.

This reduces authority attached to the shared worker identity.

---

## Administrative Access

### Jenkins Host Administration

Jenkins runs on a dedicated EC2 instance.

The instance does not expose inbound SSH.

Administrative access uses AWS Systems Manager Session Manager.

```text
Administrator
      |
      v
AWS IAM
      |
      v
Systems Manager
      |
      v
Jenkins EC2
```

The Jenkins instance security group contains no inbound management rule for TCP 22.

This removes the need to manage SSH ingress from administrator IP addresses.

### Ansible Administration Identity

Jenkins host configuration is performed with Ansible.

A dedicated role is used:

```text
eks-kubernetes-cicd-ansible-execution-role
```

The role can perform the operations required to configure the Jenkins instance through Systems Manager and use the temporary Ansible S3 transport bucket.

The transport bucket is short-lived infrastructure for Ansible module transfer rather than durable data storage.

Its objects are automatically expired.

---

## Kubernetes Security

### Namespace Boundary

The application runs in:

```text
challenge-app
```

The namespace applies Kubernetes Pod Security restricted controls.

Application resources are separated from system workloads in namespaces such as:

```text
kube-system
argocd
monitoring
```

### AWS Authentication vs Kubernetes Authorization

Access to EKS is divided into two distinct decisions.

```text
AWS / EKS access entry
        |
        v
May this IAM identity authenticate?


Kubernetes RBAC
        |
        v
What may the authenticated identity do?
```

Authentication does not imply cluster administrator authority.

This distinction is applied directly to Jenkins.

### Jenkins Kubernetes Access

The Jenkins IAM role has an EKS access entry mapped to:

```text
jenkins-deployers
```

Kubernetes RBAC grants deployment authority only within:

```text
challenge-app
```

The authorization boundary was tested with both a permitted and denied action.

```text
Update application Deployment: YES
Delete Kubernetes nodes:       NO
Modify kube-system workloads:  NO
```

This demonstrates namespace deployment authority without cluster-wide administration.

---

## Application Workload Security

### Application Service Account

The Flask application receives a Kubernetes ServiceAccount.

The ServiceAccount has:

```text
AWS IAM role:  none
AWS permissions: none
```

The workload does not call AWS APIs, so no AWS identity is assigned.

This is an intentional security decision.

A workload does not need an AWS identity merely because it runs in AWS.

### Service Account Token

The application pod uses:

```text
automountServiceAccountToken: false
```

The container therefore does not automatically receive a Kubernetes API token.

The application does not need to call the Kubernetes API.

Removing the unused credential reduces available authority inside the container.

### Container Runtime Controls

The Flask workload applies container security controls including:

```text
runAsNonRoot: true

runAsUser:  10001
runAsGroup: 10001

privileged: false

allowPrivilegeEscalation: false

readOnlyRootFilesystem: true

seccompProfile:
    RuntimeDefault

Linux capabilities:
    drop ALL
```

The application receives a writable emptyDir volume only for:

```text
/tmp
```

This allows runtime temporary-file behavior without making the container root filesystem writable.

### Health Checks

The application exposes:

```text
/health
```

The endpoint is used by:

```text
Kubernetes readiness probe
Kubernetes liveness probe
Application Load Balancer health check
Jenkins live deployment verification
```

A process running is not treated as sufficient proof that the application is healthy.

---

## AWS Workload Identities

### VPC CNI

The VPC CNI receives:

```text
eks-kubernetes-cicd-vpc-cni-role
```

through IRSA.

The trust policy is restricted to:

```text
Namespace:      kube-system
ServiceAccount: aws-node
```

The role carries AWS networking permissions required by the CNI.

Those permissions are not placed on the application ServiceAccount.

### AWS Load Balancer Controller

The AWS Load Balancer Controller receives:

```text
eks-kubernetes-cicd-load-balancer-controller-role
```

The IRSA trust is restricted to:

```text
Namespace:      kube-system
ServiceAccount: aws-load-balancer-controller
```

This identity creates and manages AWS load-balancing resources required by Kubernetes Ingress.

The application itself does not receive those permissions.

### Cluster Autoscaler

Cluster Autoscaler receives:

```text
eks-kubernetes-cicd-cluster-autoscaler-role
```

The trust is restricted to:

```text
Namespace:      kube-system
ServiceAccount: cluster-autoscaler
```

Scaling authority belongs to the controller that manages infrastructure capacity.

The Flask workload cannot change Auto Scaling Group capacity.

---

## Source-Control Identities

### Jenkins Deploy Key

Jenkins has a repository-specific GitHub deploy key:

```text
Jenkins read-only checkout
```

Authority:

```text
Read private repository: YES
Write repository:        NO
```

The private key is stored in Jenkins credentials.

### Argo CD Deploy Key

Argo CD uses a separate key:

```text
Argo CD read-only GitOps
```

Authority:

```text
Read private repository: YES
Write repository:        NO
```

The private key is stored as an Argo CD repository credential Secret.

Jenkins and Argo CD do not share a Git credential.

### Why Separate Git Identities?

The two systems perform different jobs.

```text
Jenkins
    -> source checkout
    -> traditional CI/CD


Argo CD
    -> desired-state reconciliation
    -> GitOps
```

Separate credentials provide:

```text
Independent ownership
Independent rotation
Independent revocation
Clearer auditability
Smaller blast radius
```

Compromise of one deploy key does not automatically grant the other system's identity.

---

## GitHub Actions AWS Identity

GitHub Actions uses OpenID Connect rather than stored AWS access keys.

The authentication flow is:

```text
GitHub Actions
      |
      v
OIDC token
      |
      v
AWS STS
      |
      v
eks-kubernetes-cicd-github-actions-role
```

The trust relationship is restricted to the expected repository and `gitops` branch.

Temporary STS credentials are issued only after the OIDC trust conditions match.

### GitHub Actions Permissions

The GitHub Actions role can publish application images to the project ECR repository.

It does not receive EKS deployment permissions.

```text
ECR publish: YES
EKS deploy:  NO
```

This maintains the GitOps separation:

```text
GitHub Actions
    -> build artifact
    -> publish artifact
    -> update Git desired state


Argo CD
    -> deploy desired state
```

---

## Jenkins AWS Identity

Jenkins uses:

```text
eks-kubernetes-cicd-jenkins-role
```

through its EC2 instance profile.

No AWS access key or secret access key is stored in Jenkins.

The role can:

```text
Authenticate to ECR
Publish application images
Inspect published image metadata
Describe the EKS cluster
```

Kubernetes deployment authority comes from the separate EKS access-entry and RBAC chain.

---

## Container Supply-Chain Security

### Checkov

Terraform is scanned with Checkov before deployment.

Final security-gate state:

```text
Passed checks: 276
Failed checks: 0
Skipped checks: 17
```

Skipped checks were reviewed individually.

The project distinguishes between:

```text
Security defect
    -> configuration changed


Service authorization constraint
    -> permission retained and documented


Intentional architecture exception
    -> residual risk documented
```

A scanner warning is not treated as proof that a configuration is either safe or unsafe without context.

### Trivy

Application images are scanned before publication.

The gate evaluates:

```text
HIGH
CRITICAL
```

vulnerabilities.

A qualifying vulnerability causes the pipeline to fail.

Both Jenkins and GitHub Actions apply the image security gate before artifact release.

### Vulnerability Investigation Example

Trivy identified vulnerable Python components that were not direct application dependencies.

The built container was inspected rather than immediately suppressing the findings.

The investigation found vendored msgpack content inside pip.

The application did not require pip at runtime.

The response was:

```text
Finding
   |
   v
Inspect actual artifact
   |
   v
Identify source
   |
   v
Remove unneeded runtime package manager
   |
   v
Rebuild
   |
   v
Re-scan
```

This removed the vulnerable component rather than hiding the scanner result.

### Container Registry Security

The Amazon ECR application repository uses immutable tags.

```text
Mutable overwrite of existing image tag: blocked
```

The delivery pipelines generate unique build tags rather than deploying `latest`.

This supports traceability between:

```text
Source revision
Pipeline run
ECR artifact
Kubernetes Deployment
```

ECR scan-on-push is enabled.

Repository encryption uses AWS-managed AES-256 encryption for the challenge environment.

---

## Deployment Integrity

### Jenkins Path

Jenkins verifies:

```text
Image built
    |
    v
Trivy passed
    |
    v
Image exists in ECR
    |
    v
Helm deploys exact tag
    |
    v
Kubernetes Deployment reports exact tag
    |
    v
Live application passes health test
```

A successful Helm command alone is not treated as complete deployment evidence.

### GitOps Path

GitHub Actions publishes an immutable image and writes that tag into Git desired state.

Argo CD then reconciles the cluster.

The tested chain was:

```text
ECR tag
c3df150-1
      |
      v
Git desired state
c3df150-1
      |
      v
Argo CD
Synced / Healthy
      |
      v
Live Deployment
c3df150-1
```

This provides end-to-end artifact traceability.

---

## Secrets and Credential Handling

The project contains several credentials with different storage locations.

| Credential                    | Storage                       | Purpose                          |
| ----------------------------- | ----------------------------- | -------------------------------- |
| Jenkins Git private key       | Jenkins credential store      | Read private Git repository      |
| Argo CD Git private key       | Kubernetes Secret in `argocd` | Read private Git repository      |
| GitHub Actions AWS credential | Short-lived STS session       | ECR publishing                   |
| Jenkins AWS credential        | EC2 IAM role session          | ECR/EKS access                   |
| Application AWS credential    | None                          | Application has no AWS authority |
| Grafana admin password        | Kubernetes Secret             | Local Grafana administration     |

Long-lived AWS access keys are not used by the Jenkins or GitHub Actions delivery paths.

Private deploy keys are not stored in Git.

---

## Terraform State Security

Terraform state is stored remotely in Amazon S3.

The state bucket uses controls including:

```text
Public-access blocking
Bucket ownership enforcement
Versioning
Encryption
TLS-only bucket policy
State locking
Lifecycle management
```

Terraform state is treated as sensitive infrastructure data.

The state bucket has a lifecycle policy for old versions and incomplete multipart uploads.

---

## Logging and Auditability

### EKS Control Plane Logging

The EKS cluster sends the following control-plane log types to CloudWatch:

```text
api
audit
authenticator
controllerManager
scheduler
```

This provides visibility into control-plane and authentication activity.

### VPC Flow Logs

VPC Flow Logs capture network-flow metadata for the VPC.

This provides network-level evidence that complements application and Kubernetes telemetry.

### Pipeline Evidence

The project stores execution evidence under:

`docs/evidence/`

Evidence includes:

- Infrastructure state
- Application validation
- Container controls
- Identity boundaries
- Autoscaling behavior
- Jenkins CI/CD
- GitHub Actions
- Argo CD reconciliation
- Prometheus and Grafana

Evidence is collected for security claims rather than for every command executed during the build.

### Monitoring Security

Prometheus and Grafana run as internal Kubernetes services.

Grafana uses:

```text
Service type: ClusterIP
```

Administrative access is performed through local port forwarding.

The project does not expose Grafana through another public load balancer.

---

## Accepted Risks and Challenge Exceptions

The project deliberately distinguishes challenge implementation from a production target.

### Jenkins Public IP

The Jenkins controller currently has a public IP.

Compensating controls include:

```text
No inbound security-group rules
No SSH exposure
SSM-only administration
```

Production direction:

```text
Private subnet
No public IP
Private management path
```

### Public Application Uses HTTP

The challenge Application Load Balancer currently serves HTTP.

Production direction:

```text
ACM certificate
HTTPS listener
HTTP -> HTTPS redirect
TLS policy
```

The absence of HTTPS is treated as a documented residual risk rather than a production-ready configuration.

### ECR Encryption

The application ECR repository uses AWS-managed AES-256 encryption.

Moving to a customer-managed KMS key would require repository replacement or migration.

For this short-lived challenge environment, the existing repository was retained.

Production direction:

```text
Customer-managed KMS key where required by policy
```

### Grafana Persistence

Grafana persistence is disabled.

Prometheus retention is short.

These choices reduce resource use in the demonstration cluster.

Production monitoring would use persistent storage and a longer-term telemetry strategy.

### Jenkins Docker Authority

Jenkins uses Docker on the controller host.

Membership in the Docker execution context carries high host authority.

The challenge accepts this on a dedicated controller.

Production direction could include:

```text
Ephemeral build agents
Rootless build tooling
Dedicated build service
Stronger workload isolation
```

---

## Threat Scenarios

### Compromised Application Container

Potential attacker goal:

```text
Use application compromise to reach AWS APIs
```

Controls:

```text
No AWS IAM role
No mounted Kubernetes API token
Non-root execution
Read-only root filesystem
Dropped Linux capabilities
No privilege escalation
RuntimeDefault seccomp
```

The application still has network access required for its service function, so application-layer vulnerabilities remain relevant.

### Compromised Jenkins Git Credential

Potential attacker goal:

```text
Modify repository
```

Control:

```text
Deploy key is read-only
```

The credential does not grant AWS authority.

### Compromised Argo CD Git Credential

Potential attacker goal:

```text
Modify Git desired state
```

Control:

```text
Deploy key is read-only
```

Argo can read desired state but cannot use that credential to commit malicious changes.

### Compromised GitHub Actions AWS Session

Potential attacker goal:

```text
Deploy directly to Kubernetes
```

Control:

```text
GitHub Actions role has no EKS deployment authority
```

The role can publish to the project ECR repository.

Cluster reconciliation remains a separate trust path.

### Compromised Jenkins AWS Session

Potential attacker goal:

```text
Gain cluster-wide Kubernetes administration
```

Controls:

```text
EKS authentication maps to jenkins-deployers
Kubernetes RBAC is namespace-scoped
Node deletion denied
kube-system modification denied
```

AWS authentication alone does not create Kubernetes cluster-admin authority.

---

## Security Ownership Model

Authority is intentionally distributed.

| Component                    | AWS Authority                    | Kubernetes Authority       | Git Authority       |
| ---------------------------- | -------------------------------- | -------------------------- | ------------------- |
| Flask application            | None                             | Workload only              | None                |
| Jenkins                      | ECR + EKS discovery              | `challenge-app` deployment | Read-only           |
| GitHub Actions               | ECR publishing                   | None                       | Desired-state write |
| Argo CD                      | None required for app deployment | Reconciliation             | Read-only           |
| AWS Load Balancer Controller | Load-balancer AWS APIs           | Controller resources       | None                |
| Cluster Autoscaler           | Node scaling APIs                | Autoscaling controller     | None                |
| VPC CNI                      | Networking AWS APIs              | Node networking            | None                |

The design avoids using one broadly privileged automation identity for the entire platform.

---

## Security Evidence

Representative evidence includes:

- `docs/evidence/security/non-root-container.png`
- `docs/evidence/security/application-workload-identity-controls.png`
- `docs/evidence/security/read-only-root-filesystem.png`
- `docs/evidence/security/writable-tmp.png`
- `docs/evidence/security/application-serviceaccount-no-aws-role.png`
- `docs/evidence/security/load-balancer-controller-identity.png`
- `docs/evidence/security/cluster-autoscaler-identity.png`
- `docs/evidence/security/jenkins-kubernetes-rbac-boundary.png`
- `docs/evidence/security/ansible-execution-role-assumption.png`
- `docs/evidence/security/jenkins-ssm-managed-instance.png`
- `docs/evidence/security/cicd-git-identity-separation.png`

Pipeline evidence provides further support for Checkov, Trivy, ECR verification, Kubernetes deployment, and GitOps reconciliation.

---

## Production Security Direction

A production version of the platform would likely add:

- HTTPS with ACM
- Private Jenkins controller
- Ephemeral or isolated build agents
- Persistent monitoring storage
- Centralized secret management
- KMS controls aligned to organization policy
- WAF where application risk warrants it
- Private or enterprise Grafana access
- Stronger network egress controls
- Image signing and provenance
- Admission controls for signed artifacts
- Automated identity inventory and access review
- Credential rotation workflows
- Formal exception expiration and review

These are extensions of the current security model rather than claims about controls already implemented.

---

## Security Summary

The strongest security property of the platform is not a single AWS or Kubernetes control.

It is the separation of trust.

```text
Application does not inherit AWS authority.

Jenkins does not inherit cluster-admin authority.

GitHub Actions does not inherit EKS deployment authority.

Argo CD does not inherit Git write authority.

Git deploy keys do not inherit cloud authority.

Cloud IAM roles do not automatically become Kubernetes authorization.
```

Each identity receives authority according to the job it performs.

That model reduces shared credentials, limits blast radius, and makes the platform's non-human identities governable.
