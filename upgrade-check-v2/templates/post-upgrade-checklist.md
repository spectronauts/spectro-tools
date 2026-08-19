# Palette VerteX Post-Upgrade Checklist

Complete this checklist before closing the maintenance window. Compare captured
values with `pre-upgrade-values.env` in the pre-upgrade artifact directory.

## 1. Platform health

- [ ] Confirm the installed VerteX version is the intended target.
- [ ] Confirm every node is `Ready`.
- [ ] Confirm all pods in `{{MGMT_NAMESPACE}}` are ready.
- [ ] Confirm there are no `CrashLoopBackOff`, `ImagePullBackOff`, or
      `ErrImagePull` pods anywhere in the cluster.
- [ ] Confirm all Palette Deployments and StatefulSets have their desired replicas.

```bash
kubectl get nodes
kubectl get pods -n {{MGMT_NAMESPACE}}
kubectl get pods -A
kubectl get deploy,statefulset -n {{MGMT_NAMESPACE}}
```

## 2. MongoDB and storage

- [ ] Confirm all `mongo-*` pods in `{{MONGO_NAMESPACE}}` are ready.
- [ ] Confirm the replica set has exactly one healthy primary.
- [ ] Confirm all PVCs are `Bound`.
- [ ] Confirm no nodes report `DiskPressure`.
- [ ] If Piraeus is installed, confirm every pod in `{{PIRAEUS_NAMESPACE}}` is ready.

```bash
kubectl get pods,pvc -n {{MONGO_NAMESPACE}}
kubectl get pvc -A
kubectl get nodes
kubectl get pods -n {{PIRAEUS_NAMESPACE}}
```

Use the approved MongoDB validation procedure for authenticated replica-set and
feature-compatibility checks. Do not change MongoDB feature compatibility unless
the applicable upgrade documentation explicitly requires it.

## 3. Certificates and ingress

- [ ] Confirm cert-manager and Traefik pods are ready.
- [ ] Confirm required custom TLS Secrets are still present.
- [ ] Reapply backed-up certificates if the upgrade replaced them.
- [ ] Confirm the Traefik LoadBalancer hostname or IP matches the captured value.
- [ ] Confirm DNS still resolves to the intended endpoint.

```bash
kubectl get pods -n cert-manager
kubectl get pods,svc -n ingress-traefik
kubectl get secrets -n {{MGMT_NAMESPACE}} --field-selector type=kubernetes.io/tls
```

## 4. Registries and connectivity

- [ ] Confirm the Zot Service still exposes NodePort `30003` and has ready endpoints.
- [ ] Confirm system- and tenant-level OCI, Helm, and Pack registries have no
      synchronization failures.
- [ ] Confirm in-cluster DNS resolution works.
- [ ] Confirm the Palette API health endpoint returns HTTP 200.

```bash
kubectl get svc -A
kubectl get endpointslices -A
```

## 5. Palette functional validation

- [ ] Sign in to the Palette UI.
- [ ] Confirm tenants and managed clusters are visible.
- [ ] Confirm edge clusters are connected and reporting status.
- [ ] Open representative cluster profiles and packs.
- [ ] Perform an approved workload or cluster lifecycle smoke test.

## 6. Recovery readiness

- [ ] Confirm the pre-upgrade artifact directory remains available and protected.
- [ ] Confirm the etcd/provider backup is retained and readable.
- [ ] Confirm the independently created MongoDB backup remains available.
- [ ] Confirm the LINSTOR passphrase backup is protected, when applicable.
- [ ] If rollback is required, stop and follow the documented procedure for the
      installed platform and exact source/target versions.

Do not improvise a database, etcd, or storage restore. Confirm the restore target,
backup timestamp, credentials, and impact with the platform owner first.
