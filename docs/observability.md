# Observability

## Purpose

The platform includes Prometheus and Grafana for Kubernetes infrastructure and workload visibility.

The monitoring stack answers questions such as:

```text
How much CPU are workloads consuming?
How much memory are workloads consuming?
Which pods are using resources?
How much worker-node capacity remains?
Is Kubernetes telemetry reaching the monitoring system?
```

The goal for this project is operational visibility into the running EKS environment rather than a full production monitoring platform.

> What does Prometheus do that Metrics Server does not?

Metrics Server supplies lightweight current resource metrics for `kubectl top` and HPA decisions. Prometheus collects broader time-series telemetry for dashboards and operational analysis.

Related docs: [Architecture](architecture.md) · [Autoscaling](autoscaling.md) · [Security model](security-model.md) · [Installation](installation.md)

---

## Monitoring Architecture

```text
EKS Nodes and Pods
        |
        +------------------+
        |                  |
        v                  v
 node-exporter      kube-state-metrics
        |                  |
        +--------+---------+
                 |
                 v
             Prometheus
                 |
                 v
              Grafana
                 |
                 v
        Kubernetes Dashboards
```

---

## Monitoring Stack

The stack uses the Prometheus Community `kube-prometheus-stack` Helm chart, pinned at chart version `88.3.0` during install.

Installed components include:

```text
Prometheus
Prometheus Operator
Grafana
kube-state-metrics
Prometheus node-exporter
```

Alertmanager is disabled for this challenge.

Challenge values live in:

```text
platform/observability/kube-prometheus-stack-values.yaml
```

Install and access steps are documented in [Installation](installation.md).

---

## Prometheus

Prometheus collects and stores time-series metrics from Kubernetes and monitoring exporters.

The challenge profile uses:

```text
Retention: 6 hours

CPU request:    200m
Memory request: 512Mi

CPU limit:      500m
Memory limit:   768Mi
```

The short retention period keeps the monitoring footprint small for the challenge environment.

Production monitoring would normally use persistent storage, longer retention, or a remote metrics platform.

### Prometheus Operator

Prometheus Operator manages Prometheus-related Kubernetes resources.

The operator provides Kubernetes-native management for the monitoring stack rather than requiring manual Prometheus configuration for each component.

Its challenge resource profile is kept small:

```text
CPU request:    50m
Memory request: 100Mi

CPU limit:      200m
Memory limit:   200Mi
```

### kube-state-metrics

kube-state-metrics exposes metrics derived from Kubernetes object state.

Examples include information about:

```text
Deployments
Pods
Nodes
Replica counts
Resource requests
Resource limits
Kubernetes object state
```

This complements direct host and container resource metrics.

### node-exporter

Prometheus node-exporter runs across cluster nodes and exposes host-level resource telemetry.

Examples include:

```text
CPU
Memory
Filesystem
Network
Node resource capacity
```

The node-exporter DaemonSet provides visibility into worker-node behavior.

### EKS Control Plane Metrics

The monitoring configuration disables direct scraping for:

```text
etcd
kube-controller-manager
kube-scheduler
```

These control-plane components are managed by Amazon EKS and are not exposed in the same way as self-managed Kubernetes control planes.

EKS control-plane visibility is handled through AWS-managed services and the EKS control-plane logs enabled elsewhere in the platform.

---

## Grafana

Grafana provides visualization for the metrics collected by Prometheus.

The project keeps Grafana behind a Kubernetes ClusterIP Service.

It is not exposed with a public load balancer.

Access is performed locally through port-forward (with the project AWS/kubeconfig identity as documented in Installation):

```bash
kubectl -n monitoring port-forward \
  svc/monitoring-grafana \
  3000:80
```

The interface is then available at:

```text
http://localhost:3000
```

This keeps the challenge dashboard from becoming another publicly reachable service.

> Why wasn't Grafana publicly exposed?

It is an administrative monitoring interface, not part of the public application. The service stays ClusterIP-only and is reached locally with `kubectl port-forward`.

### Grafana Authentication

The Grafana administrator password is generated and stored in a Kubernetes Secret.

It is retrieved only when needed for local access.

The password is not committed to Git and should not appear in evidence screenshots.

### Dashboard Validation

The monitoring stack was validated using the Grafana dashboard:

```text
Kubernetes / Compute Resources / Node (Pods)
```

The dashboard displayed live metrics for the EKS cluster, including:

```text
Node CPU capacity
Pod CPU usage
CPU requests
CPU limits
Node memory capacity
Pod memory usage
```

Argo CD workloads were visible in the telemetry, confirming that Grafana was displaying metrics from actual running cluster workloads rather than static sample data.

### Dashboard Refresh Behavior

Grafana dashboards were initially configured to refresh every 10 seconds.

This caused frequent panel redraws during testing.

For evidence capture, automatic refresh was disabled to keep the dashboard stable.

The behavior was a dashboard refresh setting rather than loss of telemetry.

---

## Command-Line Validation

Monitoring pod presence and resource usage were checked with:

```text
kubectl top pods -n monitoring
```

Observed components included:

```text
monitoring-grafana
monitoring-kube-prometheus-operator
monitoring-kube-state-metrics
monitoring-prometheus-node-exporter
prometheus-monitoring-kube-prometheus-prometheus-0
```

CPU and memory values were returned for the running monitoring workloads.

`kubectl top` uses Metrics Server (`metrics.k8s.io`), not the Prometheus scrape path. It confirms that monitoring pods are running and report resource usage; Grafana and Prometheus remain the time-series validation path for dashboards.

See [Autoscaling](autoscaling.md) for the Metrics Server role in HPA decisions.

---

## Resource-Conscious Monitoring

The EKS node group uses `t3.small` workers, so the monitoring installation was intentionally constrained.

The challenge configuration uses bounded CPU and memory resources for:

```text
Grafana
Prometheus
Prometheus Operator
kube-state-metrics
node-exporter
```

Alertmanager is disabled.

Grafana persistence is disabled.

Prometheus retention is limited to six hours.

These settings keep the monitoring implementation suitable for a short-lived demonstration cluster.

---

## Production Changes

A production monitoring design would likely introduce controls such as:

- Persistent Prometheus storage
- Longer metric retention
- Remote-write or managed metrics storage
- Grafana persistence
- SSO or enterprise authentication
- TLS
- Restricted ingress or private access
- Alertmanager
- Alert routing
- Backup and recovery
- Monitoring for the monitoring platform itself

Those controls are outside the scope of this challenge implementation.

---

## Security Boundary

The monitoring stack is treated as an internal platform service.

```text
Grafana
    -> ClusterIP
    -> local port-forward access


Prometheus
    -> internal cluster service


Application
    -> no monitoring administration authority
```

The project does not expose Grafana directly to the Internet.

---

## Evidence

Primary observability evidence:

- `docs/evidence/observability/monitoring-resource-metrics.png`
- `docs/evidence/observability/grafana-kubernetes-metrics.png`

The first screenshot demonstrates live monitoring pod resource metrics from Kubernetes.

The second demonstrates Grafana rendering real CPU and memory telemetry from the EKS cluster.

Together they support the claim that the observability stack is deployed, collecting data, and presenting usable Kubernetes metrics.
