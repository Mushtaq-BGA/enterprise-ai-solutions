#!/usr/bin/env bash
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# Compute NUMA-balanced reserved CPU list for kubelet reservedSystemCPUs.
# Prints a cpuset string, e.g. "0-3,64-67" for a 2-NUMA-node system.
# Usage: generate_reserved_cpus.sh <total_cpus_to_reserve>
set -euo pipefail

RESERVE_TOTAL="${1:-8}"

if ! command -v lscpu &>/dev/null; then
    echo "0,1"
    exit 0
fi

NUM_NUMA=$(lscpu | awk '/^NUMA node\(s\):/ {print $3}')

if [[ -z "$NUM_NUMA" || "$NUM_NUMA" -eq 0 ]]; then
    echo "0,1"
    exit 0
fi

# Never reserve the whole machine. The caller's reservation is sized for a
# typical server (4 single-node / 8 multi-node), but a heterogeneous cluster can
# include a small worker where that is most or all of its CPUs — kubelet then
# has nothing allocatable and every pod stays Pending. Cap at half the CPUs
# (minimum 1) so the node always keeps a usable pool.
TOTAL_CPUS=$(lscpu | awk '/^CPU\(s\):/ {print $2; exit}')
if [[ "$TOTAL_CPUS" =~ ^[0-9]+$ ]] && [[ "$TOTAL_CPUS" -gt 0 ]]; then
    MAX_RESERVE=$(( TOTAL_CPUS / 2 ))
    [[ "$MAX_RESERVE" -lt 1 ]] && MAX_RESERVE=1
    if [[ "$RESERVE_TOTAL" -gt "$MAX_RESERVE" ]]; then
        echo "generate_reserved_cpus.sh: capping reservation ${RESERVE_TOTAL} -> ${MAX_RESERVE} on a ${TOTAL_CPUS}-CPU node" >&2
        RESERVE_TOTAL="$MAX_RESERVE"
    fi
fi

RESERVE_PER_NUMA=$(( RESERVE_TOTAL / NUM_NUMA ))

if [[ "$RESERVE_PER_NUMA" -eq 0 ]]; then
    if [[ "$RESERVE_TOTAL" -eq 1 ]]; then
        echo "0"
    else
        echo "0-$(( RESERVE_TOTAL - 1 ))"
    fi
    exit 0
fi

RESERVED_CPUS=""
for i in $(seq 0 $(( NUM_NUMA - 1 ))); do
    NUMA_RANGE=$(lscpu | awk -v n="$i" '/^NUMA node[0-9]+ CPU\(s\):/ && $0 ~ "NUMA node"n" " {split($0,a,":"); gsub(/^[[:space:]]+|[[:space:]]+$/, "", a[2]); print a[2]}')
    NUMA_START=$(echo "$NUMA_RANGE" | sed 's/[,\-].*//')
    NUMA_END=$(( NUMA_START + RESERVE_PER_NUMA - 1 ))
    if [[ "$RESERVE_PER_NUMA" -eq 1 ]]; then
        RANGE="$NUMA_START"
    else
        RANGE="${NUMA_START}-${NUMA_END}"
    fi
    RESERVED_CPUS="${RESERVED_CPUS:+${RESERVED_CPUS},}${RANGE}"
done

echo "$RESERVED_CPUS"
