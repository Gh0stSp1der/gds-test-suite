#!/bin/bash
# collect_config.sh
# 모든 GPU 서버 + 스토리지 노드의 하드웨어/소프트웨어 설정 수집
#
# Usage: bash collect_config.sh <BASE_RESULT_DIR> [OPTIONS]
#   결과: BASE_RESULT_DIR/config/<hostname>/
#
# Options:
#   --gpu-nodes "h1 h2 ..."      GPU 서버 직접 지정 (hosts.conf 없을 때)
#   --storage-nodes "h1 h2 ..."  스토리지 서버 직접 지정 (hosts.conf 없을 때)
#
# Example:
#   bash collect_config.sh /root/thkim/tta_gds_root/results
#   bash collect_config.sh /tmp/out --gpu-nodes "io500-3 io500-4" --storage-nodes "aic1 aic2"

CONF_DIR="$(dirname "$0")/../conf"
HOSTS_CONF="${CONF_DIR}/hosts.conf"

# ─────────────────────────────────────────
# 인자 확인
# ─────────────────────────────────────────
if [[ -z "$1" ]]; then
    echo ""
    echo "ERROR: BASE_RESULT_DIR 인자가 필요합니다."
    echo ""
    echo "Usage: bash $(basename "$0") <BASE_RESULT_DIR>"
    echo ""
    echo "Example:"
    echo "  bash $(basename "$0") /root/thkim/tta_gds_root/results"
    echo ""
    exit 1
fi

BASE_RESULT_DIR="$1"
CONFIG_DIR="${BASE_RESULT_DIR}/config"

# ─────────────────────────────────────────
# 인자 파싱 (BASE_RESULT_DIR 이후 옵션)
# ─────────────────────────────────────────
CUSTOM_GPU_HOSTS=()
CUSTOM_STORAGE_HOSTS=()

shift  # BASE_RESULT_DIR 소비
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gpu-nodes)
            [[ -z "$2" ]] && { echo "ERROR: --gpu-nodes 뒤에 호스트 목록 필요"; exit 1; }
            IFS=' ' read -r -a CUSTOM_GPU_HOSTS <<< "$2"; shift 2 ;;
        --storage-nodes)
            [[ -z "$2" ]] && { echo "ERROR: --storage-nodes 뒤에 호스트 목록 필요"; exit 1; }
            IFS=' ' read -r -a CUSTOM_STORAGE_HOSTS <<< "$2"; shift 2 ;;
        *)
            echo "ERROR: 알 수 없는 옵션: $1"; exit 1 ;;
    esac
done

# ─────────────────────────────────────────
# hosts.conf 로드 (없으면 --gpu-nodes/--storage-nodes 필수)
# ─────────────────────────────────────────
GPU_HOSTS_ARR=()
STORAGE_HOSTS_ARR=()

if [[ -f "${HOSTS_CONF}" ]]; then
    source "${HOSTS_CONF}"
    GPU_HOSTS_ARR=($GPU_HOSTS)
    STORAGE_HOSTS_ARR=($STORAGE_HOSTS)
fi

# --gpu-nodes / --storage-nodes 가 있으면 덮어씀
[[ ${#CUSTOM_GPU_HOSTS[@]}     -gt 0 ]] && GPU_HOSTS_ARR=("${CUSTOM_GPU_HOSTS[@]}")
[[ ${#CUSTOM_STORAGE_HOSTS[@]} -gt 0 ]] && STORAGE_HOSTS_ARR=("${CUSTOM_STORAGE_HOSTS[@]}")

# 최종 확인
if [[ ${#GPU_HOSTS_ARR[@]} -eq 0 && ${#STORAGE_HOSTS_ARR[@]} -eq 0 ]]; then
    echo "ERROR: 대상 호스트가 없습니다."
    echo "       hosts.conf 가 없으면 --gpu-nodes / --storage-nodes 로 직접 지정하세요."
    exit 1
fi

GDSCHECK="/usr/local/cuda-12.9/gds/tools/gdscheck"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ─────────────────────────────────────────
# 공통 수집 함수 (GPU 서버 + 스토리지 모두)
# ─────────────────────────────────────────
collect_common() {
    local host=$1
    local outdir="${CONFIG_DIR}/${host}"
    mkdir -p "${outdir}"
    log "=== ${host} 수집 시작 ==="

    # OS / 커널 / 주요 패키지 버전
    {
        echo "=== OS / Kernel ==="
        ssh "${host}" "uname -a; cat /etc/os-release | grep -E 'NAME|VERSION_ID'" 2>/dev/null
        echo ""
        echo "=== Kernel 버전 ==="
        ssh "${host}" "uname -r" 2>/dev/null
        echo ""
        echo "=== Lustre 버전 ==="
        ssh "${host}" "rpm -q kmod-lustre kmod-lustre-client lustre lustre-client 2>/dev/null | grep -v 'not installed'" 2>/dev/null
        ssh "${host}" "lctl --version 2>/dev/null || lustre_rmmod --version 2>/dev/null || true" 2>/dev/null
        echo ""
        echo "=== ZFS 버전 ==="
        ssh "${host}" "rpm -q zfs kmod-zfs 2>/dev/null | grep -v 'not installed'" 2>/dev/null
        ssh "${host}" "zpool --version 2>/dev/null; zfs --version 2>/dev/null" 2>/dev/null
        echo ""
        echo "=== OFED 버전 ==="
        ssh "${host}" "ofed_info -s 2>/dev/null || echo 'OFED 미설치 (inbox driver)'" 2>/dev/null
        echo ""
        echo "=== CUDA / nvidia-fs 버전 ==="
        ssh "${host}" "rpm -q nvidia-fs nvidia-gds-12-9 cuda-toolkit-12-9-config-common 2>/dev/null | grep -v 'not installed'" 2>/dev/null
        ssh "${host}" "cat /proc/driver/nvidia-fs/version 2>/dev/null || true" 2>/dev/null
    } > "${outdir}/os_info.txt" 2>/dev/null

    # lscpu
    ssh "${host}" "lscpu" > "${outdir}/lscpu.txt" 2>/dev/null

    # limits.conf (OFED 설치 시 memlock 등 자동 수정됨)
    ssh "${host}" "cat /etc/security/limits.conf 2>/dev/null | grep -v '^#' | grep -v '^$'" \
        > "${outdir}/limits.txt" 2>/dev/null

    # sysctl: 메모리/네트워크 관련 커널 파라미터
    ssh "${host}" "sysctl -a 2>/dev/null | grep -E \
        'vm\.dirty|vm\.swappiness|net\.core\.(rmem|wmem|somaxconn)|kernel\.numa'" \
        > "${outdir}/sysctl.txt" 2>/dev/null

    # lsmem: 메모리 영역 및 크기
    ssh "${host}" "lsmem 2>/dev/null || echo 'lsmem not available'" \
        > "${outdir}/lsmem.txt" 2>/dev/null

    # dmidecode: BIOS/CPU/메모리/슬롯 하드웨어 정보
    {
        echo "=== dmidecode type 0 (BIOS) ==="
        ssh "${host}" "dmidecode -t 0 2>/dev/null"
        echo ""
        echo "=== dmidecode type 4 (Processor) ==="
        ssh "${host}" "dmidecode -t 4 2>/dev/null"
        echo ""
        echo "=== dmidecode type 17 (Memory Device) ==="
        ssh "${host}" "dmidecode -t 17 2>/dev/null"
        echo ""
        echo "=== dmidecode type 9 (System Slots) ==="
        ssh "${host}" "dmidecode -t 9 2>/dev/null"
    } > "${outdir}/dmidecode.txt" 2>/dev/null

    # lspci: Mellanox / NVIDIA 장치 목록
    ssh "${host}" "lspci | grep -iE 'mellanox|nvidia'" \
        > "${outdir}/lspci_mxnv.txt" 2>/dev/null

    # lspci: 각 장치 상세 (-vvv)
    {
        ssh "${host}" "lspci | grep -iE 'mellanox|nvidia' | awk '{print \$1}'" 2>/dev/null \
        | while read -r pci; do
            echo "========================================"
            echo "=== lspci -s ${pci} -vvv ==="
            echo "========================================"
            ssh "${host}" "lspci -s ${pci} -vvv" 2>/dev/null
            echo ""
        done
    } > "${outdir}/lspci_detail.txt"

    # ibstat
    ssh "${host}" "ibstat 2>/dev/null || echo 'ibstat not available'" \
        > "${outdir}/ibstat.txt"

    # ko2iblnd 커널 모듈 파라미터
    {
        echo "=== /etc/modprobe.d/ko2iblnd.conf ==="
        ssh "${host}" "cat /etc/modprobe.d/ko2iblnd.conf 2>/dev/null || echo 'not found'"
        echo ""
        echo "=== /usr/sbin/ko2iblnd-probe (mlx5 case) ==="
        ssh "${host}" "grep -A1 'mlx5' /usr/sbin/ko2iblnd-probe 2>/dev/null || echo 'not found'"
        echo ""
        echo "=== ko2iblnd sysfs parameters ==="
        for param in peer_credits peer_credits_hiw credits concurrent_sends ntx \
                     map_on_demand fmr_pool_size fmr_flush_trigger fmr_cache conns_per_peer; do
            val=$(ssh "${host}" "cat /sys/module/ko2iblnd/parameters/${param} 2>/dev/null")
            printf "  %-25s = %s\n" "${param}" "${val:-N/A}"
        done
    } > "${outdir}/ko2iblnd_params.txt" 2>/dev/null

    # lnet / Lustre 공통 설정
    {
        echo "=== /etc/lnet.conf ==="
        ssh "${host}" "cat /etc/lnet.conf 2>/dev/null || echo 'not found'"
        echo ""
        echo "=== lnetctl net show ==="
        ssh "${host}" "lnetctl net show 2>/dev/null || echo 'lnet not running'"
        echo ""
        echo "=== lnetctl peer show ==="
        ssh "${host}" "lnetctl peer show 2>/dev/null | head -40"
        echo ""
        echo "=== lctl list_nids ==="
        ssh "${host}" "lctl list_nids 2>/dev/null || echo 'N/A'"
        echo ""
        echo "=== lfs df ==="
        ssh "${host}" "lfs df 2>/dev/null || echo 'N/A'"
        echo ""
        echo "=== lfs getstripe -d /mnt/gds (테스트 디렉토리 stripe 설정) ==="
        ssh "${host}" "lfs getstripe -d /mnt/gds 2>/dev/null && lfs getstripe -d /mnt/gds/${host} 2>/dev/null || echo 'N/A'"
        echo ""
        echo "=== mount (lustre) ==="
        ssh "${host}" "mount | grep lustre 2>/dev/null || echo 'not mounted'"
    } > "${outdir}/lnet_lustre.txt" 2>/dev/null

    log "${host} 공통 수집 완료"
}

# ─────────────────────────────────────────
# GPU 서버 전용 수집
# ─────────────────────────────────────────
collect_gpu() {
    local host=$1
    local outdir="${CONFIG_DIR}/${host}"

    # nvidia-smi
    {
        echo "=== nvidia-smi ==="
        ssh "${host}" "nvidia-smi" 2>/dev/null
        echo ""
        echo "=== nvidia-smi --query-gpu ==="
        ssh "${host}" "nvidia-smi --query-gpu=index,name,driver_version,memory.total,pci.bus_id \
            --format=csv" 2>/dev/null
        echo ""
        echo "=== nvidia-smi topo -mp ==="
        ssh "${host}" "nvidia-smi topo -mp 2>/dev/null || echo 'N/A'"
        echo ""
        echo "=== nvidia-smi -q (전체 상세) ==="
        ssh "${host}" "nvidia-smi -q 2>/dev/null"
    } > "${outdir}/nvidia-smi.txt" 2>/dev/null

    # nvidia-peermem 설정
    ssh "${host}" "cat /etc/modprobe.d/nvidia-peermem.conf 2>/dev/null || echo 'not found'" \
        > "${outdir}/nvidia-peermem.txt" 2>/dev/null

    # gdscheck -p
    ssh "${host}" "${GDSCHECK} -p 2>&1" > "${outdir}/gdscheck.txt" 2>/dev/null

    # cufile.json
    ssh "${host}" "cat /etc/cufile.json 2>/dev/null || echo 'not found'" \
        > "${outdir}/cufile.json" 2>/dev/null

    # nvidia-fs stats
    {
        echo "# nvidia-fs 통계 및 모듈 설정"
        echo "# rw_stats_enabled=1: GDS read/write 카운터 활성화"
        echo "# peer_stats_enabled=1: GPU P2P peer 통계 활성화"
        echo ""
        echo "=== /proc/driver/nvidia-fs/stats ==="
        ssh "${host}" "cat /proc/driver/nvidia-fs/stats 2>/dev/null || echo 'not found'"
        echo ""
        echo "=== /proc/driver/nvidia-fs/peer_stats ==="
        ssh "${host}" "cat /proc/driver/nvidia-fs/peer_stats 2>/dev/null || echo 'not found'"
        echo ""
        echo "=== nvidia_fs module parameters ==="
        for param in rw_stats_enabled peer_stats_enabled; do
            val=$(ssh "${host}" "cat /sys/module/nvidia_fs/parameters/${param} 2>/dev/null")
            printf "  %-25s = %s\n" "${param}" "${val:-N/A}"
        done
        echo ""
        echo "=== /etc/modprobe.d/nvidia-fs.conf ==="
        ssh "${host}" "cat /etc/modprobe.d/nvidia-fs.conf 2>/dev/null || echo 'not found'"
    } > "${outdir}/nvidia-fs-stats.txt" 2>/dev/null

    # Lustre 클라이언트 튜닝값 (mount2.sh 설정값)
    {
        echo "=== Lustre client tuning parameters (mount2.sh) ==="
        ssh "${host}" "
            echo '--- osc max_rpcs_in_flight ---'
            lctl get_param osc.*.max_rpcs_in_flight 2>/dev/null
            echo '--- osc max_pages_per_rpc ---'
            lctl get_param osc.TestVol-OST000*.max_pages_per_rpc 2>/dev/null
            echo '--- llite max_read_ahead_mb ---'
            lctl get_param llite.*.max_read_ahead_mb 2>/dev/null
            echo '--- llite max_read_ahead_per_file_mb ---'
            lctl get_param llite.*.max_read_ahead_per_file_mb 2>/dev/null
            echo '--- mdc max_rpcs_in_flight ---'
            lctl get_param mdc.*.max_rpcs_in_flight 2>/dev/null
        " 2>/dev/null
    } >> "${outdir}/lnet_lustre.txt"

    log "${host} GPU 전용 수집 완료"
}

# ─────────────────────────────────────────
# 스토리지 서버 전용 수집
# ─────────────────────────────────────────
collect_storage() {
    local host=$1
    local outdir="${CONFIG_DIR}/${host}"

    # ZFS pool 상태 및 구성
    {
        echo "=== zpool status -v ==="
        ssh "${host}" "zpool status -v 2>/dev/null"
        echo ""
        echo "=== zpool list -v ==="
        ssh "${host}" "zpool list -v 2>/dev/null"
        echo ""
        echo "=== zpool get all ==="
        ssh "${host}" "zpool list -H -o name 2>/dev/null | while read pool; do
            echo \"--- \${pool} ---\"
            zpool get all \${pool} 2>/dev/null | grep -v ' -$'
        done"
        echo ""
        echo "=== NVMe 장치 목록 ==="
        ssh "${host}" "nvme list 2>/dev/null || lsblk -d -o NAME,SIZE,MODEL,ROTA 2>/dev/null"
        echo ""
        echo "=== NVMe 상세 (id-ctrl) ==="
        ssh "${host}" "nvme list 2>/dev/null | awk 'NR>1{print \$1}' | while read dev; do
            echo \"--- \${dev} ---\"
            nvme id-ctrl \${dev} 2>/dev/null | grep -E 'mn|fr|rab|ieee|cntlid|ver|lpa'
        done"
    } > "${outdir}/zpool_status.txt"

    # ZFS dataset 설정
    {
        echo "=== zfs list ==="
        ssh "${host}" "zfs list 2>/dev/null"
        echo ""
        echo "=== zfs get (per dataset) ==="
        ssh "${host}" "zfs list -H -o name 2>/dev/null | while read ds; do
            echo \"--- \${ds} ---\"
            zfs get recordsize,primarycache,secondarycache,logbias,sync,\
compression,atime,relatime,xattr,dedup,quota,used,available \${ds} 2>/dev/null
        done"
        echo ""
        echo "=== ARC 사용량 ==="
        ssh "${host}" "arc_summary 2>/dev/null || \
            awk '/^c / || /^size/ || /^hits/ || /^misses/' /proc/spl/kstat/zfs/arcstats 2>/dev/null | head -20"
    } > "${outdir}/zfs_get.txt" 2>/dev/null

    # Lustre 서버 설정
    {
        echo "=== Lustre 마운트 상태 ==="
        ssh "${host}" "mount | grep lustre 2>/dev/null || echo 'not mounted'"
        echo ""
        echo "=== lctl dl ==="
        ssh "${host}" "lctl dl 2>/dev/null | grep UP"
        echo ""
        echo "=== lfs df ==="
        ssh "${host}" "lfs df 2>/dev/null || echo 'N/A'"
        echo ""
        echo "=== obdfilter brw_size ==="
        ssh "${host}" "lctl get_param obdfilter.TestVol-OST*.brw_size 2>/dev/null || echo 'N/A'"
        echo ""
        echo "=== obdfilter OST 상태 ==="
        ssh "${host}" "lctl get_param obdfilter.TestVol-OST*.stats 2>/dev/null | \
            grep -E 'cache_hit|cache_miss|read_bytes|write_bytes' | head -20 || echo 'N/A'"
        echo ""
        echo "=== osc max_pages_per_rpc ==="
        ssh "${host}" "lctl get_param osc.TestVol-OST*.max_pages_per_rpc 2>/dev/null || echo 'N/A'"
        echo ""
        echo "=== MDT 상태 ==="
        ssh "${host}" "lctl get_param mdt.*.recovery_status 2>/dev/null | \
            grep -E 'status|completed_clients|duration' | head -10 || echo 'N/A'"
        echo ""
        echo "=== /etc/modprobe.d/zfs.conf ==="
        ssh "${host}" "cat /etc/modprobe.d/zfs.conf 2>/dev/null || echo 'not found'"
        echo ""
        echo "=== ZFS vdev tuning (target_create.sh 설정값) ==="
        ssh "${host}" "
            for p in zfs_vdev_sync_read_max_active  zfs_vdev_sync_read_min_active \
                     zfs_vdev_async_read_max_active  zfs_vdev_async_read_min_active \
                     zfs_vdev_async_write_max_active zfs_vdev_async_write_min_active \
                     zfs_prefetch_disable; do
                val=\$(cat /sys/module/zfs/parameters/\${p} 2>/dev/null)
                printf '  %-45s = %s\n' \"\${p}\" \"\${val:-N/A}\"
            done
        "
        echo ""
        echo "=== ZFS ARC 상세 ==="
        ssh "${host}" "cat /proc/spl/kstat/zfs/arcstats 2>/dev/null | \
            grep -E '^(hits|misses|demand_data_hits|demand_data_misses|c |size|p )' | head -20"
    } > "${outdir}/lustre_server.txt" 2>/dev/null

    log "${host} 스토리지 전용 수집 완료"
}

# ─────────────────────────────────────────
# 메인
# ─────────────────────────────────────────
main() {
    log "config 수집 시작 → ${CONFIG_DIR}"
    log "GPU 서버: ${GPU_HOSTS}"
    log "스토리지: ${STORAGE_HOSTS}"
    mkdir -p "${CONFIG_DIR}"

    for host in "${GPU_HOSTS_ARR[@]}"; do
        collect_common "${host}"
        collect_gpu    "${host}"
    done

    for host in "${STORAGE_HOSTS_ARR[@]}"; do
        collect_common  "${host}"
        collect_storage "${host}"
    done

    log "=== 수집 완료 ==="
    echo ""
    echo "저장 위치: ${CONFIG_DIR}"
    echo ""
    echo "디렉토리 구조:"
    find "${CONFIG_DIR}" -type f | sort | sed "s|${CONFIG_DIR}/||"
}

main "$@"
