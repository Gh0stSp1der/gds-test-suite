#!/bin/bash
# run_tests_cli.sh
# GDS 전체 테스트 실행 명령어 모음
#
# Usage: bash run_tests_cli.sh [RUN_ID]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_GDSIO="${SCRIPT_DIR}/run_gdsio.sh"
COLLECT_CONFIG="${SCRIPT_DIR}/collect_config.sh"

# ═══════════════════════════════════════════
# 테스트 파라미터
# ═══════════════════════════════════════════
CYCLES=3

READ_BS=8M
READ_THREADS=256
READ_DURATION=1200

WRITE_BS=2M
WRITE_THREADS=64
WRITE_DURATION=1200

BASE_DIR="${SCRIPT_DIR}/../results"
RUN_ID="${1:-$(date '+%Y%m%d_%H%M%S')}"
D="${BASE_DIR}/${RUN_ID}"

mkdir -p "${D}"
LOG="${D}/run_tests_cli.log"
tlog() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${LOG}"; }

tlog "로그 파일: ${LOG}"
tlog "결과 경로: ${D}"
tlog ""

SNAP_DIR="${D}/_scripts_snapshot"
mkdir -p "${SNAP_DIR}"
cp -r "${SCRIPT_DIR}" "${SNAP_DIR}/scripts" 2>/dev/null
cp -r "${SCRIPT_DIR}/../conf" "${SNAP_DIR}/conf" 2>/dev/null
tlog "스크립트 스냅샷: ${SNAP_DIR}"
tlog ""

trap 'echo ""; tlog "중단됨."; exit 1' INT TERM


# ════════════════════════════════════════════
# READ 테스트
# ════════════════════════════════════════════

# ────────────────────────────────────────────
# READ | GDS (xfertype=0)
# ────────────────────────────────────────────
for c in $(seq 1 ${CYCLES}); do
    tlog "READ GDS c${c}"
    "${RUN_GDSIO}" -d "${D}/read_xfer0_GDS/c${c}" -x 0 -I 0 -b ${READ_BS} -w ${READ_THREADS} -T ${READ_DURATION} 2>&1 | tee -a "${LOG}"
done

# ────────────────────────────────────────────
# READ | CPU_GPU (xfertype=2)
# ────────────────────────────────────────────
for c in $(seq 1 ${CYCLES}); do
    tlog "READ CPU_GPU c${c}"
    "${RUN_GDSIO}" -d "${D}/read_xfer2_CPU_GPU/c${c}" -x 2 -I 0 -b ${READ_BS} -w ${READ_THREADS} -T ${READ_DURATION} 2>&1 | tee -a "${LOG}"
done

# ────────────────────────────────────────────
# READ | CPU (xfertype=1)
# ────────────────────────────────────────────
for c in $(seq 1 ${CYCLES}); do
    tlog "READ CPU c${c}"
    "${RUN_GDSIO}" -d "${D}/read_xfer1_CPU/c${c}" -x 1 -I 0 -b ${READ_BS} -w ${READ_THREADS} -T ${READ_DURATION} 2>&1 | tee -a "${LOG}"
done


# ════════════════════════════════════════════
# WRITE 테스트
# ════════════════════════════════════════════

# ────────────────────────────────────────────
# WRITE | GDS (xfertype=0)
# ────────────────────────────────────────────
for c in $(seq 1 ${CYCLES}); do
    tlog "WRITE GDS c${c}"
    "${RUN_GDSIO}" -d "${D}/write_xfer0_GDS/c${c}" -x 0 -I 1 -b ${WRITE_BS} -w ${WRITE_THREADS} -T ${WRITE_DURATION} 2>&1 | tee -a "${LOG}"
done

# ────────────────────────────────────────────
# WRITE | CPU_GPU (xfertype=2)
# ────────────────────────────────────────────
for c in $(seq 1 ${CYCLES}); do
    tlog "WRITE CPU_GPU c${c}"
    "${RUN_GDSIO}" -d "${D}/write_xfer2_CPU_GPU/c${c}" -x 2 -I 1 -b ${WRITE_BS} -w ${WRITE_THREADS} -T ${WRITE_DURATION} 2>&1 | tee -a "${LOG}"
done

# ────────────────────────────────────────────
# WRITE | CPU (xfertype=1)
# ────────────────────────────────────────────
for c in $(seq 1 ${CYCLES}); do
    tlog "WRITE CPU c${c}"
    "${RUN_GDSIO}" -d "${D}/write_xfer1_CPU/c${c}" -x 1 -I 1 -b ${WRITE_BS} -w ${WRITE_THREADS} -T ${WRITE_DURATION} 2>&1 | tee -a "${LOG}"
done


# ════════════════════════════════════════════
# 시스템 config 수집
# ════════════════════════════════════════════
tlog "[CONFIG] 시스템 config 수집"
"${COLLECT_CONFIG}" "${D}" 2>&1 | tee -a "${LOG}"


# ════════════════════════════════════════════
# throughput 요약
# ════════════════════════════════════════════
tlog ""
tlog "════════════════════════════════════════"
tlog " throughput 요약"
tlog "════════════════════════════════════════"
find "${D}" -name "throughput.log" | sort | while read -r f; do
    label=$(echo "${f}" | sed "s|${D}/||; s|/throughput.log||")
    total=$(grep "TOTAL" "${f}" 2>/dev/null | awk '{print $2, $3}')
    printf "  %-35s  %s\n" "${label}" "${total:-N/A}" | tee -a "${LOG}"
done
tlog "════════════════════════════════════════"
tlog "완료: ${D}"
