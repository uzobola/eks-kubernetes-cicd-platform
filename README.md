# Secure AWS EKS CI/CD and GitOps Platform

A security-focused Kubernetes delivery platform on AWS demonstrating two application delivery models:

**Traditional CI/CD**

```text
GitHub → Jenkins → ECR → Helm → Amazon EKS
```

**GitOps**

```text
GitHub Actions → AWS OIDC → ECR → Git → Argo CD → Amazon EKS
```

The platform combines Terraform-managed infrastructure, Kubernetes autoscaling,
security gates, workload identity controls, non-human identity governance, and
Prometheus/Grafana observability.

---

## Project Context

This project models a real application delivery platform rather than a
single-purpose Kubernetes deployment.

The engineering focus was:

- provisioning Amazon EKS and supporting AWS infrastructure
- securing CI/CD and GitOps identities
- separating build authority from deployment authority
- deploying private EKS worker nodes behind an Application Load Balancer
- validating workload and node autoscaling
- enforcing infrastructure and container security gates
- applying least privilege across AWS IAM and Kubernetes RBAC
- monitoring the running platform with Prometheus and Grafana
- treating non-human identities as governed lifecycle objects

A recurring design question was:

> **Who or what needs authority, why does it need that authority, and where should that authority stop?**

Start with the [Documentation Index](docs/README.md) for a guided path through architecture, security, CI/CD, GitOps, and operations.

---



## Architecture

```text
                              Internet
                                 |
                                 v
                    Application Load Balancer
                         Public Subnets
                           AZ-A / AZ-B
                                 |
                                 v
                        Kubernetes Ingress
                                 |
                                 v
                         ClusterIP Service
                                 |
                                 v
                         Flask Deployment
                        Private EKS Nodes
                           AZ-A / AZ-B
                                 |
                +----------------+----------------+
                |                                 |
                v                                 v
       Horizontal Pod Autoscaler           Cluster Autoscaler
             Metrics Server                Managed Node Group
               1 → 3 Pods                    1 → 4 Nodes
```



### Delivery Paths

```text
Traditional CI/CD

GitHub
   |
   v
Jenkins
   |
   +--> Checkov
   +--> Docker Build
   +--> Trivy
   +--> Amazon ECR
   +--> Helm
   +--> Amazon EKS
   +--> Rollout + Live Test
```

```text
GitOps

gitops branch
      |
      v
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

For the full platform design, see
[Architecture](docs/architecture.md).

---



## Branch Model


| Branch   | Delivery Model           |
| -------- | ------------------------ |
| `main`   | Jenkins CI/CD            |
| `gitops` | GitHub Actions + Argo CD |


The two branches demonstrate different deployment authority models.

**Jenkins** directly deploys the application with Helm.

**GitHub Actions** builds and publishes the artifact but has no EKS deployment
authority. Argo CD reconciles the GitOps branch into Kubernetes.

---



## Application

The containerized Flask application is located at:

```text
eks-kubernetes-cicd-platform/app/
```

Endpoints:

```text
/         Application
/health   Health check
```

Successful deployment displays:

```text
Congratulations Challenge Completed !
```

The application intentionally receives:

```text
AWS IAM role:                  none
AWS permissions:               none
automountServiceAccountToken:  false
```

It does not need to call AWS or Kubernetes APIs, so those credentials are not
provided.

---



## Security Highlights

The platform applies security controls across AWS, Kubernetes, containers,
CI/CD, and GitOps.

Key controls include:

- private EKS worker nodes
- restricted EKS API access
- SSM administration instead of inbound SSH
- IMDSv2
- EKS control-plane logging
- VPC Flow Logs
- Checkov infrastructure security gate
- Trivy HIGH/CRITICAL container security gate
- immutable ECR image tags
- non-root application container
- read-only root filesystem
- dropped Linux capabilities
- RuntimeDefault seccomp
- namespace-scoped Jenkins Kubernetes RBAC
- GitHub Actions OIDC federation
- separate Jenkins and Argo CD read-only Git identities
- dedicated IRSA roles for AWS controllers
- no AWS role for the Flask workload

Full details:

- [Security Model](docs/security-model.md)
- [Non-Human Identity Governance](docs/nhi-governance-inventory.md)

---



## Identity and Authority Model

```text
Flask application
    -> no AWS authority

Jenkins
    -> ECR publishing
    -> EKS authentication
    -> challenge-app deployment only

GitHub Actions
    -> ECR publishing
    -> desired-state update
    -> no EKS deployment authority

Argo CD
    -> Git read-only
    -> Kubernetes reconciliation

AWS Load Balancer Controller
    -> dedicated IRSA role

Cluster Autoscaler
    -> dedicated IRSA role

VPC CNI
    -> dedicated IRSA role
```

One of the platform's core security distinctions is:

> **AWS IAM authentication is not Kubernetes authorization.**

Jenkins was validated as able to update the application Deployment while being
denied node deletion and `kube-system` modification.

---



## Autoscaling

The platform implements both workload and infrastructure scaling.

### Horizontal Pod Autoscaler

```text
Minimum replicas: 1
Maximum replicas: 3
CPU target:       50%
Memory target:    50%
```

Validated:

```text
1 → 3 → 1 pods
```



### Cluster Autoscaler

```text
Instance type: t3.small

Minimum nodes: 1
Desired nodes: 1
Maximum nodes: 4
```

Validated:

```text
1 → 2 → 1 nodes
```

Terraform owns the node-group boundaries.

Cluster Autoscaler owns runtime desired capacity.

See [Autoscaling](docs/autoscaling.md).

---



## Observability

The monitoring stack includes:

```text
Prometheus
Prometheus Operator
Grafana
kube-state-metrics
node-exporter
```

Grafana displays live EKS node and pod CPU and memory telemetry.

Grafana remains internal and is accessed through `kubectl port-forward`.

See [Observability](docs/observability.md).

---



## Quick Start

Detailed provisioning and operating instructions are maintained in the
[Installation and Deployment Runbook](docs/installation.md).

High-level flow:

```text
1. Authenticate to AWS through AWS Vault
2. Bootstrap Terraform remote state
3. Provision AWS / EKS infrastructure
4. Configure Jenkins through Ansible + SSM
5. Validate Kubernetes controllers and application
6. Run Jenkins CI/CD
7. Validate HPA and Cluster Autoscaler
8. Configure GitHub Actions OIDC
9. Deploy Argo CD and validate GitOps reconciliation
10. Deploy Prometheus and Grafana
```

Do not treat this section as the executable runbook; use
`[docs/installation.md](docs/installation.md)` for commands and validation steps.

---



## Repository Structure

```text
.
├── .github/
│   └── workflows/
│
├── eks-kubernetes-cicd-platform/
│   └── app/
│       ├── app.py
│       ├── Dockerfile
│       └── requirements.txt
│
├── helm/
│   └── challenge-app/
│
├── terraform/
│   ├── bootstrap/
│   └── infrastructure/
│
├── ansible/
│   ├── playbooks/
│   ├── inventory/
│   └── roles/
│
├── platform/
│   ├── argocd/
│   ├── namespaces/
│   ├── observability/
│   ├── rbac/
│   └── tests/
│
├── docs/
│   ├── README.md
│   ├── architecture.md
│   ├── installation.md
│   ├── cicd-pipeline.md
│   ├── gitops.md
│   ├── autoscaling.md
│   ├── observability.md
│   ├── security-model.md
│   ├── nhi-governance-inventory.md
│   ├── interview.md
│   └── evidence/
│
├── Jenkinsfile
└── README.md
```

Validate this tree against the current repository before final submission:

```bash
tree -L 3 -I '.git|.terraform'
```

---



## Documentation


| Document                                           | Purpose                                        |
| -------------------------------------------------- | ---------------------------------------------- |
| [Documentation Index](docs/README.md)              | Guide to all technical documentation           |
| [Architecture](docs/architecture.md)               | Platform design and component relationships    |
| [Installation](docs/installation.md)               | Provisioning, validation, operations, teardown |
| [Jenkins CI/CD](docs/cicd-pipeline.md)             | Traditional deployment pipeline                |
| [GitOps](docs/gitops.md)                           | GitHub Actions + Argo CD model                 |
| [Autoscaling](docs/autoscaling.md)                 | HPA and Cluster Autoscaler                     |
| [Observability](docs/observability.md)             | Prometheus and Grafana                         |
| [Security Model](docs/security-model.md)           | Trust boundaries, controls, residual risk      |
| [NHI Governance](docs/nhi-governance-inventory.md) | Machine identity inventory and lifecycle       |
| [Interview Story Bank](docs/interview.md)          | Engineering decisions and lessons              |


---



## Evidence

Evidence is organized by engineering claim:

```text
docs/evidence/
├── infrastructure/
├── application/
├── security/
├── autoscaling/
├── cicd/
├── gitops/
└── observability/
```



### Jenkins CI/CD

Jenkins pipeline

### GitOps

Argo CD synced and healthy

### Observability

Grafana Kubernetes metrics

---



## Validated Outcomes

```text
Private EKS worker nodes                         PASS
Application behind AWS ALB                      PASS
Application health endpoint                     PASS

HPA 1 → 3 → 1                                   PASS
Cluster Autoscaler 1 → 2 → 1                    PASS

Checkov 276 passed / 0 failed                   PASS
Trivy HIGH/CRITICAL gate                        PASS

Jenkins full CI/CD pipeline                     PASS
Namespace-scoped Jenkins RBAC                   PASS

GitHub Actions OIDC authentication              PASS
Immutable ECR publication                       PASS
Git desired-state update                        PASS
Argo CD Synced / Healthy                        PASS
Live EKS image matched Git desired state        PASS

Prometheus metrics                              PASS
Grafana Kubernetes telemetry                    PASS
```

---



## Production Direction

This implementation models a secure engineering environment but is not presented
as production-complete.

Production improvements would include:

- ACM-backed HTTPS
- private Jenkins controller
- isolated or ephemeral build agents
- container image signing and provenance verification
- admission policies
- persistent or managed monitoring storage
- enterprise Grafana authentication
- stronger egress controls
- centralized secret management
- automated NHI discovery and access review
- formal security-exception expiration and review

---



## Engineering Takeaway

The strongest property of the platform is not any single AWS or Kubernetes
control.

It is the separation of authority.

```text
Terraform owns infrastructure definition.

Cluster Autoscaler owns runtime node demand.

Jenkins can deploy the application without becoming cluster-admin.

GitHub Actions can publish artifacts without gaining EKS deployment authority.

Argo CD can reconcile Kubernetes without gaining Git write authority.

AWS controllers receive workload-specific cloud identities.

The application receives no AWS identity when it does not need one.
```

> **Secure automation means giving each identity enough authority to perform its
> job, proving where that authority stops, and removing the trust relationship
> when the identity is no longer needed.**

