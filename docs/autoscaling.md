# Autoscaling

## Purpose

The EKS platform implements two independent scaling mechanisms:

1. Horizontal Pod Autoscaling for application replicas
2. Cluster Autoscaling for worker-node capacity

These layers solve different capacity problems.

Related docs: [Architecture](architecture.md) · [Observability](observability.md) · [Security model](security-model.md) · [Installation](installation.md)

---

## Scaling Chain

```text
Application demand increases
          |
          v
Horizontal Pod Autoscaler
          |
          v
More application pods
          |
          | insufficient node capacity?
          v
Cluster Autoscaler
          |
          v
More EKS worker nodes
```

The reverse path occurs after demand falls.

---

## Scaling Architecture

```text
                    Application Load
                           |
                           v
                    Flask Deployment
                           |
                           v
                     Metrics Server
                           |
                           v
                Horizontal Pod Autoscaler
                     1 -> 3 replicas
                           |
                  pods need capacity
                           |
                           v
                   Kubernetes Scheduler
                           |
                  insufficient capacity
                           |
                           v
                   Cluster Autoscaler
                           |
                           v
                 EKS Managed Node Group
                     1 -> 4 nodes
```

---

## Horizontal Pod Autoscaler

The application HPA uses the Kubernetes `autoscaling/v2` API.

### Configuration

```text
Minimum replicas: 1
Maximum replicas: 3

CPU target:    50%
Memory target: 50%
```

The HPA evaluates application resource utilization against the resource requests defined for the container.

### Current Application Resources

```text
CPU request:     100m
CPU limit:       250m

Memory request:  256Mi
Memory limit:    384Mi
```

### Metrics Server

Metrics Server supplies the resource telemetry consumed by the HPA.

It provides Kubernetes resource metrics such as:

```text
Pod CPU
Pod memory
Node CPU
Node memory
```

Metrics Server was validated through commands such as:

```text
kubectl top nodes
kubectl top pods -n challenge-app
```

Without Metrics Server, the HPA would have no CPU or memory telemetry for resource-based scaling decisions.

### HPA Scale-Out Test

The application began with one replica.

Load was generated against the application until resource utilization exceeded the configured HPA target. The challenge load generator lives at `platform/tests/hpa-load-generator.yaml`.

Observed behavior:

```text
Initial:
1 pod

Under load:
1 -> 2 -> 3 pods
```

This demonstrated that Kubernetes could increase application capacity without a manual replica change.

### HPA Scale-In Test

After load generation stopped, utilization fell.

The HPA eventually reduced the application replicas:

```text
3 -> 2 -> 1
```

Scale-in is intentionally slower than scale-out.

Rapid scale-in can cause capacity to disappear during short dips in demand, so Kubernetes applies stabilization behavior before reducing replicas.

### Memory Utilization Finding

During the first HPA test, the application returned to low absolute memory usage but remained above the configured percentage target.

The reason was the relationship between actual memory consumption and the configured memory request.

The original memory request was:

```text
128Mi
```

A workload using roughly half or more of that request could remain above the 50% HPA target despite appearing small in absolute terms.

The request was revised to:

```text
256Mi
```

After the change, steady-state utilization aligned more closely with the workload's observed working set and HPA scale-in was demonstrated.

This test reinforced an operational point:

> HPA percentages are evaluated against resource requests, not against the node's total capacity.

Resource requests are part of scaling behavior, not merely scheduler hints.

---

## Cluster Autoscaler

Horizontal Pod Autoscaling can create more pods, but it cannot create new EC2 worker capacity.

Cluster Autoscaler handles that second problem.

### Node Group Configuration

The managed node group is configured as:

```text
Instance type: t3.small
Capacity type: ON_DEMAND

Minimum nodes: 1
Desired nodes: 1
Maximum nodes: 4
```

Cluster Autoscaler watches for pods that cannot be scheduled with the current worker capacity.

When required, it changes the node group's desired capacity.

### Cluster Autoscaler AWS Identity

Cluster Autoscaler receives a dedicated AWS IAM role through IRSA:

```text
eks-kubernetes-cicd-cluster-autoscaler-role
```

The trust relationship is restricted to:

```text
Namespace:      kube-system
ServiceAccount: cluster-autoscaler
```

Its scaling permissions include:

```text
autoscaling:SetDesiredCapacity
autoscaling:TerminateInstanceInAutoScalingGroup
```

Scaling actions use cluster ownership tags to restrict which Auto Scaling resources may be modified.

Discovery APIs use wildcard resource scope where AWS does not expose resource-level authorization.

### Terraform Ownership Boundary

Terraform creates the node group with:

```text
desired_size = 1
```

After creation, Terraform ignores changes to the runtime desired capacity:

```hcl
lifecycle {
  ignore_changes = [
    scaling_config[0].desired_size
  ]
}
```

This prevents Terraform and Cluster Autoscaler from competing over the same runtime value.

Ownership is split as follows:

```text
Terraform
    -> defines min/max node-group boundaries
    -> creates infrastructure


Cluster Autoscaler
    -> owns runtime desired node count
```

### Node Scale-Out Test

During load testing, application demand caused additional pod scheduling pressure.

Observed behavior:

```text
Initial:
1 worker node

Under scheduling pressure:
1 -> 2 worker nodes
```

The new node joined the cluster and provided capacity for Kubernetes workloads.

This demonstrated that pod scaling and infrastructure scaling were connected without being the same mechanism.

### Node Scale-In Test

After demand fell and excess workloads disappeared, Cluster Autoscaler later reduced worker capacity:

```text
2 -> 1 worker node
```

Node removal takes longer than pod scale-in.

Cluster Autoscaler waits before considering a node removable and must determine that its remaining workloads can run elsewhere.

This avoids aggressively terminating capacity during short workload fluctuations.

---

## Relationship Between HPA and Cluster Autoscaler

The two controllers operate independently.

```text
HPA asks:
"How many application replicas should exist?"

Cluster Autoscaler asks:
"Does the cluster have enough nodes to schedule the requested workloads?"
```

A healthy scaling chain looks like:

```text
Traffic increases
      |
      v
CPU / memory rises
      |
      v
HPA adds pods
      |
      v
Scheduler places pods
      |
      +---- capacity available ----> continue
      |
      +---- capacity unavailable
                     |
                     v
             Cluster Autoscaler
                     |
                     v
                 add node
```

Neither controller replaces the other.

---

## Security Boundary

The application does not receive AWS scaling permissions.

```text
Application workload
    -> no AWS role


Horizontal Pod Autoscaler
    -> Kubernetes resource controller


Cluster Autoscaler
    -> dedicated AWS IAM role
```

AWS infrastructure authority is granted only to the component that needs to modify AWS capacity.

---

## Evidence

Autoscaling evidence is stored under:

`docs/evidence/autoscaling/`

The evidence set demonstrates:

- HPA baseline
- HPA scale-out
- HPA maximum replicas
- HPA scale-in
- Cluster Autoscaler operation
- Node scale-out
- Node scale-in

Identity evidence for Cluster Autoscaler is stored under:

- `docs/evidence/security/cluster-autoscaler-identity.png`

Together, the screenshots demonstrate both workload scaling and infrastructure scaling.
