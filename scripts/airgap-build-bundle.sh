#!/usr/bin/env bash
# =============================================================================
# 폐쇄망(air-gap) 설치 번들 빌드 스크립트  —  RHEL 9 기준
# -----------------------------------------------------------------------------
# "인터넷이 되는" RHEL 9 호스트에서 실행합니다. Patroni HA 클러스터 설치에 필요한
# 모든 산출물(RPM, pip wheel, etcd 바이너리, Ansible 컬렉션)을 모아 tarball 로 묶습니다.
#
# 두 가지 프로파일을 만듭니다.
#   full  — 의존성 전체 폐쇄. OS 미러조차 없는 완전 폐쇄망용. 무겁지만 자급자족.
#           설치 시 offline_repo_exclusive=true (기본값)
#   delta — 번들 저장소에만 있는 것(PGDG/EPEL 유래)만 담음. 사내에 RHEL 미러가
#           이미 있는 환경용. 가볍다.
#           설치 시 반드시 offline_repo_exclusive=false 로 두어야 한다.
#
# 빌드 호스트 사전 조건:
#   - 대상과 **같은 RHEL 마이너 버전** (9.4 대상이면 9.4 에서 빌드).
#     상위 마이너에서 빌드하면 base 패키지가 대상보다 높은 버전으로 섞인다.
#   - 활성화된 저장소: BaseOS/AppStream, PGDG. (pgbackrest 를 담으려면 EPEL 도)
#   - sudo 권한, 인터넷 연결
#
# 사용법:
#   ./scripts/airgap-build-bundle.sh                       # full + delta 둘 다
#   PROFILE=full  ./scripts/airgap-build-bundle.sh
#   PG_PIN=16.14-1PGDG.rhel9.6 ./scripts/airgap-build-bundle.sh
#   WITH_PGBACKREST=1 ./scripts/airgap-build-bundle.sh     # EPEL 필요
# =============================================================================
set -euo pipefail

# --- 버전/경로 (group_vars/all/main.yml 과 일치시킬 것) ---------------------------
PG_VER="${PG_VER:-16}"
# PostgreSQL 패키지 핀. 폐쇄망에서는 설치 시점에 바꿀 수 없으므로 **번들 빌드 때**
# 대상 OS 에서 설치 가능한 빌드로 고정해야 한다. 비워두면 저장소 최신을 받는다.
#   예) RHEL 9.4 는 openssl 3.0 이라 최신(*.rhel9.8, OpenSSL 3.4 요구)이 설치 불가.
#       → PG_PIN=16.14-1PGDG.rhel9.6
PG_PIN="${PG_PIN:-}"
ETCD_VER="${ETCD_VER:-3.5.16}"

# 대상 노드에서 Patroni venv 를 만들 파이썬. wheel 의 ABI 태그(cp39/cp311)를 결정하므로
# **group_vars/all/main.yml 의 patroni_python 과 반드시 같아야 한다.**
# (어긋나면 폐쇄망에서 "no matching distribution" 으로 설치가 실패한다.)
#
# 기본값은 python3.11 이다. RHEL 9 의 /usr/bin/python3 는 3.9 지만 그것은 OS
# 전용(dnf/firewalld/SELinux)이고, 같은 서버에 Airflow 등을 함께 올리는 구성에서
# 애플리케이션 런타임을 3.11 로 맞추는 편이 관리가 쉽다.
# 3.9 로 되돌리려면 VENV_PY=python3.9 로 빌드하고 patroni_python 도 함께 바꾼다.
VENV_PY="${VENV_PY:-python3.11}"

# RHEL 9 시스템 Python 3.9 와 호환되는 ansible-core 범위 (2.16+ 는 Python 3.10+ 요구)
ANSIBLE_SPEC="${ANSIBLE_SPEC:-ansible-core>=2.15,<2.16}"
PROFILE="${PROFILE:-both}"          # full | delta | both
WITH_PGBACKREST="${WITH_PGBACKREST:-0}"
OUT_BASE="${OUT_BASE:-./airgap-out}"
ARCH="${ARCH:-linux-amd64}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STAMP="$(date -u +%Y%m%d)"

die() { echo "❌ $*" >&2; exit 1; }

case "${PROFILE}" in full|delta|both) ;; *) die "PROFILE 은 full|delta|both 중 하나" ;; esac
command -v "${VENV_PY}" >/dev/null 2>&1 \
  || die "${VENV_PY} 가 없습니다. VENV_PY 를 대상 노드의 python3 버전에 맞추세요."

# --- 패키지 목록 ------------------------------------------------------------
PG_SUFFIX=""
[[ -n "${PG_PIN}" ]] && PG_SUFFIX="-${PG_PIN}"

# PGDG 유래 (delta 에도 반드시 포함)
PKGS_PGDG=(
  "postgresql${PG_VER}-server${PG_SUFFIX}"
  "postgresql${PG_VER}-contrib${PG_SUFFIX}"
  pgbouncer
)
# OS 저장소 유래 (full 에만 남는다. delta 는 대상의 BaseOS/AppStream 미러가 제공)
PKGS_OS=(
  python3-pip
  python3-psycopg2
  python3-libsemanage     # SELinux boolean(haproxy_connect_any) 설정에 필요
  acl
  chrony
  haproxy
  keepalived
)
# venv 를 시스템 기본(python3=3.9)이 아닌 인터프리터로 만드는 경우, 그 인터프리터
# 자체도 번들에 담아야 폐쇄망에서 venv 를 만들 수 있다. RHEL 9 는 python3.11 을
# AppStream 에서 제공하며 psycopg2 도 같은 접두사의 패키지가 따로 있다.
#   python3.11  python3.11-pip  python3.11-psycopg2
if [[ "${VENV_PY}" != "python3" && "${VENV_PY}" =~ ^python3\.[0-9]+$ ]]; then
  PKGS_OS+=("${VENV_PY}" "${VENV_PY}-pip" "${VENV_PY}-psycopg2")
fi
if [[ "${WITH_PGBACKREST}" == "1" ]]; then
  # pgbackrest 는 EPEL 의 libssh2 에 의존한다(TESTING.md FINDING-9).
  PKGS_PGDG+=(pgbackrest)
fi

echo "==> 번들 빌드 (PostgreSQL ${PG_VER}${PG_PIN:+ / 핀 ${PG_PIN}}, etcd ${ETCD_VER}, wheel=${VENV_PY}, profile=${PROFILE})"

# --- 0) 빌드 도구 -----------------------------------------------------------
sudo dnf install -y -q dnf-plugins-core createrepo_c >/dev/null

WORK="${OUT_BASE}/work"
rm -rf "${OUT_BASE}"
mkdir -p "${WORK}"/{rpms_full,rpms_delta,wheels/control,wheels/target,etcd,collections}

# --- 1) RPM: 전체 의존 폐쇄 --------------------------------------------------
# --alldeps 는 빌드 호스트에 이미 설치된 것까지 포함해 전체 폐쇄를 받는다.
# (--alldeps 없이 --resolve 만 쓰면 "빌드 호스트에 이미 있는" 의존성이 누락되어
#  clean 한 대상에서 설치가 깨진다.)
echo "==> RPM 다운로드 (의존성 전체 폐쇄)"
sudo dnf download --resolve --alldeps --destdir "${WORK}/rpms_full" \
  "${PKGS_PGDG[@]}" "${PKGS_OS[@]}" >/dev/null
echo "    full: $(ls -1 "${WORK}/rpms_full"/*.rpm 2>/dev/null | wc -l) RPM"

# --- 2) RPM: delta = full 에서 "대상 OS 저장소가 이미 제공하는 것"을 뺀 것 ------
# 판정 기준은 빌드 호스트에 설정된 OS 저장소(BaseOS/AppStream)의 가용 목록이다.
if [[ "${PROFILE}" == "delta" || "${PROFILE}" == "both" ]]; then
  echo "==> delta 산출 (OS 저장소가 제공하는 패키지 제외)"
  # 저장소 목록을 repolist 로 파싱하지 않는다 — 구독 미등록 경고 등이 stdout 에 섞이고
  # 로케일에 따라 헤더 문구도 달라져서 저장소 ID 로 오인된다.
  # 대신 패키지마다 %{reponame} 을 직접 물어 "PGDG/EPEL 이 아닌 저장소가 제공하는가"로 판정.
  LC_ALL=C dnf repoquery --available \
      --qf '%{name}-%{version}-%{release}.%{arch}|%{reponame}' 2>/dev/null \
    | grep -F '|' \
    | grep -viE '\|(pgdg|epel|patroni-airgap)' \
    | cut -d'|' -f1 | sort -u > "${WORK}/os_available.txt"
  [[ -s "${WORK}/os_available.txt" ]] \
    || die "OS 저장소 패키지 목록이 비었습니다(BaseOS/AppStream 활성화 필요)."
  echo "    OS 저장소 제공 패키지: $(wc -l < "${WORK}/os_available.txt")개"

  kept=0; skipped=0
  for f in "${WORK}/rpms_full"/*.rpm; do
    nevra="$(rpm -qp --qf '%{name}-%{version}-%{release}.%{arch}' "$f" 2>/dev/null)"
    if grep -qxF "${nevra}" "${WORK}/os_available.txt"; then
      skipped=$((skipped+1))
    else
      cp -a "$f" "${WORK}/rpms_delta/"; kept=$((kept+1))
    fi
  done
  echo "    delta: ${kept} RPM (OS 저장소 제공분 ${skipped}개 제외)"
fi

# --- 3) pip wheel -----------------------------------------------------------
echo "==> wheel 다운로드 (${VENV_PY} — ABI 태그가 대상과 일치해야 함)"
"${VENV_PY}" -m pip download --dest "${WORK}/wheels/target" \
  "patroni[etcd3]" psycopg2-binary >/dev/null
echo "    target: $(ls -1 "${WORK}/wheels/target" | wc -l) 파일"

"${VENV_PY}" -m pip download --dest "${WORK}/wheels/control" ${ANSIBLE_SPEC} >/dev/null
echo "    control: $(ls -1 "${WORK}/wheels/control" | wc -l) 파일"

# ABI 태그 검증 — 대상 파이썬과 다른 cp 태그가 섞이면 폐쇄망에서 설치 실패한다.
PYTAG="cp$(${VENV_PY} -c 'import sys;print(f"{sys.version_info[0]}{sys.version_info[1]}")')"
BAD="$(ls -1 "${WORK}/wheels/target" | grep -oE 'cp3[0-9]+' | sort -u \
        | grep -vE "^(${PYTAG}|cp3[0-6])$" || true)"
[[ -z "${BAD}" ]] || die "wheel ABI 태그 불일치: ${BAD} (기대 ${PYTAG}). VENV_PY 를 확인하세요."
echo "    ABI 태그 검증 통과 (${PYTAG})"

# --- 4) etcd 바이너리 -------------------------------------------------------
echo "==> etcd ${ETCD_VER} 다운로드"
curl -fsSL -o "${WORK}/etcd/etcd-v${ETCD_VER}-${ARCH}.tar.gz" \
  "https://github.com/etcd-io/etcd/releases/download/v${ETCD_VER}/etcd-v${ETCD_VER}-${ARCH}.tar.gz"

# --- 5) Ansible 컬렉션 ------------------------------------------------------
echo "==> Ansible 컬렉션 다운로드"
BUILD_VENV="$(mktemp -d)/venv"
"${VENV_PY}" -m venv "${BUILD_VENV}"
"${BUILD_VENV}/bin/pip" install --quiet --upgrade pip
"${BUILD_VENV}/bin/pip" install --quiet --no-index --find-links "${WORK}/wheels/control" ${ANSIBLE_SPEC}
"${BUILD_VENV}/bin/ansible-galaxy" collection download \
  -r "${PROJECT_DIR}/requirements.yml" -p "${WORK}/collections" >/dev/null

# --- 6) 프로파일별 조립 -----------------------------------------------------
assemble() {
  local prof="$1" src_rpms="$2"
  local dir="${OUT_BASE}/patroni-airgap-${prof}"
  echo "==> [${prof}] 조립"
  mkdir -p "${dir}"/{rpms,wheels,etcd,collections}
  cp -a "${src_rpms}"/*.rpm "${dir}/rpms/" 2>/dev/null || true
  createrepo_c --quiet "${dir}/rpms"
  cp -a "${WORK}/wheels/." "${dir}/wheels/"
  cp -a "${WORK}/etcd/."   "${dir}/etcd/"
  cp -a "${WORK}/collections/." "${dir}/collections/"
  cp "${SCRIPT_DIR}/airgap-install.sh" "${dir}/"

  local excl="true"; local note="OS 미러 없이 자급자족"
  if [[ "${prof}" == "delta" ]]; then
    excl="false"; note="대상에 RHEL BaseOS/AppStream 미러가 있어야 함"
  fi

  cat > "${dir}/MANIFEST.txt" <<EOF
Patroni PostgreSQL HA — air-gap bundle
profile               : ${prof}   (${note})
build_date            : $(date -u +%Y-%m-%dT%H:%M:%SZ)
build_host_os         : $(. /etc/os-release && echo "${PRETTY_NAME}")
postgresql_version    : ${PG_VER}
postgresql_package_pin: ${PG_PIN:-<none: repo latest>}
etcd_version          : ${ETCD_VER}
wheel_python          : $(${VENV_PY} --version 2>&1) (${PYTAG})
ansible_spec          : ${ANSIBLE_SPEC}
arch                  : ${ARCH}
rpms                  : $(ls -1 "${dir}/rpms"/*.rpm 2>/dev/null | wc -l) files
wheels(target)        : $(ls -1 "${dir}/wheels/target" 2>/dev/null | wc -l) files
wheels(control)       : $(ls -1 "${dir}/wheels/control" 2>/dev/null | wc -l) files
collections           : $(ls -1 "${dir}/collections"/*.tar.gz 2>/dev/null | wc -l) files

[설치 시 반드시 지정할 변수]
  offline_mode: true
  offline_repo_exclusive: ${excl}
  postgresql_package_pin: "${PG_PIN}"
EOF

  ( cd "${dir}" && find . -type f ! -name SHA256SUMS -print0 \
      | sort -z | xargs -0 sha256sum > SHA256SUMS )

  local tgz="${OUT_BASE}/patroni-airgap-${prof}-pg${PG_VER}-${STAMP}.tar.gz"
  tar -czf "${tgz}" -C "${OUT_BASE}" "patroni-airgap-${prof}"
  echo "    ${tgz}  ($(du -h "${tgz}" | cut -f1))"
}

[[ "${PROFILE}" == "full"  || "${PROFILE}" == "both" ]] && assemble full  "${WORK}/rpms_full"
[[ "${PROFILE}" == "delta" || "${PROFILE}" == "both" ]] && assemble delta "${WORK}/rpms_delta"

rm -rf "${WORK}"
echo ""
echo "==> 완료. 산출물: ${OUT_BASE}/"
ls -1sh "${OUT_BASE}"/*.tar.gz 2>/dev/null || true
