# GPUDirect Storage 테스트 스크립트

> 작성: 2026-07  
> 목적: GPU Direct Storage(GDS) 성능 측정 — 공인 시험평가용

---

## 1. 디렉토리 구조

```
/root/thkim/tta_gds_root/
├── README.md
├── conf/
│   └── hosts.conf              # GPU 서버 / 스토리지 호스트 목록
├── scripts/
│   ├── create_files.sh         # 테스트 파일 생성
│   ├── run_gdsio.sh            # gdsio 실행 wrapper (단일 테스트)
│   ├── run_tests.sh            # 전체 테스트 자동화 (루프 기반)
│   ├── run_tests_cli.sh        # 전체 테스트 명령어 모음 (보고서용)
│   ├── collect_config.sh       # 시스템 config 수집
│   └── mon/
│       ├── start_mon.sh        # 모니터링 시작
│       └── stop_mon.sh         # 모니터링 종료 + 로그 수집
└── results/
    └── <RUN_ID>/               # 실행마다 독립 디렉토리
        ├── run_tests_cli.log   # 전체 실행 로그
        ├── config/             # 시스템 config (실행 시점 스냅샷)
        │   ├── io500-1/
        │   │   ├── os_info.txt, lscpu.txt, lsmem.txt, dmidecode.txt
        │   │   ├── lspci_mxnv.txt, lspci_detail.txt, ibstat.txt
        │   │   ├── ko2iblnd_params.txt, lnet_lustre.txt
        │   │   ├── nvidia-smi.txt, gdscheck.txt, cufile.json
        │   │   └── nvidia-fs-stats.txt
        │   └── aic1/
        │       ├── os_info.txt, lscpu.txt, lsmem.txt, dmidecode.txt
        │       ├── lspci_mxnv.txt, lspci_detail.txt, ibstat.txt
        │       ├── ko2iblnd_params.txt, lnet_lustre.txt
        │       ├── zpool_status.txt, zfs_get.txt, lustre_server.txt
        │       └── (aic2/ 동일)
        ├── read_xfer0_GDS/
        │   ├── c1/
        │   │   ├── throughput.log        # 결과 요약
        │   │   ├── gdsio_io500-1.log     # 노드별 gdsio 원본 출력
        │   │   └── monitor/
        │   │       ├── io500-1/
        │   │       │   ├── mpstat.log, nvdmon.log, ib_bw.log, dstat.log
        │   │       └── aic1/
        │   │           ├── mpstat.log, ib_bw.log, dstat.log
        │   │           ├── zpool_iostat.log, iostat.log
        │   ├── c2/  c3/
        ├── read_xfer1_CPU/
        ├── read_xfer2_CPU_GPU/
        ├── write_xfer0_GDS/
        ├── write_xfer1_CPU/
        └── write_xfer2_CPU_GPU/
```

---

## 2. 사전 요구사항

### SSH 키 설정 (패스워드 없이 접속)
```bash
ssh-keygen -t rsa -N ""   # 키가 없는 경우
for h in io500-1 io500-2 io500-3 io500-4 io500-5 io500-6 io500-7 aic1 aic2; do
    ssh-copy-id -y root@${h}
done
```

### Lustre 마운트 확인
```bash
for node in io500-1 io500-2 io500-3 io500-4 io500-5 io500-6 io500-7; do
    ssh ${node} "df -h | grep TestVol"
done
```

### gdsio 경로
```
/usr/local/cuda-12.9/gds/tools/gdsio
```
각 GPU 서버에 설치되어 있어야 합니다.

---

## 3. 테스트 파라미터

| 항목 | 값 | 비고 |
|------|----|------|
| Block Size (bs) | 8M | run_tests_cli.sh 상단 변수 |
| Threads | 256 | run_tests_cli.sh 상단 변수 |
| Duration | 120s | run_tests_cli.sh 상단 변수 |
| Cycles | 3회 | xfertype별 반복 횟수 |
| XferType | 0=GDS, 1=CPU, 2=CPU_GPU | |
| IoType | 0=Read, 1=Write | |
| 총 실행 | 18회 | 2 × 3 × 3 |

파라미터 변경은 `run_tests_cli.sh` 상단의 변수를 수정합니다:
```bash
BS=8M
THREADS=256
DURATION=120
```

---

## 4. 실행 절차

### Step 1. 호스트 설정 확인
```bash
cat /root/thkim/tta_gds_root/conf/hosts.conf
```

### Step 2. 테스트 파일 생성 (최초 1회)
각 GPU 서버에 256개 × 16GB 파일 순차 생성 (~4TB/노드, 수 시간 소요)
```bash
cd /root/thkim/tta_gds_root/scripts
./create_files.sh             # 확인 프롬프트 있음
./create_files.sh --yes       # 확인 없이 바로 실행
./create_files.sh --skip-existing  # 중단 후 재시작 시
```

### Step 3. 전체 테스트 실행
```bash
cd /root/thkim/tta_gds_root/scripts
./run_tests_cli.sh                        # 자동 타임스탬프 RUN_ID
./run_tests_cli.sh 20260714_tta_test1     # RUN_ID 직접 지정
```
실행 중 진행 상황과 로그 파일 경로가 터미널에 표시됩니다.

### Step 4. 결과 확인
```bash
# throughput 요약
cat /root/thkim/tta_gds_root/results/<RUN_ID>/run_tests_cli.log | grep "TOTAL"

# 전체 결과 디렉토리
ls /root/thkim/tta_gds_root/results/<RUN_ID>/
```

---

## 5. 개별 스크립트 사용법

### run_gdsio.sh — 단일 테스트 실행
```bash
./run_gdsio.sh -d <output_dir> -x <xfertype> -I <iotype> [OPTIONS]

# 예시: GDS Read, bs=8M, 256 threads, 120초
./run_gdsio.sh -d /tmp/test1 -x 0 -I 0 -b 8M -w 256 -T 120
```

옵션 설명:
| 옵션 | 설명 | 필수 |
|------|------|------|
| `-d <dir>` | 결과 저장 디렉토리 | ✓ |
| `-x 0\|1\|2` | XferType (0=GDS, 1=CPU, 2=CPU_GPU) | ✓ |
| `-I 0\|1` | IoType (0=Read, 1=Write) | ✓ |
| `-b <bs>` | Block size (기본: 8M) | |
| `-w <n>` | Thread 수 (기본: 256) | |
| `-T <sec>` | 실행 시간 초 (기본: 120) | |

### collect_config.sh — 시스템 config 수집
```bash
./collect_config.sh <BASE_RESULT_DIR>
./collect_config.sh /root/thkim/tta_gds_root/results/20260714_tta_test1
```

### create_files.sh — 테스트 파일 생성
```bash
./create_files.sh [--nodes "h1 h2"] [--skip-existing] [--yes]
```

---

## 6. 클러스터 구성

### GPU 클라이언트 (io500-1~7)
| 항목 | 값 |
|------|----|
| OS | Rocky Linux 8.10 |
| Kernel | 4.18.0-553.111.1.el8_10 |
| GPU | H100 NVL (io500-2~7), A100 (io500-1) |
| IB NIC | ConnectX-7 400G |
| CUDA | 12.9 |
| nvidia-fs | 2.29.4 |
| Lustre client | 2.15.8 (flexa 1.3, OFED) |

### 스토리지 서버
| 항목 | aic1 | aic2 |
|------|------|------|
| Lustre | MGS + MDT0 + OST0~7 | MDT1 + OST8~15 |
| ZFS | 2.3.6 (flexa 1.3) | 2.3.6 (flexa 1.3) |
| IB NIC | ConnectX-7 × 3 | ConnectX-7 × 3 |
| IB NID | .130/.140/.150 | .131/.141/.151 |

---

## 7. 모니터링 항목

### GPU 서버
| 파일 | 명령어 | 설명 |
|------|--------|------|
| mpstat.log | `mpstat 1` | CPU 코어별 사용률 |
| nvdmon.log | `nvidia-smi dmon -s um -d 1` | GPU SM/MEM utilization |
| ib_bw.log | `ib-bw.sh` | IB NIC TX/RX 대역폭 |
| dstat.log | `dstat -t -c -m -n -d 1` | 종합 시스템 통계 |

### 스토리지 서버
| 파일 | 명령어 | 설명 |
|------|--------|------|
| mpstat.log | `mpstat 1` | CPU 사용률 |
| ib_bw.log | `ib-bw.sh` | IB NIC TX/RX 대역폭 |
| dstat.log | `dstat -t -c -m -n -d 1` | 종합 통계 |
| zpool_iostat.log | `zpool iostat -qv 1` | ZFS pool I/O |
| iostat.log | `iostat -mtxz 1` | 디바이스별 I/O |

---

## 8. Ctrl+C 처리

테스트 실행 중 `Ctrl+C`를 누르면:
- 원격 gdsio 프로세스 자동 종료 (`pkill -f gdsio`)
- 원격 모니터링 프로세스 자동 종료
- 이미 완료된 결과는 보존됨
- `create_files.sh` 중단 시 `--skip-existing`으로 재시작 가능
