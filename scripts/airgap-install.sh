#!/usr/bin/env bash
# =============================================================================
# 폐쇄망(air-gap) 오프라인 설치 스크립트  —  RHEL 9 / Python 3.9 기준
# -----------------------------------------------------------------------------
# airgap-build-bundle.sh 로 만든 번들을 푼 디렉터리(또는 번들 안)에서 실행합니다.
# 각 노드에 로컬 자원(dnf 저장소, pip wheelhouse, etcd 바이너리)을 배치하여
# Ansible 이 offline_mode=true 로 인터넷 없이 설치할 수 있게 만듭니다.
#
# 역할:
#   --role control : 컨트롤 노드. Python 3.9 venv 에 ansible-core + 컬렉션(오프라인) 설치
#   --role target  : 대상(DB/etcd) 노드. 로컬 dnf 저장소 + wheelhouse + etcd 배치
#   --role both    : 한 노드가 컨트롤 겸 대상일 때(통합형)
#
# 사용법 (번들을 푼 디렉터리에서):
#   sudo ./airgap-install.sh --role control
#   sudo ./airgap-install.sh --role target
#   sudo ./airgap-install.sh --role both --bundle /path/to/airgap-bundle
# =============================================================================
set -euo pipefail

# --- 설치 위치 (group_vars/all.yml 의 offline_* 와 일치) --------------------
BASE_DIR="${BASE_DIR:-/opt/patroni-airgap}"
REPO_NAME="${REPO_NAME:-patroni-airgap}"

ROLE=""
BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 기본: 스크립트가 있는 폴더

# --- 인자 파싱 --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)   ROLE="$2"; shift 2 ;;
    --bundle) BUNDLE_DIR="$(cd "$2" && pwd)"; shift 2 ;;
    *) echo "알 수 없는 옵션: $1"; exit 1 ;;
  esac
done

if [[ -z "${ROLE}" ]]; then
  echo "오류: --role {control|target|both} 를 지정하세요."
  exit 1
fi
if [[ "${EUID}" -ne 0 ]]; then
  echo "오류: root(또는 sudo)로 실행해야 합니다."
  exit 1
fi

echo "==> 폐쇄망 설치 시작 (role=${ROLE}, bundle=${BUNDLE_DIR})"

# 번들 구성 요소 확인
for d in rpms wheels collections etcd; do
  [[ -d "${BUNDLE_DIR}/${d}" ]] || { echo "오류: 번들에 ${d}/ 가 없습니다 (${BUNDLE_DIR})"; exit 1; }
done

# ----------------------------------------------------------------------------
# 공통) 로컬 dnf 저장소 설정 (대상/both 에서 패키지 설치에 사용)
# ----------------------------------------------------------------------------
setup_local_repo() {
  echo "==> 로컬 dnf 저장소 배치: ${BASE_DIR}/rpms"
  mkdir -p "${BASE_DIR}/rpms"
  cp -a "${BUNDLE_DIR}/rpms/." "${BASE_DIR}/rpms/"

  # 빌드 단계에서 repodata 가 없다면 여기서 생성 시도
  if [[ ! -d "${BASE_DIR}/rpms/repodata" ]]; then
    if command -v createrepo_c >/dev/null 2>&1; then
      createrepo_c "${BASE_DIR}/rpms"
    else
      echo "경고: repodata 가 없고 createrepo_c 도 없습니다. 번들을 다시 만들어 주세요."
    fi
  fi

  cat > "/etc/yum.repos.d/${REPO_NAME}.repo" <<EOF
[${REPO_NAME}]
name=Patroni Air-gap Bundle
baseurl=file://${BASE_DIR}/rpms
enabled=1
gpgcheck=0
EOF
  echo "    /etc/yum.repos.d/${REPO_NAME}.repo 작성 완료"
}

# ----------------------------------------------------------------------------
# 대상 노드) wheelhouse + etcd 바이너리 배치
# ----------------------------------------------------------------------------
setup_target_assets() {
  echo "==> 대상 노드 자원 배치 (wheelhouse, etcd)"
  mkdir -p "${BASE_DIR}/wheels" "${BASE_DIR}/etcd"
  cp -a "${BUNDLE_DIR}/wheels/target/." "${BASE_DIR}/wheels/"
  cp -a "${BUNDLE_DIR}/etcd/." "${BASE_DIR}/etcd/"

  # 대상 노드에 pip 가 없을 수 있으니 로컬 저장소로 설치(이후 Ansible 의 pip 모듈이 사용)
  echo "==> python3-pip 설치 (로컬 저장소)"
  dnf install -y --disablerepo='*' --enablerepo="${REPO_NAME}" python3-pip || true
  echo "    완료. (Ansible 이 offline_mode=true 로 patroni 등을 wheelhouse 에서 설치)"
}

# ----------------------------------------------------------------------------
# 컨트롤 노드) Python 3.9 venv 에 ansible-core + 컬렉션(오프라인) 설치
# ----------------------------------------------------------------------------
setup_control() {
  echo "==> 컨트롤 노드: Python 3.9 venv 에 ansible-core 설치"
  command -v python3 >/dev/null 2>&1 || { echo "오류: python3(3.9)가 필요합니다."; exit 1; }

  python3 -m venv "${BASE_DIR}/venv"
  "${BASE_DIR}/venv/bin/pip" install --no-index --find-links "${BUNDLE_DIR}/wheels/control" --upgrade pip || true
  "${BASE_DIR}/venv/bin/pip" install --no-index --find-links "${BUNDLE_DIR}/wheels/control" ansible-core

  echo "==> Ansible 컬렉션 오프라인 설치"
  # collection download 가 만든 requirements.yml 은 tarball 을 "상대경로(파일명)"로만 참조합니다.
  # 따라서 반드시 collections 디렉터리 안에서 실행해야 ansible-galaxy 가 tarball 을 찾습니다.
  ( cd "${BUNDLE_DIR}/collections" \
    && "${BASE_DIR}/venv/bin/ansible-galaxy" collection install -r requirements.yml )

  echo ""
  echo "    컨트롤 노드 준비 완료. 사용 전 venv 활성화:"
  echo "      source ${BASE_DIR}/venv/bin/activate"
  echo "      ansible --version"
  echo ""
  echo "    배포 시 offline_mode=true 를 켜고 실행하세요:"
  echo "      ansible-playbook site.yml -e offline_mode=true --ask-vault-pass"
}

# --- 역할별 실행 ------------------------------------------------------------
case "${ROLE}" in
  control)
    setup_control
    ;;
  target)
    setup_local_repo
    setup_target_assets
    ;;
  both)
    setup_local_repo
    setup_target_assets
    setup_control
    ;;
  *)
    echo "오류: --role 은 control | target | both 중 하나여야 합니다."
    exit 1
    ;;
esac

echo "==> 완료 (role=${ROLE})"
