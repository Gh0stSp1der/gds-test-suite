#!/bin/bash
# start_mon.sh <monitor_dir>
# 모든 GPU 서버 + 스토리지 서버에서 모니터링 시작
# 각 원격 호스트에 프로세스 실행 후 PID를 /tmp/mon_<type>.pid 에 저장
# 로그는 /tmp/mon_<type>.log 에 저장 → stop_mon.sh 에서 수집

MONITOR_DIR="$1"
if [[ -z "${MONITOR_DIR}" ]]; then
    echo "ERROR: Usage: $0 <monitor_dir>"; exit 1
fi

CONF_DIR="$(cd "$(dirname "$0")/../../conf" && pwd)"
HOSTS_CONF="${CONF_DIR}/hosts.conf"
# 원격 서버에 배포된 에이전트 스크립트 경로 (deploy_agents.sh로 배포)
AGENT_REMOTE_DIR="/root/thkim/scripts"
IB_BW="${AGENT_REMOTE_DIR}/ib-bw.sh"
POWER_MON="${AGENT_REMOTE_DIR}/power-mon.sh"

if [[ ! -f "${HOSTS_CONF}" ]]; then
    echo "ERROR: hosts.conf 없음: ${HOSTS_CONF}"; exit 1
fi
source "${HOSTS_CONF}"
GPU_HOSTS_ARR=($GPU_HOSTS)
STORAGE_HOSTS_ARR=($STORAGE_HOSTS)

log() { echo "[MON][$(date '+%H:%M:%S')] $*"; }

# ─────────────────────────────────────────
# 시작 전 잔여 프로세스/파일 정리
# ─────────────────────────────────────────
cleanup_remote() {
    local host=$1
    ssh "${host}" "
        for pidfile in /tmp/mon_*.pid; do
            [ -f \"\${pidfile}\" ] || continue
            pid=\$(cat \"\${pidfile}\" 2>/dev/null)
            [ -n \"\${pid}\" ] && kill \"\${pid}\" 2>/dev/null
            rm -f \"\${pidfile}\"
        done
        rm -f /tmp/mon_*.log 2>/dev/null
    " 2>/dev/null
}

# ─────────────────────────────────────────
# 원격 프로세스 시작 헬퍼
# nohup으로 실행, PID를 /tmp/mon_<type>.pid 에 저장
# ─────────────────────────────────────────
start_remote() {
    local host=$1
    local type=$2
    local cmd=$3
    ssh "${host}" "
        nohup bash -c '${cmd}' > /tmp/mon_${type}.log 2>&1 &
        echo \$! > /tmp/mon_${type}.pid
    " 2>/dev/null
    log "  ${host}: ${type} 시작"
}

# ─────────────────────────────────────────
# GPU 서버 모니터링
# ─────────────────────────────────────────
start_gpu_mon() {
    local host=$1

    # mpstat: CPU 코어별 사용률 (1초 간격, 전체 코어)
    start_remote "${host}" "mpstat" \
        "mpstat -P ALL 1"

    # nvidia-smi dmon: GPU SM utilization + FB memory (1초 간격)
    # 컬럼 설명 주석을 먼저 기록 후 dmon 데이터 append
    ssh "${host}" "
        cat > /tmp/mon_nvdmon.log << 'HEADER'
# nvidia-smi dmon -s um -d 1
# -s um : utilization + memory bandwidth
# -d 1  : 1초 간격
#
# 컬럼 설명:
#   gpu : GPU index
#   sm  : SM (CUDA core) utilization [%]
#   mem : FB memory bandwidth utilization [%]
#   enc : Video Encoder utilization [%]
#   dec : Video Decoder utilization [%]
#   jpg : JPEG Decoder utilization [%]
#   ofa : Optical Flow Accelerator utilization [%]
#
HEADER
        nohup nvidia-smi dmon -s um -d 1 >> /tmp/mon_nvdmon.log 2>&1 &
        echo \$! > /tmp/mon_nvdmon.pid
    " 2>/dev/null
    log "  ${host}: nvdmon 시작"

    # ib-bw.sh: IB NIC TX/RX 대역폭 (mlx5 디바이스)
    if ssh "${host}" "test -f ${IB_BW}" 2>/dev/null; then
        start_remote "${host}" "ib_bw" "bash ${IB_BW}"
    else
        log "  ${host}: ib-bw.sh 없음 (${IB_BW}) — 건너뜀"
    fi

    # power: CPU 패키지 전력 (RAPL, 1초 간격)
    if ssh "${host}" "test -f ${POWER_MON}" 2>/dev/null; then
        start_remote "${host}" "power" "bash ${POWER_MON}"
    fi

    # dstat: CPU/MEM/NET/DISK 종합 (1초 간격, 타임스탬프 포함)
    start_remote "${host}" "dstat" \
        "dstat -t -c --mem-adv -n -d 1"
}

# ─────────────────────────────────────────
# 스토리지 서버 모니터링
# ─────────────────────────────────────────
start_storage_mon() {
    local host=$1

    # mpstat: CPU 코어별 사용률 (1초 간격, 전체 코어)
    start_remote "${host}" "mpstat" \
        "mpstat -P ALL 1"

    # ib-bw.sh
    if ssh "${host}" "test -f ${IB_BW}" 2>/dev/null; then
        start_remote "${host}" "ib_bw" "bash ${IB_BW}"
    else
        log "  ${host}: ib-bw.sh 없음 — 건너뜀"
    fi

    # power: CPU 패키지 전력 (RAPL)
    if ssh "${host}" "test -f ${POWER_MON}" 2>/dev/null; then
        start_remote "${host}" "power" "bash ${POWER_MON}"
    fi

    # dstat
    start_remote "${host}" "dstat" \
        "dstat -t -c --mem-adv -n -d 1"

    # zpool iostat: pool I/O 통계 (1초 간격)
    start_remote "${host}" "zpool_iostat" \
        "zpool iostat -qv 1"

    # iostat: 디바이스별 I/O 통계 (1초 간격)
    start_remote "${host}" "iostat" \
        "iostat -mtxz 1"
}

# ─────────────────────────────────────────
# 메인
# ─────────────────────────────────────────
log "모니터링 시작 (출력: ${MONITOR_DIR})"

ALL_HOSTS=("${GPU_HOSTS_ARR[@]}" "${STORAGE_HOSTS_ARR[@]}")
for host in "${ALL_HOSTS[@]}"; do
    cleanup_remote "${host}"
done

for host in "${GPU_HOSTS_ARR[@]}"; do
    log "── GPU: ${host}"
    start_gpu_mon "${host}"
done

for host in "${STORAGE_HOSTS_ARR[@]}"; do
    log "── Storage: ${host}"
    start_storage_mon "${host}"
done

log "모니터링 시작 완료"
log "종료 시: bash stop_mon.sh ${MONITOR_DIR}"
