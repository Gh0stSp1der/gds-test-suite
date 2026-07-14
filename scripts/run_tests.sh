#!/bin/bash
# run_tests.sh
# GDS 전체 테스트 수행 스크립트
# read/write × xfertype(0/1/2) × 3회 반복 순차 실행
# 완료 후 config 수집 (collect_config.sh)
#
# Usage: bash run_tests.sh [RUN_ID]
#   RUN_ID: 결과 디렉토리 이름 (미입력 시 타임스탬프 자동 생성)
#
# Example:
#   bash run_tests.sh
#   bash run_tests.sh 20260714_test1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ═══════════════════════════════════════════
# 테스트 파라미터 (자주 바뀌지 않으므로 변수로 선언)
# ═══════════════════════════════════════════
BS="8M"           # Block size
THREADS=256       # Thread 수
DURATION=120      # 테스트 시간 (초)
CYCLES=3          # xfertype당 반복 횟수

# 테스트 대상 xfertype 목록 (0=GDS, 1=CPU, 2=CPU_GPU)
XFERTYPES=(0 1 2)

# 결과 저장 최상위 경로: 스크립트 위치 기준 상대경로
# 압축 후 다른 위치에 풀어도 자동으로 해당 위치 기준으로 동작
BASE_RESULT_DIR="${SCRIPT_DIR}/../results"

# ═══════════════════════════════════════════
# 실행 ID / 디렉토리 설정
# ═══════════════════════════════════════════
RUN_ID="${1:-$(date '+%Y%m%d_%H%M%S')}"
RUN_DIR="${BASE_RESULT_DIR}/${RUN_ID}"
LOG_FILE="${RUN_DIR}/run_tests.log"

mkdir -p "${RUN_DIR}"

# ─────────────────────────────────────────
# 로깅 함수: echo + 파일 동시 기록
# ─────────────────────────────────────────
log() {
    local msg="[$(date '+%H:%M:%S')] $*"
    echo "${msg}" | tee -a "${LOG_FILE}"
}

log_plain() {
    echo "$*" | tee -a "${LOG_FILE}"
}

# ─────────────────────────────────────────
# Ctrl+C 처리
# ─────────────────────────────────────────
cleanup() {
    echo ""
    log "[INTERRUPT] 중단됨 — 실행 중인 run_gdsio.sh 종료 중..."
    # 현재 실행 중인 run_gdsio.sh 자식 프로세스 종료
    jobs -p | xargs kill 2>/dev/null
    wait
    log "중단. 이미 완료된 결과는 ${RUN_DIR} 에 보존됨."
    exit 1
}
trap cleanup INT TERM

# ─────────────────────────────────────────
# xfertype 이름 매핑
# ─────────────────────────────────────────
xfer_name() {
    case "$1" in
        0) echo "GDS"     ;;
        1) echo "CPU"     ;;
        2) echo "CPU_GPU" ;;
    esac
}

# ─────────────────────────────────────────
# 전체 테스트 수 계산
# ─────────────────────────────────────────
TOTAL_RUNS=$(( 2 * ${#XFERTYPES[@]} * CYCLES ))   # read+write × xfertypes × cycles
DONE=0

# ─────────────────────────────────────────
# 헤더
# ─────────────────────────────────────────
log_plain ""
log_plain "╔══════════════════════════════════════════╗"
log_plain "║       GDS 벤치마크 테스트 시작            ║"
log_plain "╚══════════════════════════════════════════╝"
log_plain ""
log "실행 ID   : ${RUN_ID}"
log "결과 경로 : ${RUN_DIR}"
log "로그 파일 : ${LOG_FILE}"
log_plain ""
log "파라미터:"
log "  BS      = ${BS}"
log "  THREADS = ${THREADS}"
log "  DURATION= ${DURATION}s"
log "  CYCLES  = ${CYCLES}"
log "  XFER    = ${XFERTYPES[*]}  (0=GDS, 1=CPU, 2=CPU_GPU)"
log_plain ""
log "총 실행 수: ${TOTAL_RUNS}회 (READ ${#XFERTYPES[@]}×${CYCLES} + WRITE ${#XFERTYPES[@]}×${CYCLES})"
log_plain "──────────────────────────────────────────"

# 실행 시점 스크립트 스냅샷 저장
SNAP_DIR="${RUN_DIR}/_scripts_snapshot"
mkdir -p "${SNAP_DIR}"
cp -r "${SCRIPT_DIR}" "${SNAP_DIR}/scripts" 2>/dev/null
cp -r "${SCRIPT_DIR}/../conf" "${SNAP_DIR}/conf" 2>/dev/null
log "스크립트 스냅샷: ${SNAP_DIR}"

# ─────────────────────────────────────────
# 테스트 실행 함수
# ─────────────────────────────────────────
run_test() {
    local iotype=$1   # 0=read, 1=write
    local xfer=$2
    local cycle=$3
    local io_name xname

    [[ ${iotype} -eq 0 ]] && io_name="read" || io_name="write"
    xname=$(xfer_name "${xfer}")

    DONE=$((DONE + 1))
    local progress="[${DONE}/${TOTAL_RUNS}]"
    local test_label="${io_name}_xfer${xfer}_${xname}_c${cycle}"
    local outdir="${RUN_DIR}/${io_name}_xfer${xfer}_${xname}/c${cycle}"

    mkdir -p "${outdir}"

    log_plain ""
    log "${progress} ┌─────────────────────────────────────"
    log "${progress} │ ${test_label}"
    log "${progress} │ bs=${BS}  threads=${THREADS}  duration=${DURATION}s"
    log "${progress} └─────────────────────────────────────"

    # run_gdsio.sh 실행 (출력도 로그에 tee)
    bash "${SCRIPT_DIR}/run_gdsio.sh" \
        -d "${outdir}" \
        -x "${xfer}" \
        -I "${iotype}" \
        -b "${BS}" \
        -w "${THREADS}" \
        -T "${DURATION}" \
        2>&1 | tee -a "${LOG_FILE}"

    local rc=${PIPESTATUS[0]}
    if [[ ${rc} -eq 0 ]]; then
        # throughput.log에서 TOTAL 라인 추출해서 요약에 표시
        local total_line
        total_line=$(grep "TOTAL" "${outdir}/throughput.log" 2>/dev/null | tail -1)
        log "${progress} ✓ 완료: ${total_line:-결과 없음}"
    else
        log "${progress} ✗ 실패 (exit=${rc}): ${outdir}"
    fi
}

# ─────────────────────────────────────────
# READ 테스트
# ─────────────────────────────────────────
log_plain ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log " READ 테스트 시작"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for xfer in "${XFERTYPES[@]}"; do
    for cycle in $(seq 1 "${CYCLES}"); do
        run_test 0 "${xfer}" "${cycle}"
    done
done

# ─────────────────────────────────────────
# WRITE 테스트
# ─────────────────────────────────────────
log_plain ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log " WRITE 테스트 시작"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for xfer in "${XFERTYPES[@]}"; do
    for cycle in $(seq 1 "${CYCLES}"); do
        run_test 1 "${xfer}" "${cycle}"
    done
done

# ─────────────────────────────────────────
# config 수집
# ─────────────────────────────────────────
log_plain ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log " 시스템 config 수집 (collect_config.sh)"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
bash "${SCRIPT_DIR}/collect_config.sh" "${RUN_DIR}" 2>&1 | tee -a "${LOG_FILE}"

# ─────────────────────────────────────────
# 결과 요약
# ─────────────────────────────────────────
log_plain ""
log_plain "╔══════════════════════════════════════════╗"
log_plain "║           전체 테스트 완료               ║"
log_plain "╚══════════════════════════════════════════╝"
log_plain ""
log "결과 경로 : ${RUN_DIR}"
log "로그 파일 : ${LOG_FILE}"
log_plain ""
log "throughput 요약:"
log_plain "────────────────────────────────────────────────"
find "${RUN_DIR}" -name "throughput.log" | sort | while read -r f; do
    label=$(echo "${f}" | sed "s|${RUN_DIR}/||; s|/throughput.log||")
    total=$(grep "TOTAL" "${f}" 2>/dev/null | awk '{print $2, $3}')
    printf "  %-35s  %s\n" "${label}" "${total:-N/A}" | tee -a "${LOG_FILE}"
done
log_plain "────────────────────────────────────────────────"
log_plain ""
log "완료 시각: $(date '+%Y-%m-%d %H:%M:%S')"
