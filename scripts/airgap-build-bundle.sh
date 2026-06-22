#!/usr/bin/env bash
# =============================================================================
# 폐쇄망(air-gap) 설치 번들 빌드 스크립트  —  RHEL 9 / Python 3.9 기준
# -----------------------------------------------------------------------------
# "인터넷이 되는" RHEL 9 호스트에서 실행합니다. Patroni HA 클러스터 설치에 필요한
# 모든 산출물(RPM, pip wheel, etcd 바이너리, Ansible 컬렉션)을 한곳에 모아
# tarball 로 묶습니다. 이 tarball 을 폐쇄망 노드들로 옮겨 airgap-install.sh 로 풉니다.
#
# 빌드 호스트 사전 조건:
#   - RHEL 9 (대상과 동일 계열) + 시스템 Python 3.9
#   - 활성화된 저장소: BaseOS/AppState, EPEL, PGDG(PostgreSQL)
#     (postgresql16-server, pgbouncer 등을 받기 위함)
#   - sudo 권한, 인터넷 연결
#
# 사용법:
#   ./scripts/airgap-build-bundle.sh
#   PG_VER=16 ETCD_VER=3.5.16 OUT=./airgap-bundle ./scripts/airgap-build-bundle.sh
# =============================================================================
set -euo pipefail

# --- 버전/경로 (group_vars/all.yml 과 일치시킬 것) ---------------------------
PG_VER="${PG_VER:-16}"
ETCD_VER="${ETCD_VER:-3.5.16}"
# RHEL 9 시스템 Python 3.9 와 호환되는 ansible-core 범위 (2.16+ 는 Python 3.10+ 요구)
ANSIBLE_SPEC="${ANSIBLE_SPEC:-ansible-core>=2.15,<2.16}"
OUT="${OUT:-./airgap-bundle}"
ARCH="${ARCH:-linux-amd64}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "==> 번들 빌드 시작 (PostgreSQL ${PG_VER}, etcd ${ETCD_VER}, ${ANSIBLE_SPEC})"

# --- 0) 빌드 도구 확인/설치 -------------------------------------------------
echo "==> 빌드 도구 확인 (dnf-plugins-core, createrepo_c)"
sudo dnf install -y dnf-plugins-core createrepo_c python3 python3-pip

# 출력 디렉터리 초기화
rm -rf "${OUT}"
mkdir -p "${OUT}"/{rpms,wheels/control,wheels/target,etcd,collections}

# --- 1) RPM 수집 (의존성 포함) ----------------------------------------------
# --resolve --alldeps: 의존 패키지까지 모두 내려받아 폐쇄망에서 자급자족 가능하게 함
echo "==> RPM 다운로드 (의존성 포함)"
sudo dnf download --resolve --alldeps --destdir "${OUT}/rpms" \
  python3-pip \
  python3-psycopg2 \
  acl \
  chrony \
  "postgresql${PG_VER}-server" \
  "postgresql${PG_VER}-contrib" \
  pgbouncer \
  haproxy \
  keepalived

echo "==> 로컬 저장소 메타데이터 생성 (createrepo_c)"
createrepo_c "${OUT}/rpms"

# --- 2) pip wheel 수집 ------------------------------------------------------
# 빌드 호스트가 RHEL 9 + Python 3.9 이므로, 여기서 받은 wheel 은 대상 노드와 호환됩니다.
echo "==> 컨트롤 노드용 wheel 다운로드 (ansible-core)"
python3 -m pip download --dest "${OUT}/wheels/control" ${ANSIBLE_SPEC}

echo "==> 대상 노드용 wheel 다운로드 (patroni, psycopg2-binary, python-etcd)"
python3 -m pip download --dest "${OUT}/wheels/target" \
  "patroni[etcd3]" psycopg2-binary python-etcd

# --- 3) etcd 바이너리 ------------------------------------------------------
echo "==> etcd ${ETCD_VER} 바이너리 다운로드"
curl -fL -o "${OUT}/etcd/etcd-v${ETCD_VER}-${ARCH}.tar.gz" \
  "https://github.com/etcd-io/etcd/releases/download/v${ETCD_VER}/etcd-v${ETCD_VER}-${ARCH}.tar.gz"

# --- 4) Ansible Galaxy 컬렉션 ----------------------------------------------
# 컬렉션 다운로드를 위해 임시 venv 에 ansible-core 설치 후 사용
echo "==> 임시 venv 로 ansible-galaxy 준비 후 컬렉션 다운로드"
BUILD_VENV="$(mktemp -d)/venv"
python3 -m venv "${BUILD_VENV}"
"${BUILD_VENV}/bin/pip" install --quiet --upgrade pip
"${BUILD_VENV}/bin/pip" install --quiet --find-links "${OUT}/wheels/control" ${ANSIBLE_SPEC}
"${BUILD_VENV}/bin/ansible-galaxy" collection download \
  -r "${PROJECT_DIR}/requirements.yml" -p "${OUT}/collections"

# --- 5) 매니페스트 + 설치 스크립트 동봉 -------------------------------------
cp "${SCRIPT_DIR}/airgap-install.sh" "${OUT}/"
cat > "${OUT}/MANIFEST.txt" <<EOF
Patroni PostgreSQL HA - air-gap bundle
build_date            : $(date -u +%Y-%m-%dT%H:%M:%SZ)
postgresql_version    : ${PG_VER}
etcd_version          : ${ETCD_VER}
ansible_spec          : ${ANSIBLE_SPEC}
arch                  : ${ARCH}
rpms                  : $(ls -1 "${OUT}/rpms"/*.rpm 2>/dev/null | wc -l) files
wheels(control)       : $(ls -1 "${OUT}/wheels/control" 2>/dev/null | wc -l) files
wheels(target)        : $(ls -1 "${OUT}/wheels/target" 2>/dev/null | wc -l) files
collections           : $(ls -1 "${OUT}/collections"/*.tar.gz 2>/dev/null | wc -l) files
EOF

# --- 6) tarball 묶기 --------------------------------------------------------
BUNDLE="patroni-airgap-bundle-pg${PG_VER}-$(date -u +%Y%m%d).tar.gz"
echo "==> tarball 생성: ${BUNDLE}"
tar -czf "${BUNDLE}" -C "$(dirname "${OUT}")" "$(basename "${OUT}")"

echo ""
echo "==> 완료!"
echo "    번들      : ${BUNDLE}"
echo "    매니페스트: ${OUT}/MANIFEST.txt"
echo ""
echo "    다음 단계:"
echo "    1) ${BUNDLE} 를 폐쇄망의 컨트롤 노드와 모든 대상 노드로 복사"
echo "    2) 각 노드에서 압축 해제 후 airgap-install.sh 실행"
echo "       - 컨트롤: sudo ./airgap-install.sh --role control"
echo "       - 대상  : sudo ./airgap-install.sh --role target"
