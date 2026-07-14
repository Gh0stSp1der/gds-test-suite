#!/bin/bash
# stop_mon.sh <monitor_dir>
# 모든 원격 모니터링 프로세스 종료 + 로그 수집
#
# Usage: bash stop_mon.sh <monitor_dir>

MONITOR_DIR="$1"
if [[ -z "${MONITOR_DIR}" ]]; then
    echo "ERROR: Usage: $0 <monitor_dir>"; exit 1
fi

CONF_DIR="$(cd "$(dirname "$0")/../../conf" && pwd)"
HOSTS_CONF="${CONF_DIR}/hosts.conf"

if [[ ! -f "${HOSTS_CONF}" ]]; then
    echo "ERROR: hosts.conf 없음: ${HOSTS_CONF}"; exit 1
fi
source "${HOSTS_CONF}"
GPU_HOSTS_ARR=($GPU_HOSTS)
STORAGE_HOSTS_ARR=($STORAGE_HOSTS)

log() { echo "[MON][$(date '+%H:%M:%S')] $*"; }

# ─────────────────────────────────────────
# 원격 프로세스 종료 + 로그 수집
# ─────────────────────────────────────────
stop_and_collect() {
    local host=$1
    local outdir="${MONITOR_DIR}/${host}"
    mkdir -p "${outdir}"

    # 단일 SSH 연결로: 프로세스 종료 + flush 대기 + tar 전송
    # 여러 scp 병렬 호출 대신 tar pipe 방식으로 SSH 연결 수 최소화
    ssh "${host}" "
        for pidfile in /tmp/mon_*.pid; do
            [ -f \"\${pidfile}\" ] || continue
            pid=\$(cat \"\${pidfile}\" 2>/dev/null)
            [ -n \"\${pid}\" ] && kill \"\${pid}\" 2>/dev/null
            rm -f \"\${pidfile}\"
        done
        sleep 2
        files=\$(ls /tmp/mon_*.log 2>/dev/null)
        [ -n \"\${files}\" ] && tar -cf - \${files} 2>/dev/null || true
    " 2>/dev/null | tar -xf - -C "${outdir}" --transform 's|.*/mon_||' 2>/dev/null

    local count
    count=$(ls "${outdir}"/*.log 2>/dev/null | wc -l)
    log "  ${host}: ${count}개 파일 수집 완료"

    # 원격 로그 파일 정리
    ssh "${host}" "rm -f /tmp/mon_*.log" 2>/dev/null
}

# ─────────────────────────────────────────
# 메인
# ─────────────────────────────────────────
log "모니터링 종료 + 로그 수집 시작"

ALL_HOSTS=("${GPU_HOSTS_ARR[@]}" "${STORAGE_HOSTS_ARR[@]}")
for host in "${ALL_HOSTS[@]}"; do
    log "── ${host}"
    stop_and_collect "${host}" &
done
wait

log "모니터링 로그 저장 완료 → ${MONITOR_DIR}"
echo ""
echo "저장된 파일:"
find "${MONITOR_DIR}" -type f -name "*.log" | sort | sed "s|${MONITOR_DIR}/||"
