#!/usr/bin/env python3
"""Small JSON queries used by upgrade-check.sh."""

import json
import sys


def load():
    return json.load(sys.stdin)


def zot_services(node_port):
    for service in load().get("items", []):
        metadata = service.get("metadata", {})
        spec = service.get("spec", {})
        for port in spec.get("ports", []) or []:
            if port.get("nodePort") == node_port:
                values = (
                    metadata.get("namespace", ""),
                    metadata.get("name", ""),
                    spec.get("type", ""),
                    port.get("port", ""),
                    port.get("targetPort", ""),
                    port.get("nodePort", ""),
                    port.get("protocol", "TCP"),
                )
                print("\t".join(str(value) for value in values))


def ready_endpoints():
    endpoints = [
        endpoint
        for item in load().get("items", [])
        for endpoint in item.get("endpoints", []) or []
    ]
    ready = sum(
        1
        for endpoint in endpoints
        if (endpoint.get("conditions", {}) or {}).get("ready") is not False
    )
    print("{}\t{}".format(ready, len(endpoints)))


def disk_pressure():
    for node in load().get("items", []):
        for condition in node.get("status", {}).get("conditions", []):
            if condition.get("type") == "DiskPressure" and condition.get("status") == "True":
                print(node.get("metadata", {}).get("name", "unknown"))


def server_version():
    print(load().get("serverVersion", {}).get("gitVersion", "unknown"))


def node_facts():
    nodes = load().get("items", [])
    labels = {
        key
        for node in nodes
        for key in (node.get("metadata", {}).get("labels", {}) or {})
    }
    provider_ids = [
        node.get("spec", {}).get("providerID", "").lower()
        for node in nodes
        if node.get("spec", {}).get("providerID")
    ]
    control_planes = sum(
        1
        for node in nodes
        if any(
            key in (node.get("metadata", {}).get("labels", {}) or {})
            for key in (
                "node-role.kubernetes.io/control-plane",
                "node-role.kubernetes.io/master",
            )
        )
    )
    return labels, provider_ids, control_planes


def cluster_type(version, context, cluster_name, api_server):
    labels, provider_ids, control_planes = node_facts()
    haystack = " ".join((version, context, cluster_name, api_server)).lower()

    def has_label(prefix):
        return any(key.startswith(prefix) for key in labels)

    # Managed-service markers are checked before generic cloud provider IDs.
    if "eks-anywhere" in haystack or has_label("anywhere.eks.amazonaws.com/"):
        result = (
            "unmanaged",
            "EKSA",
            "Amazon EKS Anywhere",
            "EKS Anywhere node or cluster metadata",
        )
    elif (
        "-eks-" in version.lower()
        or ":eks:" in cluster_name.lower()
        or ".eks.amazonaws.com" in api_server.lower()
        or has_label("eks.amazonaws.com/")
        or has_label("alpha.eksctl.io/")
    ):
        result = (
            "managed",
            "EKS",
            "Amazon EKS",
            "EKS API, version, or node-group metadata",
        )
    elif (
        ".azmk8s.io" in api_server.lower()
        or "-aks-" in version.lower()
        or has_label("kubernetes.azure.com/")
    ):
        result = (
            "managed",
            "AKS",
            "Azure Kubernetes Service",
            "AKS API, version, or node metadata",
        )
    elif (
        "-gke." in version.lower()
        or context.lower().startswith("gke_")
        or has_label("cloud.google.com/gke-")
    ):
        result = (
            "managed",
            "GKE",
            "Google Kubernetes Engine",
            "GKE version, context, or node metadata",
        )
    elif ".k8s.oci.oraclecloud.com" in api_server.lower() or has_label("oke.oraclecloud.com/"):
        result = (
            "managed",
            "OKE",
            "Oracle Kubernetes Engine",
            "OKE API or node metadata",
        )
    elif "k3s" in version.lower():
        result = ("unmanaged", "K3S", "Self-managed K3s", "K3s Kubernetes version")
    elif "rke2" in version.lower():
        result = ("unmanaged", "RKE2", "Self-managed RKE2", "RKE2 Kubernetes version")
    elif control_planes:
        result = (
            "unmanaged",
            "IAAS",
            "Self-managed Kubernetes / IaaS",
            f"{control_planes} visible control-plane node(s)",
        )
    elif any(value.startswith("aws://") for value in provider_ids):
        result = (
            "unmanaged",
            "IAAS_AWS",
            "Self-managed Kubernetes on AWS IaaS",
            "AWS provider IDs without EKS markers",
        )
    elif any(value.startswith("azure://") for value in provider_ids):
        result = (
            "unmanaged",
            "IAAS_AZURE",
            "Self-managed Kubernetes on Azure IaaS",
            "Azure provider IDs without AKS markers",
        )
    elif any(value.startswith("gce://") for value in provider_ids):
        result = (
            "unmanaged",
            "IAAS_GCP",
            "Self-managed Kubernetes on Google Cloud IaaS",
            "GCE provider IDs without GKE markers",
        )
    else:
        result = (
            "unknown",
            "UNKNOWN",
            "Unclassified Kubernetes",
            "No managed-service or visible control-plane markers",
        )

    print("\t".join(result))


def control_plane_count():
    _, _, count = node_facts()
    print(count)


def version_configmap():
    names = [item.get("metadata", {}).get("name", "") for item in load().get("items", [])]
    priorities = ("spectro-mgmt-version", "palette-version-info-for-webhook")
    for candidate in priorities:
        if candidate in names:
            print(candidate)
            return
    generated = sorted(name for name in names if name.startswith("version-info-"))
    if generated:
        print(generated[0])


def main():
    if len(sys.argv) < 2:
        return 2
    command = sys.argv[1]
    if command == "zot-services" and len(sys.argv) == 3:
        zot_services(int(sys.argv[2]))
    elif command == "ready-endpoints":
        ready_endpoints()
    elif command == "disk-pressure":
        disk_pressure()
    elif command == "server-version":
        server_version()
    elif command == "cluster-type" and len(sys.argv) == 6:
        cluster_type(*sys.argv[2:])
    elif command == "control-plane-count":
        control_plane_count()
    elif command == "version-configmap":
        version_configmap()
    else:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
