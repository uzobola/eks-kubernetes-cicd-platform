# Architecture

## Overview

This project implements a containerized Flask application on Amazon EKS with two delivery models:

1. A traditional Jenkins CI/CD pipeline that builds, scans, publishes, and deploys the application with Helm.
2. A GitOps pipeline where GitHub Actions builds and publishes the image, Git records the desired state, and Argo CD reconciles that state into EKS.

The platform is designed around private worker nodes, explicit workload identities, least-privileged automation, automated scaling, security gates, and operational visibility.

---

## Platform Layers

| Layer | Location | Responsibility |
| ----- | -------- | -------------- |
| Bootstrap | `terraform/bootstrap` | Remote state bucket and lock foundation |
| Infrastructure | `terraform/infrastructure` | VPC, EKS, ECR, Jenkins, IAM, OIDC, Flow Logs |
| Jenkins config | `ansible/` | Toolchain and Jenkins setup over SSM (no SSH) |
| App delivery | `helm/challenge-app`, `Jenkinsfile`, `.github/workflows` | Build, scan, publish, deploy / desired state |
| Platform manifests | `platform/` | Namespace, RBAC, Argo CD app, observability values |

Day-0 creates durable AWS foundations. Day-1 configures the controller and cluster add-ons. Day-2 delivers the application through Jenkins and/or GitOps.

Related docs: [CI/CD](cicd-pipeline.md), [GitOps](gitops.md), [Security](security-model.md), [NHI inventory](nhi-governance-inventory.md), [Observability](observability.md), [Autoscaling](autoscaling.md), [Installation](installation.md).

---

## High-Level Architecture

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
                 +-----------------+-----------------+
                 |                                   |
                 v                                   v
         Horizontal Pod Autoscaler            Cluster Autoscaler
              Metrics Server                  Managed Node Group
                1 -> 3 Pods                     1 -> 4 Nodes

```

The EKS worker nodes run only in private subnets. Public application traffic enters through an internet-facing Application Load Balancer managed by the AWS Load Balancer Controller.

The application itself does not receive AWS permissions.

---

## Trust Boundaries

```text
                    +------------------+
  Humans / MFA ---> | Terraform admin  |  broad infra change
                    +------------------+
                              |
                    +------------------+
  Git (deploy key)->| Jenkins EC2 role |  ECR + namespace deploy
                    +--------+---------+
                             | Helm
                             v
                    +------------------+
  gitops + OIDC --->| GitHub Actions   |  ECR publish only
                    +--------+---------+
                             | commit values.yaml
                             v
                    +------------------+
  Git (deploy key)->| Argo CD          |  reconcile Helm to EKS
                    +--------+---------+
                             |
                             v
  Internet ---> ALB (public) ---> Ingress ---> Service ---> Pods (private)
                                                      |
                                                      x  no AWS IAM / no IRSA
```

Credentials are short-lived or role-based (instance profile, OIDC, IRSA). Static AWS keys are not used for Jenkins or GitHub Actions.

---

## Network Architecture

The VPC spans two Availability Zones and contains:

- Two public subnets
- Two private subnets
- An Internet Gateway
- NAT Gateways for private-subnet outbound access
- Route tables for public and private traffic
- EKS worker nodes in private subnets
- An internet-facing Application Load Balancer in public networking
- A restricted EKS API endpoint with private access enabled

The EKS public API endpoint is restricted to the administrator CIDR. Jenkins reaches the private EKS endpoint over TCP 443 through a security-group-to-security-group rule.

---

## Kubernetes Architecture

The application runs in the challenge-app namespace.

Primary Kubernetes resources include:

- Deployment
- ClusterIP Service
- Ingress
- HorizontalPodAutoscaler
- ServiceAccount

The Flask container listens on port 8080.

The Service exposes port 80 internally and forwards traffic to port 8080.

The Ingress uses the AWS Load Balancer Controller to provision the public Application Load Balancer.

The application exposes:

```text
/        Application response
/health  Health endpoint
```

The health endpoint is used by Kubernetes probes and the Application Load Balancer.

---

## Scaling Architecture

The platform implements two independent scaling layers.

### Pod Scaling

Metrics Server supplies CPU and memory telemetry to the Horizontal Pod Autoscaler.

The HPA is configured with:

```text
Minimum replicas: 1
Maximum replicas: 3
CPU target:       50%
Memory target:    50%
```

The HPA scales application pods based on workload demand.

### Node Scaling

The EKS managed node group is configured with:

```text
Minimum nodes: 1
Desired nodes: 1
Maximum nodes: 4
Instance type: t3.small
```

Cluster Autoscaler increases node capacity when pods cannot be scheduled and removes excess capacity when it is no longer required.

Terraform ignores changes to the node group's desired capacity after creation so that Cluster Autoscaler can own that runtime value.

---

## Traditional CI/CD Path

```text
GitHub
   |
   v
Jenkins
   |
   +--> AWS Identity Preflight
   |
   +--> Checkov
   |
   +--> Docker Build
   |
   +--> Trivy Security Gate
   |
   +--> Amazon ECR
   |
   +--> EKS Authentication
   |
   +--> Helm Deployment
   |
   +--> Rollout Verification
   |
   +--> Live Application Test
```

Jenkins authenticates to GitHub with a repository-specific read-only deploy key.

Its AWS permissions are supplied through its EC2 instance role rather than static AWS access keys.

Jenkins receives Kubernetes deployment authority only within the challenge-app namespace through Kubernetes RBAC.

It does not receive cluster-administrator permissions.

---

## Jenkins Controller Provisioning

Jenkins EC2 is created by Terraform. Runtime tooling is installed with Ansible over AWS Systems Manager Session Manager and an S3 transport bucket — not SSH.

Ansible installs and validates Docker, kubectl, Helm, Trivy, and Checkov so the Jenkinsfile stages have a consistent agent toolchain.

---

## GitOps Path

```text
gitops branch
      |
      v
GitHub Actions
      |
      | OIDC
      v
AWS STS
      |
      +--> Docker Build
      |
      +--> Trivy Security Gate
      |
      +--> Amazon ECR
      |
      v
Update Git Desired State
      |
      v
Argo CD
      |
      v
Amazon EKS
```

GitHub Actions exchanges a GitHub OIDC token for short-lived AWS credentials.

No long-lived AWS access keys are stored in GitHub.

The GitHub Actions IAM role can publish application images to the project ECR repository but receives no EKS deployment authority.

After publishing an immutable image tag, the workflow updates the Helm values stored on the gitops branch.

Argo CD reads the private repository with a separate read-only deploy key and reconciles the Helm release into EKS.

This separates artifact production from cluster deployment:

```text
GitHub Actions -> produce artifact and update desired state
Argo CD        -> reconcile desired state
```

### Desired State Contract

The GitOps desired state for the application lives on the `gitops` branch in:

`helm/challenge-app/values.yaml`

GitHub Actions updates `image.repository` and `image.tag` after a successful publish. Argo CD syncs that Helm chart into the `challenge-app` namespace. Changing the running image means changing Git, not running `kubectl set image` by hand.

---

## Observability

The monitoring stack uses:

```text
Prometheus
Prometheus Operator
Grafana
kube-state-metrics
node-exporter
```

Prometheus collects cluster and workload telemetry.

Grafana provides Kubernetes dashboards for CPU, memory, node, and pod visibility.

Grafana is exposed only through local kubectl port-forward during this challenge rather than through a public load balancer.

---

## Security Architecture

Security controls are applied across several layers.

### Infrastructure

- Private EKS worker nodes
- Restricted EKS API access
- Encrypted storage
- VPC Flow Logs
- EKS control-plane logging
- Remote Terraform state protections
- No inbound SSH access to Jenkins
- Systems Manager used for Jenkins administration

### Container

The application container:

- Runs as non-root UID/GID 10001
- Prevents privilege escalation
- Uses a read-only root filesystem
- Drops Linux capabilities
- Uses RuntimeDefault seccomp
- Receives a writable /tmp volume only where needed
- Does not receive an automatically mounted Kubernetes service-account token

### Supply Chain

The delivery pipelines enforce:

```text
Checkov -> infrastructure security gate
Trivy   -> HIGH/CRITICAL container vulnerability gate
ECR     -> immutable image repository
```

### Identity

Automation identities are separated by function.

Examples include:

- Terraform execution role
- Jenkins EC2 role
- Jenkins Git deploy key
- GitHub Actions OIDC role
- Argo CD Git deploy key
- AWS Load Balancer Controller IRSA role
- Cluster Autoscaler IRSA role
- VPC CNI IRSA role

The application workload intentionally has no AWS IAM role.

### Identity Boundary

One design question used throughout the project is:

> Does this workload need an AWS identity at all?

For the Flask application, the answer is no.

The Kubernetes ServiceAccount provides workload identity inside Kubernetes, but it has:

```text
AWS IAM role:                  none
AWS permissions:               none
automountServiceAccountToken:  false
```

AWS permissions are granted only to components that need to call AWS APIs.

This reduces unnecessary non-human identity authority.

---

## Availability and Resilience

The design uses:

- Multiple Availability Zones
- Kubernetes self-healing
- Deployment health probes
- Horizontal Pod Autoscaling
- Cluster Autoscaling
- Application Load Balancer health checks
- Helm atomic deployments
- Rollout verification
- Live post-deployment tests

The infrastructure is designed to recover application capacity without depending on a single application pod or worker node.

---

## Intentional Non-Goals

For this challenge scope, the design deliberately does **not** include:

- Public Grafana or Argo CD UIs (local port-forward only)
- Application IRSA or AWS API access from the Flask workload
- Customer-managed KMS for every data store (AES256/SSE-S3 used where documented; KMS called out as hardening)
- A single shared deploy identity across Jenkins and GitHub Actions

---

## Failure Domains

| Failure | Impact | Mitigation in this design |
| ------- | ------ | ------------------------- |
| Single app pod | Brief capacity loss | HPA + Deployment self-heal |
| Single worker node | Pods reschedule | Multi-AZ node group + Cluster Autoscaler |
| Jenkins unavailable | Traditional path blocked | GitOps path still builds/publishes; Argo CD still syncs |
| Argo CD unavailable | GitOps sync paused | Jenkins path can still Helm deploy |
| NAT / AZ impairment | Private egress in that AZ affected | NAT Gateway per AZ |

---

## Deployment Models

The project intentionally demonstrates two delivery approaches.

| Capability                      | Jenkins CI/CD         | GitOps                 |
| ------------------------------- | --------------------- | ---------------------- |
| Source branch                   | `main`                | `gitops`               |
| Build image                     | Jenkins               | GitHub Actions         |
| Security scan                   | Trivy                 | Trivy                  |
| Push image                      | Jenkins               | GitHub Actions         |
| AWS authentication              | EC2 IAM role          | GitHub OIDC / STS      |
| Deployment mechanism            | Helm from Jenkins     | Argo CD reconciliation |
| Direct EKS deployment authority | Yes, namespace-scoped | GitHub Actions: No     |
| Desired state stored in Git     | No                    | Yes                    |
| Cluster reconciler              | No                    | Argo CD                |

Both delivery paths publish immutable application images to the same Amazon ECR repository.

The two models are demonstrated side by side for learning and comparison. Do not treat Jenkins Helm deploys and Argo CD auto-sync as simultaneous owners of the same release in normal operation — they can compete over desired state if both are actively changing the same workload.
