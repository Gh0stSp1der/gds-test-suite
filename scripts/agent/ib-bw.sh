#!/bin/bash

INTERVAL=1  # 측정 간격(초)

declare -A counters_tx counters_rx prev_tx prev_rx

# 모든 IB 디바이스와 포트 순회
for devpath in /sys/class/infiniband/*;
do
    dev=$(basename "$devpath")
    if [[ ! $dev =~ mlx_* ]]; then
        continue
    fi

    for portpath in "$devpath"/ports/*;
    do
        port=$(basename "$portpath")

        counters_tx["$dev:$port"]="$portpath/counters/port_xmit_data"
        counters_rx["$dev:$port"]="$portpath/counters/port_rcv_data"

        # 초기값 저장
        prev_tx["$dev:$port"]="$(cat "${counters_tx[$dev:$port]}")"
        prev_rx["$dev:$port"]="$(cat "${counters_rx[$dev:$port]}")"
    done
done

prev_time=$(date +%s.%N)

while true;
do
    sleep "$INTERVAL"

    curr_time=$(date +%s.%N)
    time_diff=$(echo "$curr_time - $prev_time" | bc -l)

    for key in "${!prev_tx[@]}";
    do
        tx_path=${counters_tx[$key]}
        rx_path=${counters_rx[$key]}

        curr_tx=$(cat "$tx_path")
        curr_rx=$(cat "$rx_path")

        # 4바이트 단위 => 바이트
        tx_bytes=$(echo "($curr_tx - ${prev_tx[$key]}) * 4" | bc)
        rx_bytes=$(echo "($curr_rx - ${prev_rx[$key]}) * 4" | bc)

        # GB/s 계산
        tx_gbs=$(echo "scale=4; $tx_bytes / $time_diff / 1000000000" | bc -l)
        rx_gbs=$(echo "scale=4; $rx_bytes / $time_diff / 1000000000" | bc -l)

        printf "%-12s Port %-2s | TX: %7s GB/s | RX: %7s GB/s\n" \
            "${key%%:*}" "${key##*:}" "$tx_gbs" "$rx_gbs"

        # 값 업데이트
        prev_tx[$key]=$curr_tx
        prev_rx[$key]=$curr_rx
    done

    prev_time=$curr_time

    echo "----------------------------------------------------------"
done

