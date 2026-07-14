#!/bin/bash
# deploy_agents.sh
# scripts/agent/ 하위 스크립트를 모든 GPU/스토리지 서버에 배포
#
# Usage: bash deploy_agents.sh [--check]
#   --check : 배포 없이 존재 여부만 확인

AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="${AGENT_DIR}/../../conf"
REMOTE_DIR="/root/thkim/scripts"

source "${CONF_DIR}/hosts.conf"
GPU_HOSTS_ARR=($GPU_HOSTS)
STORAGE_HOSTS_ARR=($STORAGE_HOSTS)
ALL_HOSTS=("${GPU_HOSTS_ARR[@]}" "${STORAGE_HOSTS_ARR[@]}")

CHECK_ONLY=0
[[ "${1}" == "--check" ]] && CHECK_ONLY=1

# 배포 대상 스크립트 (agent 디렉토리 내)
SCRIPTS=(
    "ib-bw.sh"
    "power-mon.sh"
)

log() { echo "[$(date '+%H:%M:%S')] $*"; }

deploy_to_host() {
    local host=$1
    local ok=0; local fail=0

    ssh "${host}" "mkdir -p ${REMOTE_DIR}" 2>/dev/null

    for script in "${SCRIPTS[@]}"; do
        local src="${AGENT_DIR}/${script}"
        local dst="${host}:${REMOTE_DIR}/${script}"

        if [[ ! -f "${src}" ]]; then
            echo "  [SKIP] ${script} — 로컬에 없음"
            continue
        fi

        if [[ "${CHECK_ONLY}" -eq 1 ]]; then
            if ssh "${host}" "test -f ${REMOTE_DIR}/${script}" 2>/dev/null; then
                echo "  [OK]   ${host}: ${script}"
            else
                echo "  [MISS] ${host}: ${script} — 없음"
                fail=$((fail+1))
            fi
        else
            if scp -q "${src}" "${dst}" 2>/dev/null; then
                echo "  [OK]   ${host}: ${script} 배포 완료"
                ok=$((ok+1))
            else
                echo "  [FAIL] ${host}: ${script} 배포 실패"
                fail=$((fail+1))
            fi
        fi
    done
}

if [[ "${CHECK_ONLY}" -eq 1 ]]; then
    log "=== 에이전트 스크립트 존재 확인 (${REMOTE_DIR}) ==="
else
    log "=== 에이전트 스크립트 배포 시작 → ${REMOTE_DIR} ==="
fi

for host in "${ALL_HOSTS[@]}"; do
    log "── ${host}"
    deploy_to_host "${host}"
done

log "완료"
