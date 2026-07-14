#!/bin/bash
# run_tests_cli.sh
# GDS 전체 테스트 실행 명령어 모음
# run_gdsio.sh를 xfertype별, read/write별 3회씩 순차 실행
#
# Usage: bash run_tests_cli.sh [RUN_ID]
#   RUN_ID: 결과 하위 디렉토리 이름 (미입력 시 타임스탬프 자동)
#
# 결과: BASE_DIR/<RUN_ID>/<iotype>_xfer<n>_<name>/c<1~3>/

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_GDSIO="${SCRIPT_DIR}/run_gdsio.sh"
COLLECT_CONFIG="${SCRIPT_DIR}/collect_config.sh"

# ═══════════════════════════════════════════
# 테스트 파라미터
# ═══════════════════════════════════════════
BS=8M
THREADS=256
DURATION=120

# 결과 경로: 스크립트 위치 기준 상대경로
# 압축 후 다른 위치에 풀어도 자동으로 해당 위치 기준으로 동작
BASE_DIR="${SCRIPT_DIR}/../results"
RUN_ID="${1:-$(date '+%Y%m%d_%H%M%S')}"
D="${BASE_DIR}/${RUN_ID}"

# 로그 설정
mkdir -p "${D}"
LOG="${D}/run_tests_cli.log"
tlog() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${LOG}"; }

tlog "로그 파일: ${LOG}"
tlog "결과 경로: ${D}"
tlog ""

# 실행 시점 스크립트 스냅샷 저장 (이후 수정 시 추적 가능)
SNAP_DIR="${D}/_scripts_snapshot"
mkdir -p "${SNAP_DIR}"
cp -r "${SCRIPT_DIR}" "${SNAP_DIR}/scripts" 2>/dev/null
cp -r "${SCRIPT_DIR}/../conf" "${SNAP_DIR}/conf" 2>/dev/null
tlog "스크립트 스냅샷: ${SNAP_DIR}"
tlog ""

# Ctrl+C 처리
trap 'echo ""; tlog "중단됨."; exit 1' INT TERM


# ════════════════════════════════════════════
# READ 테스트
# ════════════════════════════════════════════

# ────────────────────────────────────────────
# READ | GDS (xfertype=0) | 3회
# ────────────────────────────────────────────
tlog "[1/18] READ GDS c1"
"${RUN_GDSIO}" -d "${D}/read_xfer0_GDS/c1" -x 0 -I 0 -b ${BS} -w ${THREADS} -T ${DURATION} 2>&1 | tee -a "${LOG}"

tlog "[2/18] READ GDS c2"
"${RUN_GDSIO}" -d "${D}/read_xfer0_GDS/c2" -x 0 -I 0 -b ${BS} -w ${THREADS} -T ${DURATION} 2>&1 | tee -a "${LOG}"

tlog "[3/18] READ GDS c3"
"${RUN_GDSIO}" -d "${D}/read_xfer0_GDS/c3" -x 0 -I 0 -b ${BS} -w ${THREADS} -T ${DURATION} 2>&1 | tee -a "${LOG}"

# ────────────────────────────────────────────
# READ | CPU (xfertype=1) | 3회
# ────────────────────────────────────────────
tlog "[4/18] READ CPU c1"
"${RUN_GDSIO}" -d "${D}/read_xfer1_CPU/c1" -x 1 -I 0 -b ${BS} -w ${THREADS} -T ${DURATION} 2>&1 | tee -a "${LOG}"

tlog "[5/18] READ CPU c2"
"${RUN_GDSIO}" -d "${D}/read_xfer1_CPU/c2" -x 1 -I 0 -b ${BS} -w ${THREADS} -T ${DURATION} 2>&1 | tee -a "${LOG}"

tlog "[6/18] READ CPU c3"
"${RUN_GDSIO}" -d "${D}/read_xfer1_CPU/c3" -x 1 -I 0 -b ${BS} -w ${THREADS} -T ${DURATION} 2>&1 | tee -a "${LOG}"

# ────────────────────────────────────────────
# READ | CPU_GPU (xfertype=2) | 3회
# ────────────────────────────────────────────
tlog "[7/18] READ CPU_GPU c1"
"${RUN_GDSIO}" -d "${D}/read_xfer2_CPU_GPU/c1" -x 2 -I 0 -b ${BS} -w ${THREADS} -T ${DURATION} 2>&1 | tee -a "${LOG}"

tlog "[8/18] READ CPU_GPU c2"
"${RUN_GDSIO}" -d "${D}/read_xfer2_CPU_GPU/c2" -x 2 -I 0 -b ${BS} -w ${THREADS} -T ${DURATION} 2>&1 | tee -a "${LOG}"

tlog "[9/18] READ CPU_GPU c3"
"${RUN_GDSIO}" -d "${D}/read_xfer2_CPU_GPU/c3" -x 2 -I 0 -b ${BS} -w ${THREADS} -T ${DURATION} 2>&1 | tee -a "${LOG}"


# ════════════════════════════════════════════
# WRITE 테스트
# ════════════════════════════════════════════

# ────────────────────────────────────────────
# WRITE | GDS (xfertype=0) | 3회
# ────────────────────────────────────────────
tlog "[10/18] WRITE GDS c1"
"${RUN_GDSIO}" -d "${D}/write_xfer0_GDS/c1" -x 0 -I 1 -b ${BS} -w ${THREADS} -T ${DURATION} 2>&1 | tee -a "${LOG}"

tlog "[11/18] WRITE GDS c2"
"${RUN_GDSIO}" -d "${D}/write_xfer0_GDS/c2" -x 0 -I 1 -b ${BS} -w ${THREADS} -T ${DURATION} 2>&1 | tee -a "${LOG}"

tlog "[12/18] WRITE GDS c3"
"${RUN_GDSIO}" -d "${D}/write_xfer0_GDS/c3" -x 0 -I 1 -b ${BS} -w ${THREADS} -T ${DURATION} 2>&1 | tee -a "${LOG}"

# ────────────────────────────────────────────
# WRITE | CPU (xfertype=1) | 3회
# ────────────────────────────────────────────
tlog "[13/18] WRITE CPU c1"
"${RUN_GDSIO}" -d "${D}/write_xfer1_CPU/c1" -x 1 -I 1 -b ${BS} -w ${THREADS} -T ${DURATION} 2>&1 | tee -a "${LOG}"

tlog "[14/18] WRITE CPU c2"
"${RUN_GDSIO}" -d "${D}/write_xfer1_CPU/c2" -x 1 -I 1 -b ${BS} -w ${THREADS} -T ${DURATION} 2>&1 | tee -a "${LOG}"

tlog "[15/18] WRITE CPU c3"
"${RUN_GDSIO}" -d "${D}/write_xfer1_CPU/c3" -x 1 -I 1 -b ${BS} -w ${THREADS} -T ${DURATION} 2>&1 | tee -a "${LOG}"

# ────────────────────────────────────────────
# WRITE | CPU_GPU (xfertype=2) | 3회
# ────────────────────────────────────────────
tlog "[16/18] WRITE CPU_GPU c1"
"${RUN_GDSIO}" -d "${D}/write_xfer2_CPU_GPU/c1" -x 2 -I 1 -b ${BS} -w ${THREADS} -T ${DURATION} 2>&1 | tee -a "${LOG}"

tlog "[17/18] WRITE CPU_GPU c2"
"${RUN_GDSIO}" -d "${D}/write_xfer2_CPU_GPU/c2" -x 2 -I 1 -b ${BS} -w ${THREADS} -T ${DURATION} 2>&1 | tee -a "${LOG}"

tlog "[18/18] WRITE CPU_GPU c3"
"${RUN_GDSIO}" -d "${D}/write_xfer2_CPU_GPU/c3" -x 2 -I 1 -b ${BS} -w ${THREADS} -T ${DURATION} 2>&1 | tee -a "${LOG}"


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
