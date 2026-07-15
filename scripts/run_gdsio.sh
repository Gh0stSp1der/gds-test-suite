#!/bin/bash
# run_gdsio.sh
# gdsio 테스트 실행 wrapper — 전체 GPU 서버 동시 실행, 모니터링, 결과 취합
#
# Usage: bash run_gdsio.sh -d <output_dir> -x <xfertype> -I <iotype> [OPTIONS]
#
# Required:
#   -d <dir>     결과 저장 디렉토리
#   -x <0|1|2>   XferType: 0=GDS, 1=CPU, 2=CPU_GPU
#   -I <0|1>     IoType: 0=Read, 1=Write
#
# Optional (기본값은 상단 변수 참조):
#   -b <bs>      Block size    (기본: 8M)
#   -w <n>       Thread 수     (기본: 256)
#   -T <sec>     실행 시간     (기본: 120)
#   -h           도움말

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="${SCRIPT_DIR}/../conf"
HOSTS_CONF="${CONF_DIR}/hosts.conf"
MON_DIR="${SCRIPT_DIR}/mon"
GDSIO="/usr/local/cuda-12.9/gds/tools/gdsio"
FILE_BASE="/mnt/gds"

# ─────────────────────────────────────────
# 기본값 변수 (run_tests.sh에서도 일관되게 사용)
# ─────────────────────────────────────────
DEFAULT_BS="8M"
DEFAULT_THREADS=256
DEFAULT_DURATION=120
DEFAULT_FILE_SIZE="8G"   # create_files.sh FILE_SIZE와 일치시켜야 함. "" 로 설정 시 -s 옵션 생략

# NUMA 바인딩: H100 NVL / A100 모두 NUMA 1에 GPU와 NIC이 위치
# numactl --cpunodebind=1 --membind=1 로 CPU/메모리를 NUMA 1에 고정
NUMACTL="numactl --cpunodebind=1 --membind=1"

# ─────────────────────────────────────────
# hosts.conf 로드
# ─────────────────────────────────────────
if [[ ! -f "${HOSTS_CONF}" ]]; then
    echo "ERROR: hosts.conf 없음: ${HOSTS_CONF}"; exit 1
fi
source "${HOSTS_CONF}"
GPU_HOSTS_ARR=($GPU_HOSTS)
STORAGE_HOSTS_ARR=($STORAGE_HOSTS)

# ─────────────────────────────────────────
# 인자 파싱
# ─────────────────────────────────────────
OUTDIR="" XFERTYPE="" IOTYPE=""
BS="${DEFAULT_BS}" THREADS="${DEFAULT_THREADS}" DURATION="${DEFAULT_DURATION}" FILE_SIZE="${DEFAULT_FILE_SIZE}"

usage() {
    grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'; exit 0
}

while getopts "d:x:I:b:w:T:s:h" opt; do
    case "${opt}" in
        d) OUTDIR="$OPTARG"     ;;
        x) XFERTYPE="$OPTARG"   ;;
        I) IOTYPE="$OPTARG"     ;;
        b) BS="$OPTARG"         ;;
        w) THREADS="$OPTARG"    ;;
        T) DURATION="$OPTARG"   ;;
        s) FILE_SIZE="$OPTARG"  ;;
        h) usage                ;;
        *) echo "ERROR: -h 로 도움말 확인"; exit 1 ;;
    esac
done

# 필수 인자
[[ -z "${OUTDIR}"   ]] && { echo "ERROR: -d <output_dir> 필수"; exit 1; }
[[ -z "${XFERTYPE}" ]] && { echo "ERROR: -x <0|1|2> 필수 (0=GDS, 1=CPU, 2=CPU_GPU)"; exit 1; }
[[ -z "${IOTYPE}"   ]] && { echo "ERROR: -I <0|1> 필수 (0=Read, 1=Write)"; exit 1; }

case "${XFERTYPE}" in
    0) XFER_NAME="GDS"     ;;
    1) XFER_NAME="CPU"     ;;
    2) XFER_NAME="CPU_GPU" ;;
    *) echo "ERROR: xfertype 은 0/1/2 중 하나"; exit 1 ;;
esac
case "${IOTYPE}" in
    0) IO_NAME="READ"  ;;
    1) IO_NAME="WRITE" ;;
    *) echo "ERROR: iotype 은 0(Read) 또는 1(Write)"; exit 1 ;;
esac

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ─────────────────────────────────────────
# Ctrl+C / 종료 시 정리 (trap)
# ─────────────────────────────────────────
cleanup() {
    echo ""
    log "[INTERRUPT] 중단 감지 — 정리 중..."

    # 원격 gdsio 프로세스 종료
    for host in "${GPU_HOSTS_ARR[@]}"; do
        ssh "${host}" "pkill -f gdsio 2>/dev/null; true" &
    done
    wait

    # 모니터링 종료
    bash "${MON_DIR}/stop_mon.sh" "${MONITOR_DIR}" 2>/dev/null

    # 로컬 백그라운드 프로세스 종료
    for pid in "${BGPIDS[@]}"; do
        kill "${pid}" 2>/dev/null
    done

    log "정리 완료. 종료."
    exit 1
}
trap cleanup INT TERM

# ─────────────────────────────────────────
# 디렉토리 생성
# ─────────────────────────────────────────
MONITOR_DIR="${OUTDIR}/monitor"
mkdir -p "${OUTDIR}" "${MONITOR_DIR}"
for h in "${GPU_HOSTS_ARR[@]}" "${STORAGE_HOSTS_ARR[@]}"; do
    mkdir -p "${MONITOR_DIR}/${h}"
done

THROUGHPUT_LOG="${OUTDIR}/throughput.log"

log "========================================"
log " run_gdsio 시작"
log " xfertype : ${XFERTYPE} (${XFER_NAME})"
log " iotype   : ${IOTYPE} (${IO_NAME})"
log " bs       : ${BS}  threads: ${THREADS}  duration: ${DURATION}s  filesize: ${FILE_SIZE}"
log " numactl  : ${NUMACTL}"
log " nodes    : ${GPU_HOSTS_ARR[*]}"
log " output   : ${OUTDIR}"
log "========================================"

# ─────────────────────────────────────────
# 모니터링 시작
# ─────────────────────────────────────────
log "[MON] 모니터링 시작"
bash "${MON_DIR}/start_mon.sh" "${MONITOR_DIR}"

# ─────────────────────────────────────────
# gdsio 동시 실행
# ─────────────────────────────────────────
log "[RUN] gdsio 실행 (${#GPU_HOSTS_ARR[@]}개 노드 동시)"
declare -A BGPIDS

for host in "${GPU_HOSTS_ARR[@]}"; do
    ssh "${host}" "
        ${NUMACTL} ${GDSIO} \
            -D ${FILE_BASE}/${host} \
            -d 0 \
            -w ${THREADS} \
            ${FILE_SIZE:+-s ${FILE_SIZE}} \
            -i ${BS} \
            -x ${XFERTYPE} \
            -I ${IOTYPE} \
            -T ${DURATION} 2>&1
    " > "${OUTDIR}/gdsio_${host}.log" 2>&1 &
    BGPIDS[${host}]=$!
    log "  ${host}: bg PID=${BGPIDS[${host}]}"
done

# ─────────────────────────────────────────
# 완료 대기
# ─────────────────────────────────────────
log "[WAIT] 완료 대기 중... (예상 ~$((DURATION + 15))초)"
for host in "${GPU_HOSTS_ARR[@]}"; do
    wait "${BGPIDS[${host}]}" && log "  ${host}: 완료" \
        || log "  ${host}: WARNING exit code $?"
done

# ─────────────────────────────────────────
# 모니터링 종료
# ─────────────────────────────────────────
log "[MON] 모니터링 종료"
bash "${MON_DIR}/stop_mon.sh" "${MONITOR_DIR}"

# ─────────────────────────────────────────
# throughput 취합
# ─────────────────────────────────────────
log "[RESULT] throughput 취합"
{
    echo "========================================"
    echo " GDS Benchmark Results"
    echo " $(date '+%Y-%m-%d %H:%M:%S')"
    echo " xfertype : ${XFERTYPE} (${XFER_NAME})"
    echo " iotype   : ${IOTYPE} (${IO_NAME})"
    echo " bs       : ${BS}"
    echo " threads  : ${THREADS}"
    echo " duration : ${DURATION}s"
    echo " nodes    : ${GPU_HOSTS_ARR[*]}"
    echo "========================================"
    echo ""

    TOTAL=0; NODE_COUNT=0; FAIL_COUNT=0

    for host in "${GPU_HOSTS_ARR[@]}"; do
        TPUT=$(grep -oP 'Throughput:\s*\K[0-9.]+' "${OUTDIR}/gdsio_${host}.log" | tail -1)
        if [[ -n "${TPUT}" ]]; then
            printf "  %-12s  %7s GiB/s\n" "${host}" "${TPUT}"
            TOTAL=$(awk "BEGIN {printf \"%.2f\", ${TOTAL} + ${TPUT}}")
            NODE_COUNT=$((NODE_COUNT + 1))
        else
            printf "  %-12s  ERROR — 로그 확인: %s\n" "${host}" "${OUTDIR}/gdsio_${host}.log"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    done

    echo ""
    echo "----------------------------------------"
    printf "  TOTAL         %7s GiB/s  (%d nodes)\n" "${TOTAL}" "${NODE_COUNT}"
    [[ ${FAIL_COUNT} -gt 0 ]] && echo "  WARNING: ${FAIL_COUNT}개 노드 실패"
    echo "========================================"
} | tee "${THROUGHPUT_LOG}"

log "결과: ${THROUGHPUT_LOG}"
log "모니터링: ${MONITOR_DIR}/"
log "완료"
