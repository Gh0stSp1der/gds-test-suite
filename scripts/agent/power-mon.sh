#!/bin/bash
# CPU 패키지 전력 모니터링 (RAPL /sys/class/powercap)
# 출력 형식: HH:MM:SS pkg0=XX.XW pkg1=XX.XW sys=0W

RAPL_BASE="/sys/class/powercap"
INTERVAL=1

# RAPL 최대값 (오버플로우 처리)
get_max_energy() {
    local domain=$1
    local path="${RAPL_BASE}/${domain}/max_energy_range_uj"
    [ -r "${path}" ] && cat "${path}" || echo 262143328850
}

declare -A prev_energy max_energy

read_energy() {
    local domain=$1
    local path="${RAPL_BASE}/${domain}/energy_uj"
    [ -r "${path}" ] && cat "${path}" || echo 0
}

for d in intel-rapl:0 intel-rapl:1; do
    [ -d "${RAPL_BASE}/${d}" ] || continue
    prev_energy["${d}"]=$(read_energy "${d}")
    max_energy["${d}"]=$(get_max_energy "${d}")
done

while true; do
    sleep "${INTERVAL}"
    ts=$(date '+%H:%M:%S')
    line="${ts}"

    for d in intel-rapl:0 intel-rapl:1; do
        [ -d "${RAPL_BASE}/${d}" ] || continue
        cur=$(read_energy "${d}")
        prev=${prev_energy["${d}"]}
        maxe=${max_energy["${d}"]}

        # 오버플로우 처리
        if [ "$cur" -lt "$prev" ]; then
            delta=$(( maxe - prev + cur ))
        else
            delta=$(( cur - prev ))
        fi
        prev_energy["${d}"]=${cur}

        watts=$(awk "BEGIN {printf \"%.1f\", ${delta} / 1000000 / ${INTERVAL}}")
        name="${d#intel-rapl:}"
        line="${line} pkg${name}=${watts}W"
    done

    echo "${line} sys=0W"
done
