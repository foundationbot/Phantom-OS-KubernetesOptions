# /etc/k0s/k0s.yaml — template for bootstrap-managed fields.
#
# This file is NOT applied verbatim. It documents the SHAPE of what
# bootstrap-robot.sh phase 3 (cluster) writes to /etc/k0s/k0s.yaml. The
# actual rendering is done in scripts/bootstrap-robot.sh's
# _kubelet_reservation_apply, which:
#
#   1. Reads the existing /etc/k0s/k0s.yaml (or starts fresh from the
#      ClusterConfig skeleton below).
#   2. Splices/replaces only spec.workerProfiles[default] from
#      cpuIsolation.partitions in /etc/phantomos/host-config.yaml.
#   3. Preserves every other field — including any spec.api.address,
#      network, controllerManager, etc. that k0s's own
#      `k0s config create` defaults supply, plus operator hand-edits.
#   4. Writes atomically and only restarts k0scontroller when the
#      rendered content actually changed.
#
# Single-node controller+worker (`--enable-worker --single`) mode is
# what every robot in this fleet runs. The default `k0s controller`
# CLI arg passes `--profile default`, so the profile name MUST be
# "default" for the embedded kubelet to pick it up. Verified via
# `k0s controller --help`:
#     --profile string    worker profile to use on the node (default "default")
#
# Why we set these specific kubeletConfiguration fields:
#
#   cpuManagerPolicy: static
#     Required for kubelet to honor reservedSystemCPUs at all. With
#     policy=none (k0s default), kubepods.cpuset.cpus is left as the
#     full online set regardless of reservedSystemCPUs.
#
#   reservedSystemCPUs: <managed-cpus>
#     CPUs reserved AWAY from kubepods. Per Kubernetes docs:
#       "CPUs in this set are not eligible to be assigned to any
#        containers' cpuset.cpus."
#     So the value to put here is the union of cpu-isolation managed
#     partitions (the EtherCAT RT cores). With cpuIsolation.partitions
#     = [{cpus: "11-13"}], this becomes "11-13" and kubepods then
#     covers the inverse housekeeping range "0-10". Kubepods will not
#     try to schedule workloads on the isolated cores.
#
#   kubeReservedCgroup: ""
#     k0s defaults this to "system.slice". Kubernetes >= 1.32 rejects
#     the combination of (kubeReservedCgroup OR systemReservedCgroup)
#     with reservedSystemCPUs:
#       "invalid configuration: can't use reservedSystemCPUs
#        (--reserved-cpus) with systemReservedCgroup
#        (--system-reserved-cgroup) or kubeReservedCgroup
#        (--kube-reserved-cgroup)"
#     The empty string clears the inherited default so kubelet
#     validation passes. Kubelet's own --kube-reserved memory /
#     ephemeral-storage enforcement still works; only the cgroup-
#     scoped enforcement of those reservations is disabled.
#
# The bootstrap merge preserves every other field, so feel free to
# hand-edit /etc/k0s/k0s.yaml on the robot to add cluster-level
# config (api.address, network, controllerManager, extensions, etc.)
# — re-running bootstrap will not overwrite those.

apiVersion: k0s.k0sproject.io/v1beta1
kind: ClusterConfig
metadata:
  name: k0s

spec:
  workerProfiles:
    - name: default
      values:
        cpuManagerPolicy: static
        reservedSystemCPUs: "<MANAGED-CPUS>"   # rendered: union of
                                               # cpuIsolation.partitions[].cpus
        kubeReservedCgroup: ""
