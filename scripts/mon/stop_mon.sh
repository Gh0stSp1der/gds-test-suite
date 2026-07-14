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

    # /tmp/mon_*.pid 파일 전체 읽어서 kill
    ssh "${host}" "
        for pidfile in /tmp/mon_*.pid; do
            [ -f \"\${pidfile}\" ] || continue
            pid=\$(cat \"\${pidfile}\" 2>/dev/null)
            if [ -n \"\${pid}\" ] && kill -0 \"\${pid}\" 2>/dev/null; then
                kill \"\${pid}\" 2>/dev/null
            fi
            rm -f \"\${pidfile}\"
        done
    " 2>/dev/null
    log "  ${host}: 프로세스 종료"

    # 잠시 대기 (마지막 로그 flush)
    sleep 1

    # 로그 수집 (/tmp/mon_*.log → monitor_dir/<hostname>/)
    ssh "${host}" "ls /tmp/mon_*.log 2>/dev/null" 2>/dev/null \
    | while read -r remote_log; do
        fname=$(basename "${remote_log}")
        # mon_<type>.log → <type>.log
        local_name="${fname#mon_}"
        scp -q "${host}:${remote_log}" "${outdir}/${local_name}" 2>/dev/null \
            && ssh "${host}" "rm -f ${remote_log}" 2>/dev/null \
            && log "  ${host}: ${local_name} 수집 완료"
    done
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
