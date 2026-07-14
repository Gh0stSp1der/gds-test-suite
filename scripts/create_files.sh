#!/bin/bash
# create_files.sh
# GPU 서버별 /mnt/<hostname>/ 에 gdsio.0~255 파일 순차 생성
#
# Usage: bash create_files.sh [OPTIONS]
#
# Options:
#   --nodes "h1 h2 ..."   대상 호스트 직접 지정 (기본: hosts.conf의 GPU_HOSTS)
#   --skip-existing       이미 존재하는 파일은 건너뜀 (중단 후 재시작 시 유용)
#   -y, --yes             실행 전 확인 프롬프트 생략 (자동화 스크립트에서 호출 시)
#   -h, --help            도움말 출력
#
# 파일 생성 규칙:
#   - 경로: /mnt/<hostname>/gdsio.0 ~ gdsio.255
#   - 크기: 16GB per file (총 256 × 16GB = 4TB per node)
#   - 방식: gdsio CPU I/O (xfer=1), bs=16M, 단일 스레드 (w=1)
#   - 순서: 노드별 순차, 파일별 순차 → ZFS NVMe sequential write 보장
#
# --skip-existing 설명:
#   파일 생성 도중 중단됐을 때 재시작하는 용도.
#   이미 생성된 파일은 건너뛰고 누락된 파일만 생성함.
#   단, 크기 검증은 하지 않으므로 불완전한 파일이 있으면 수동 삭제 후 재실행 필요.

CONF_DIR="$(dirname "$0")/../conf"
HOSTS_CONF="${CONF_DIR}/hosts.conf"

# ─────────────────────────────────────────
# 상수
# ─────────────────────────────────────────
GDSIO="/usr/local/cuda-12.9/gds/tools/gdsio"
FILE_SIZE="8G"
BS="16M"
NUM_FILES=256          # gdsio.0 ~ gdsio.255
MOUNT_BASE="/mnt/gds"

# ─────────────────────────────────────────
# hosts.conf 로드 (없으면 --nodes 필수)
# ─────────────────────────────────────────
HOSTS_FROM_CONF=()
if [[ -f "${HOSTS_CONF}" ]]; then
    source "${HOSTS_CONF}"
    HOSTS_FROM_CONF=($GPU_HOSTS)
fi

# ─────────────────────────────────────────
# 인자 파싱
# ─────────────────────────────────────────
SKIP_EXISTING=0
AUTO_YES=0
CUSTOM_HOSTS=()

usage() {
    sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage ;;
        --nodes)
            [[ -z "$2" ]] && { echo "ERROR: --nodes 뒤에 호스트 목록 필요"; exit 1; }
            IFS=' ' read -r -a CUSTOM_HOSTS <<< "$2"; shift 2 ;;
        --skip-existing)
            SKIP_EXISTING=1; shift ;;
        -y|--yes)
            AUTO_YES=1; shift ;;
        *)
            echo "ERROR: 알 수 없는 옵션: $1"
            echo "       -h 또는 --help 로 도움말 확인"
            exit 1 ;;
    esac
done

# 대상 호스트 결정
if [[ ${#CUSTOM_HOSTS[@]} -gt 0 ]]; then
    TARGET_HOSTS=("${CUSTOM_HOSTS[@]}")
elif [[ ${#HOSTS_FROM_CONF[@]} -gt 0 ]]; then
    TARGET_HOSTS=("${HOSTS_FROM_CONF[@]}")
else
    echo "ERROR: 대상 호스트가 없습니다."
    echo "       hosts.conf 가 없으면 --nodes 옵션으로 직접 지정하세요."
    echo "       예: --nodes \"io500-1 io500-2 io500-3\""
    exit 1
fi

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ─────────────────────────────────────────
# Ctrl+C 시 원격 gdsio 정리
# ─────────────────────────────────────────
cleanup() {
    echo ""
    log "[INTERRUPT] 중단 감지 — 원격 gdsio 종료 중..."
    for host in "${TARGET_HOSTS[@]}"; do
        ssh "${host}" "pkill -f gdsio 2>/dev/null; true" &
    done
    wait
    log "정리 완료. --skip-existing 옵션으로 재시작 가능."
    exit 1
}
trap cleanup INT TERM

# ─────────────────────────────────────────
# 사전 점검
# ─────────────────────────────────────────
log "=== 사전 점검 ==="
log "대상 노드: ${TARGET_HOSTS[*]}"
log "파일 수:   ${NUM_FILES}개 × ${FILE_SIZE} = $((NUM_FILES * 16))GB per node"
[[ ${SKIP_EXISTING} -eq 1 ]] && log "모드: 기존 파일 건너뜀 (--skip-existing)"

for host in "${TARGET_HOSTS[@]}"; do
    if ! ssh -o ConnectTimeout=5 "${host}" "test -d ${MOUNT_BASE}" 2>/dev/null; then
        echo "ERROR: ${host}: ${MOUNT_BASE} 없음 또는 SSH 접속 불가 → 중단"
        exit 1
    fi
    if ! ssh "${host}" "test -x ${GDSIO}" 2>/dev/null; then
        echo "ERROR: ${host}: gdsio 실행 파일 없음 (${GDSIO}) → 중단"
        exit 1
    fi
done
log "사전 점검 완료"

# ─────────────────────────────────────────
# 실행 확인
# ─────────────────────────────────────────
TOTAL_SIZE_TB=$(echo "scale=1; ${#TARGET_HOSTS[@]} * ${NUM_FILES} * 16 / 1024" | bc)
echo ""
echo "  생성 예정: ${#TARGET_HOSTS[@]}개 노드 × ${NUM_FILES}개 × 16GB"
echo "  총 용량:   약 ${TOTAL_SIZE_TB} TB"
echo "  저장 경로: ${MOUNT_BASE}/<hostname>/gdsio.0~$((NUM_FILES-1))"
echo ""

if [[ ${AUTO_YES} -eq 0 ]]; then
    read -r -p "파일 생성을 시작하시겠습니까? [y/N] " confirm
    case "${confirm}" in
        [yY]|[yY][eE][sS]) ;;
        *) echo "취소됨."; exit 0 ;;
    esac
fi
echo ""

# ─────────────────────────────────────────
# 파일 생성 (노드별 순차, 파일별 순차)
# ─────────────────────────────────────────
TOTAL_SUCCESS=0
TOTAL_FAIL=0

for host in "${TARGET_HOSTS[@]}"; do
    TARGET_DIR="${MOUNT_BASE}/${host}"
    log "────────────────────────────────────"
    log "노드: ${host}  →  ${TARGET_DIR}"
    log "────────────────────────────────────"

    ssh "${host}" "mkdir -p ${TARGET_DIR}" 2>/dev/null

    NODE_SUCCESS=0
    NODE_FAIL=0

    for i in $(seq 0 $((NUM_FILES - 1))); do
        FPATH="${TARGET_DIR}/gdsio.${i}"

        if ssh "${host}" "test -f ${FPATH}" 2>/dev/null; then
            if [[ ${SKIP_EXISTING} -eq 1 ]]; then
                log "  [skip] gdsio.${i}"
                NODE_SUCCESS=$((NODE_SUCCESS + 1))
                continue
            fi
        fi

        log "  [$(printf '%3d' $((i+1)))/${NUM_FILES}] gdsio.${i} 생성 중..."

        RESULT=$(ssh "${host}" "
            ${GDSIO} -f ${FPATH} -w 1 -s ${FILE_SIZE} -i ${BS} -x 1 -I 1 2>&1 | \
            grep -E 'Throughput|[Ee]rror'
        " 2>/dev/null)

        FILE_OK=$(ssh "${host}" "test -f ${FPATH} && echo ok" 2>/dev/null)

        if [[ "${FILE_OK}" == "ok" ]]; then
            TPUT=$(echo "${RESULT}" | grep -oP 'Throughput: \K[0-9.]+')
            log "  [ OK ] gdsio.${i}  ${TPUT:+(${TPUT} GiB/s)}"
            NODE_SUCCESS=$((NODE_SUCCESS + 1))
        else
            log "  [FAIL] gdsio.${i}  ${RESULT}"
            NODE_FAIL=$((NODE_FAIL + 1))
        fi
    done

    log "${host} 완료: 성공 ${NODE_SUCCESS}개 / 실패 ${NODE_FAIL}개"
    echo ""
    TOTAL_SUCCESS=$((TOTAL_SUCCESS + NODE_SUCCESS))
    TOTAL_FAIL=$((TOTAL_FAIL + NODE_FAIL))
done

log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "전체 완료: 성공 ${TOTAL_SUCCESS}개 / 실패 ${TOTAL_FAIL}개"

if [[ ${TOTAL_FAIL} -gt 0 ]]; then
    log "WARNING: 실패한 파일이 있습니다."
    log "  재실행: bash $(basename "$0") --skip-existing"
    exit 1
fi
