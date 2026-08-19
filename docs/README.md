# Documentation Index

This directory contains the technical, operational, security, and evidence documentation for the EKS Kubernetes CI/CD Platform.

The documentation is organized so a reviewer can move from the high-level architecture into implementation details, security decisions, identity governance, operational procedures, and supporting evidence.

---

## Start Here

If this is your first time reviewing the project, use this order:

1. [Architecture](architecture.md)
2. [Security Model](security-model.md)
3. [Jenkins CI/CD Pipeline](cicd-pipeline.md)
4. [GitOps Delivery](gitops.md)
5. [Non-Human Identity Governance](nhi-governance-inventory.md)
6. [Autoscaling](autoscaling.md)
7. [Observability](observability.md)
8. [Installation and Operations](installation.md)

For interview-oriented engineering decisions and lessons:

[Interview Story Bank](interview.md)

---

## Documentation Map

### Architecture

[**architecture.md**](architecture.md)

Explains the platform design and how the major components interact.

Topics include:

- AWS VPC and subnet architecture
- Amazon EKS
- Application Load Balancer
- Kubernetes Deployment, Service, and Ingress
- Horizontal Pod Autoscaler
- Cluster Autoscaler
- Jenkins delivery path
- GitOps delivery path
- Prometheus and Grafana
- Security and identity boundaries

Use this document when answering:

> What did you build, and how do the components fit together?

---

### Jenkins CI/CD

[**cicd-pipeline.md**](cicd-pipeline.md)

Documents the traditional CI/CD delivery model:

```text
GitHub
   |
   v
Jenkins
   |
   +--> Checkov
   +--> Docker Build
   +--> Trivy
   +--> ECR
   +--> EKS Authentication
   +--> Helm
   +--> Rollout Verification
   +--> Live Application Test
```

Topics include:

- GitHub deploy-key authentication
- Jenkins EC2 IAM role
- ECR permissions
- Checkov IaC security gate
- Trivy image security gate
- EKS authentication
- Kubernetes RBAC
- Helm deployment
- Rollout validation
- Live application testing
- Credential cleanup

Use this document when answering:

> How does the traditional deployment pipeline work?

---

### GitOps

[**gitops.md**](gitops.md)

Documents the GitOps delivery model:

```text
GitHub Actions
      |
      | OIDC
      v
AWS STS
      |
      v
Amazon ECR
      |
      v
Git Desired State
      |
      v
Argo CD
      |
      v
Amazon EKS
```

Topics include:

- GitHub Actions OIDC federation
- Short-lived AWS credentials
- Immutable image publication
- Git desired-state updates
- Argo CD repository authentication
- Automated synchronization
- Self-healing
- Pruning
- Separation between CI and deployment authority

Use this document when answering:

> Why doesn't GitHub Actions deploy directly to EKS?

---

### Security Model

[**security-model.md**](security-model.md)

Describes the platform's security architecture and trust boundaries.

Topics include:

- Private EKS worker nodes
- Restricted EKS API access
- Systems Manager administration
- Kubernetes Pod Security controls
- Container hardening
- EKS access entries
- Kubernetes RBAC
- IRSA
- Git deploy keys
- GitHub Actions OIDC
- Jenkins IAM
- Checkov
- Trivy
- Terraform state security
- Accepted risks
- Compensating controls
- Threat scenarios
- Production security improvements

Use this document when answering:

> Who has authority in this platform, and where does that authority stop?

---

### Non-Human Identity Governance

[**nhi-governance-inventory.md**](nhi-governance-inventory.md)

Inventories the major machine and workload identities in the platform.

Examples include:

- Terraform execution role
- Ansible execution role
- Jenkins IAM role
- Jenkins Git deploy key
- GitHub Actions OIDC identity
- GitHub Actions IAM role
- Argo CD Git deploy key
- Application ServiceAccount
- VPC CNI IRSA role
- AWS Load Balancer Controller IRSA role
- Cluster Autoscaler IRSA role
- EKS worker-node role

For each identity, the inventory considers:

- Owner
- Purpose
- Identity type
- Authentication mechanism
- Trust relationship
- Granted authority
- Explicitly withheld authority
- Credential storage
- Rotation or replacement
- Offboarding
- Supporting evidence

Use this document when answering:

> How are machine identities governed across their lifecycle?

A central principle is:

> Does this workload need an AWS identity at all?

The Flask workload does not, so no AWS IAM role was created for it.

---

### Autoscaling

[**autoscaling.md**](autoscaling.md)

Documents both scaling layers.

#### Horizontal Pod Autoscaler

```text
Minimum replicas: 1
Maximum replicas: 3
CPU target:       50%
Memory target:    50%
```

Validated behavior:

```text
1 -> 3 pods
3 -> 2 -> 1 pods
```

#### Cluster Autoscaler

Managed node group:

```text
Minimum nodes: 1
Desired nodes: 1
Maximum nodes: 4
```

Validated behavior:

```text
1 -> 2 nodes
2 -> 1 node
```

The document also explains why Terraform ignores runtime changes to node-group `desired_size`.

Use this document when answering:

> What is the difference between scaling pods and scaling worker nodes?

---

### Observability

[**observability.md**](observability.md)

Documents the Kubernetes monitoring stack.

Components:

```text
Prometheus
Prometheus Operator
Grafana
kube-state-metrics
node-exporter
```

Topics include:

- Prometheus collection
- Grafana visualization
- Kubernetes resource telemetry
- Node and pod metrics
- Resource-conscious monitoring configuration
- Grafana access through `kubectl port-forward`
- Production monitoring changes

Use this document when answering:

> How do you know what the cluster is doing after deployment?

---

### Installation and Operations

[**installation.md**](installation.md)

Provides the platform runbook.

Topics include:

- Prerequisites
- AWS authentication
- Terraform state bootstrap
- Infrastructure provisioning
- Jenkins configuration
- Kubernetes validation
- Application deployment
- HPA validation
- Cluster Autoscaler validation
- GitHub Actions OIDC
- Argo CD setup
- Prometheus and Grafana
- Security validation
- Teardown
- Identity offboarding

Use this document when answering:

> How would another engineer reproduce or operate this environment?

---

### Interview Story Bank

[**interview.md**](interview.md)

Contains interview-ready engineering stories based on real problems and decisions encountered while building the platform.

Examples include:

- Remediating a real IAM least-privilege finding
- Rejecting an unnecessary scanner remediation
- Security controls creating new security findings
- Why `Resource: "*"` is not automatically excessive privilege
- Compensating controls and residual risk
- Trivy vendored-package investigation
- AWS IAM authentication vs Kubernetes authorization
- Why the Flask application has no AWS role
- Why GitHub Actions has no EKS deployment authority
- Jenkins versus Argo CD
- Terraform versus Cluster Autoscaler ownership
- HPA resource-request behavior
- SSM instead of SSH
- NHI lifecycle and offboarding

This document is intended for interview preparation rather than platform operation.

---

## Evidence

Implementation evidence is stored under:

```text
evidence/
├── infrastructure/
├── application/
├── security/
├── autoscaling/
├── cicd/
├── gitops/
└── observability/
```

Evidence is collected to support meaningful engineering claims rather than to record every command executed.

### Infrastructure Evidence

`evidence/infrastructure/`

Examples include:

- EKS node readiness
- Private-node validation
- EKS control-plane logging
- Metrics Server

### Application Evidence

`evidence/application/`

Examples include:

- Kubernetes workload state
- Service validation
- Ingress reconciliation
- ALB address assignment
- Public application validation
- Health endpoint validation

### Security Evidence

`evidence/security/`

Examples include:

- Non-root container execution
- Read-only root filesystem
- Writable `/tmp`
- Application ServiceAccount with no AWS role
- No automatically mounted ServiceAccount token
- Jenkins Kubernetes RBAC boundary
- Cluster Autoscaler identity
- AWS Load Balancer Controller identity
- Ansible execution-role assumption
- SSM-managed Jenkins host
- Jenkins and Argo CD Git identity separation

### Autoscaling Evidence

`evidence/autoscaling/`

Demonstrates:

- HPA baseline
- HPA scale-out
- Maximum replicas
- HPA scale-in
- Cluster Autoscaler operation
- Node scale-out
- Node scale-in

### CI/CD Evidence

`evidence/cicd/`

Primary evidence includes successful Jenkins pipeline execution covering:

- Checkout
- AWS identity
- Checkov
- Docker build
- Trivy
- ECR
- EKS authentication
- Helm deployment
- Rollout verification
- Live application test

### GitOps Evidence

`evidence/gitops/`

Primary evidence includes:

- Successful GitHub Actions GitOps run
- Argo CD components running
- Argo CD Synced / Healthy
- Live EKS image matching Git desired state

### Observability Evidence

`evidence/observability/`

Primary evidence includes:

- Monitoring workload resource metrics
- Grafana displaying live Kubernetes telemetry

---

## Key Engineering Themes

The documents in this directory collectively demonstrate several recurring engineering principles.

### Identity boundaries

```text
Git identity
    !=
AWS identity


AWS authentication
    !=
Kubernetes authorization


Kubernetes ServiceAccount
    !=
AWS IAM role
```

### Controller ownership

```text
Terraform
    -> infrastructure definition


Cluster Autoscaler
    -> runtime node demand


GitHub Actions
    -> artifact production + desired-state update


Argo CD
    -> Kubernetes reconciliation
```

### Least privilege

Least privilege is evaluated through effective authority rather than simply avoiding wildcard syntax.

### Workload identity

A workload receives a cloud identity only when it actually needs cloud API authority.

### Security validation

Controls are tested with evidence, including denied actions, rather than inferred solely from configuration.

---

## Recommended Reviewer Paths

### Hiring Manager

Read:

- [`../README.md`](../README.md)
- [`architecture.md`](architecture.md)
- [`security-model.md`](security-model.md)
- [`nhi-governance-inventory.md`](nhi-governance-inventory.md)

Then review the strongest screenshots under:

- `evidence/cicd/`
- `evidence/gitops/`
- `evidence/security/`

### Cloud / Platform Engineer

Read:

- [`architecture.md`](architecture.md)
- [`installation.md`](installation.md)
- [`cicd-pipeline.md`](cicd-pipeline.md)
- [`gitops.md`](gitops.md)
- [`autoscaling.md`](autoscaling.md)
- [`observability.md`](observability.md)

### Cloud Security / IAM Reviewer

Read:

- [`security-model.md`](security-model.md)
- [`nhi-governance-inventory.md`](nhi-governance-inventory.md)
- [`cicd-pipeline.md`](cicd-pipeline.md)
- [`gitops.md`](gitops.md)

Then inspect:

- `evidence/security/`

### Interview Preparation

Read:

- [`interview.md`](interview.md)

Use the other documents only when deeper technical recall is needed.

---

## Project Thesis

The technical components in this platform are useful, but the larger design principle is the separation of authority.

```text
The application does not inherit AWS authority.

Jenkins does not inherit cluster-admin authority.

GitHub Actions does not inherit EKS deployment authority.

Argo CD does not inherit Git write authority.

AWS controllers receive workload-specific identities.

Terraform and runtime controllers have explicit ownership boundaries.
```

The platform is built around one recurring question:

> Who or what needs authority, why does it need that authority, and where should that authority stop?
