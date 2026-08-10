#!/usr/bin/env bash
# =============================================================================
# help.sh — 이 저장소의 명령어 사용법 안내
# -----------------------------------------------------------------------------
# 자주 쓰는 명령을 주제별로 보여 줍니다. 아무 것도 바꾸지 않고 출력만 합니다.
#
#   ./help.sh              # 전체 요약 + 주제 목록
#   ./help.sh deploy       # 특정 주제만
#   ./help.sh all          # 모든 주제를 한 번에
#
# 주제: deploy verify ops tuning vault inventory airgap uninstall troubleshoot
# =============================================================================
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

# --- 색상 (터미널일 때만 사용. 파이프/리다이렉트 시 자동으로 꺼집니다) --------
if [[ -t 1 ]]; then
  B=$'\033[1m'; DIM=$'\033[2m'; C=$'\033[36m'; Y=$'\033[33m'; G=$'\033[32m'; R=$'\033[0m'
else
  B=''; DIM=''; C=''; Y=''; G=''; R=''
fi

# 실제로 쓰는 인벤토리를 고릅니다. inventory/lab.yml 처럼 환경 전용 인벤토리가
# 있으면(보통 .gitignore 대상) 그것을 우선합니다.
INV=inventory/hosts.yml
INV_OPT=""
if [[ -f inventory/lab.yml ]]; then INV=inventory/lab.yml; INV_OPT="-i inventory/lab.yml "; fi

# 경로/포트는 group_vars 에서 읽어 실제 설정과 어긋나지 않게 합니다.
# group_vars/all/ 은 알파벳 순으로 로드되며 뒤 파일이 앞을 덮으므로, 뒤에서부터
# 처음 찾은 값이 최종값입니다.
_gv() {
  local f v
  for f in $(ls -r group_vars/all/*.yml 2>/dev/null); do
    v=$(grep -E "^$1:" "$f" 2>/dev/null | sed 's/^[^:]*: *//' | awk '{print $1}' | tr -d '"')
    [[ -n $v ]] && { printf '%s' "$v"; return; }
  done
}
PATRONI_VENV=$(_gv patroni_venv_dir); PATRONI_VENV=${PATRONI_VENV:-/opt/patroni}
PATRONI_CONF=$(_gv patroni_config_dir); PATRONI_CONF=${PATRONI_CONF:-/etc/patroni}
PATRONICTL="$PATRONI_VENV/bin/patronictl -c $PATRONI_CONF/patroni.yml"
STATS_PORT=$(_gv haproxy_stats_port); STATS_PORT=${STATS_PORT:-7000}
REST_PORT=$(_gv patroni_rest_port); REST_PORT=${REST_PORT:-8008}

title()   { printf '\n%s%s%s\n' "$B" "$1" "$R"; }
section() { printf '\n%s── %s %s\n' "$C" "$1" "$R"; }
cmd()     { printf '  %s%s%s\n' "$G" "$1" "$R"; }
desc()    { printf '      %s%s%s\n' "$DIM" "$1" "$R"; }
note()    { printf '  %s%s%s\n' "$Y" "$1" "$R"; }
plain()   { printf '  %s\n' "$1"; }

# -----------------------------------------------------------------------------
# 현재 설정 요약 — group_vars / inventory 에서 그대로 읽어옵니다.
# (배포 상태가 아니라 "이 저장소가 무엇을 배포하도록 설정돼 있는지"입니다)
# -----------------------------------------------------------------------------
show_current() {
  section "현재 설정"
  plain "클러스터   $(_gv cluster_name)"
  plain "VIP        $(_gv cluster_vip)  (인터페이스 $(_gv vip_interface))"
  plain "PostgreSQL $(_gv postgresql_version)"
  local pin; pin=$(_gv postgresql_package_pin)
  [[ -n $pin ]] && plain "버전 고정   $pin"
  plain "인벤토리   $INV"
  if [[ -f $INV ]]; then
    local nodes
    nodes=$(grep -E '^\s+node_ip:' "$INV" | awk '{print $2}' | sort -u | tr '\n' ' ')
    plain "노드       ${nodes:-(없음)}"
  fi
  if [[ -f group_vars/all/vault.yml ]]; then
    if head -1 group_vars/all/vault.yml | grep -q '^\$ANSIBLE_VAULT'; then
      plain "Vault      사용 중(암호화됨) → 모든 명령에 --ask-vault-pass 필요"
    else
      note "Vault      group_vars/all/vault.yml 이 평문입니다. ansible-vault encrypt 를 권장합니다."
    fi
  else
    plain "Vault      미사용 → main.yml 의 기본 비밀번호로 배포됩니다(운영 부적합)"
  fi
}

# -----------------------------------------------------------------------------
topic_deploy() {
  title "배포"
  section "사전 확인"
  cmd "ansible ${INV_OPT}all -m ping"
  desc "모든 노드에 SSH 로 붙는지 먼저 확인합니다."
  cmd "ansible-playbook ${INV_OPT}site.yml --check --diff"
  desc "실제로 바꾸지 않고 무엇이 바뀔지만 봅니다(드라이런)."

  section "전체 배포"
  cmd "ansible-playbook ${INV_OPT}site.yml"
  desc "preflight → common → etcd → postgresql → patroni → pgbouncer → haproxy 순으로 진행하고,"
  desc "끝나면 접속 정보를 자동으로 출력합니다."
  cmd "ansible-playbook site.yml --ask-vault-pass"
  desc "Vault 를 쓰는 경우."

  section "일부만 배포 (--tags)"
  cmd "ansible-playbook site.yml --tags etcd,patroni"
  cmd "ansible-playbook site.yml --tags haproxy"
  cmd "ansible-playbook site.yml --limit pg-node-2"
  desc "사용 가능한 태그: common etcd postgresql patroni pgbackrest pgbouncer haproxy info"
  note "preflight(토폴로지 검증)는 always 태그라 어떤 --tags 를 줘도 항상 먼저 실행됩니다."
}

topic_verify() {
  title "확인 · 검증"
  section "접속 정보"
  cmd "ansible-playbook ${INV_OPT}playbooks/connection-info.yml"
  desc "애플리케이션 접속 문자열, 노드별 주소, 운영 인터페이스, 현재 리더를 한 화면에 출력."
  cmd "ansible-playbook playbooks/connection-info.yml -e show_passwords=true"
  desc "비밀번호를 실제 값으로 출력(기본은 ******** 로 가림)."

  section "동작 검증 (스모크 테스트)"
  cmd "ansible-playbook ${INV_OPT}playbooks/verify-cluster.yml"
  desc "VIP 로 실제 SQL 을 날려 라우팅·복제까지 검증합니다. 실패 시 종료 코드가 0이 아니므로"
  desc "CI 파이프라인에 그대로 연결할 수 있습니다."
  cmd "ansible-playbook playbooks/verify-cluster.yml --tags sql"
  cmd "ansible-playbook playbooks/verify-cluster.yml --skip-tags replication"
  desc "운영 DB 에 쓰기가 부담되면 replication 검사를 빼세요(임시 테이블 생성/삭제를 안 함)."
  plain ""
  plain "검증 태그"
  desc "services     노드별 systemd 서비스가 모두 active 인가"
  desc "etcd         etcd 멤버 전원이 healthy 한가 (정족수)"
  desc "patroni      리더가 정확히 1대이고 모든 멤버가 정상 상태인가"
  desc "vip          VIP 가 정확히 한 노드에만 떠 있는가"
  desc "sql          쓰기 포트→리더, 읽기 포트→복제본으로 라우팅되는가"
  desc "replication  리더에 쓴 행이 모든 복제본에 전파되는가"

  section "상태만 빠르게"
  cmd "ansible-playbook playbooks/cluster-status.yml"
  desc "patronictl list 결과(누가 리더인지, 복제 지연은 얼마인지)."
  cmd "sudo -u postgres $PATRONICTL list"
  desc "노드에 직접 들어가서 볼 때."
}

topic_ops() {
  title "운영"
  section "리더 전환 · 재시작"
  cmd "ansible-playbook playbooks/switchover.yml -e target_leader=pg-node-2"
  desc "점검 등으로 리더를 계획적으로 옮깁니다(장애 상황이 아닐 때)."
  cmd "ansible-playbook playbooks/restart-postgresql.yml"
  desc "복제본 먼저 → 리더 마지막 순서로 롤링 재시작."
  cmd "ansible-playbook playbooks/restart-postgresql.yml -e only_pending=true"
  desc "'pending restart' 로 표시된 노드만 재시작."

  section "노드에서 직접 (patronictl)"
  plain "PATRONICTL=\"sudo -u postgres $PATRONICTL\""
  cmd "\$PATRONICTL list"
  cmd "\$PATRONICTL switchover"
  cmd "\$PATRONICTL failover"
  desc "failover 는 리더가 이미 죽었을 때. 살아있으면 switchover 를 쓰세요."
  cmd "\$PATRONICTL reinit <클러스터> <노드>"
  desc "복제가 깨진 복제본을 리더에서 다시 받아 복구합니다(해당 노드 데이터 삭제 후 재동기화)."

  section "서비스 · 로그"
  cmd "ansible all -m shell -a 'systemctl is-active etcd patroni pgbouncer haproxy keepalived'"
  cmd "journalctl -u patroni -f"
  cmd "journalctl -u etcd -n 100 --no-pager"
}

topic_tuning() {
  title "튜닝 · 설정 변경"
  note "postgresql.conf 를 직접 고치면 안 됩니다. Patroni 가 DCS(etcd)의 설정으로 덮어씁니다."
  cmd "ansible-playbook playbooks/apply-tuning.yml"
  desc "group_vars 의 튜닝 값을 실행 중 클러스터에 반영(patronictl edit-config → reload)."
  cmd "ansible-playbook playbooks/apply-tuning.yml -e postgresql_tuning_profile=medium"
  cmd "ansible-playbook playbooks/apply-tuning.yml -e postgresql_max_connections=500"
  cmd "ansible-playbook playbooks/apply-tuning.yml -e patroni_synchronous_mode=true"
  desc "동기 복제 켜기/끄기는 재시작 없이 적용됩니다."
  cmd "ansible-playbook playbooks/apply-tuning.yml -e restart_after_apply=true"
  desc "shared_buffers·max_connections 처럼 재시작이 필요한 값을 바꿨을 때."

  section "접속 허용 대역 변경"
  desc "group_vars/all/main.yml 의 postgresql_allowed_cidrs 를 고친 뒤:"
  cmd "ansible-playbook site.yml --tags patroni"
  desc "Patroni 가 pg_hba.conf 를 다시 쓰고 reload 합니다(재시작 없음)."
}

topic_vault() {
  title "Vault (비밀번호 관리)"
  section "새로 만들기"
  cmd "cp group_vars/vault.yml.example group_vars/all/vault.yml"
  note "반드시 group_vars/all/ 안에 두세요. group_vars/vault.yml 은 조용히 무시됩니다"
  note "(Ansible 은 group_vars/ 밑의 파일명을 '그룹 이름'으로 해석하는데 vault 그룹은 없음)."
  desc "편집기로 8개 비밀번호를 채운 뒤:"
  cmd "ansible-vault encrypt group_vars/all/vault.yml"
  desc "이때 입력하는 'New Vault password' 는 DB 비밀번호가 아니라, 그 파일을 잠그는"
  desc "마스터 열쇠입니다. 직접 정하고 따로 보관하세요(분실 시 복구 불가)."

  section "사용"
  cmd "ansible-playbook site.yml --ask-vault-pass"
  cmd "echo 'my-vault-password' > ~/.vault_pass.txt && chmod 600 ~/.vault_pass.txt"
  cmd "ansible-playbook site.yml --vault-password-file ~/.vault_pass.txt"
  desc "비밀번호 파일은 저장소 밖(홈 디렉터리)에 두세요."

  section "다루기"
  cmd "ansible-vault view group_vars/all/vault.yml"
  cmd "ansible-vault edit group_vars/all/vault.yml"
  cmd "ansible-vault rekey group_vars/all/vault.yml"
  note "'Attempting to decrypt but no vault secrets found' 오류는 암호화된 vault.yml 이 있는데"
  note "비밀번호를 안 줬다는 뜻입니다. --ask-vault-pass 를 붙이세요."
}

topic_inventory() {
  title "인벤토리 · 변수"
  cmd "ansible-inventory --graph"
  desc "어떤 노드가 어떤 그룹(etcd/patroni_cluster/pgbouncer/haproxy)에 속하는지."
  cmd "ansible-inventory --host pg-node-1"
  cmd "ansible pg-node-1 -m debug -a 'var=cluster_vip'"
  desc "특정 변수가 최종적으로 어떤 값으로 해석되는지 확인."
  plain ""
  plain "고쳐야 할 파일"
  desc "inventory/hosts.yml       노드 IP·역할·keepalived 우선순위(저장소 기본=문서용 예시)"
  desc "inventory/lab.yml         실제 환경 인벤토리(있으면 이 스크립트가 자동으로 우선)"
  desc "group_vars/all/main.yml   VIP·버전·튜닝·접근 대역 등 전역 설정"
  desc "group_vars/all/vault.yml  비밀번호(직접 생성, 커밋 금지)"
}

topic_airgap() {
  title "폐쇄망(air-gap)"
  section "번들 만들기 (인터넷 되는 곳에서)"
  cmd "./scripts/airgap-build-bundle.sh"
  desc "RPM·wheel·etcd 바이너리를 한 덩어리로 묶습니다."

  section "설치 (폐쇄망에서, 번들 푼 디렉터리에서)"
  cmd "sudo ./scripts/airgap-install.sh --role control"
  desc "컨트롤 노드: ansible-core + 컬렉션을 오프라인 설치."
  cmd "sudo ./scripts/airgap-install.sh --role target"
  desc "대상 노드: 로컬 dnf 저장소 + wheelhouse + etcd 배치."
  cmd "sudo ./scripts/airgap-install.sh --role both"
  desc "한 노드가 컨트롤 겸 대상일 때."

  section "배포"
  cmd "ansible-playbook site.yml -e offline_mode=true"
  desc "인터넷 저장소를 건드리지 않고 로컬 번들 저장소만 사용합니다."
}

topic_uninstall() {
  title "언인스톨 (전부 걷어내기)"
  note "경고: 되돌릴 수 없습니다. PostgreSQL 데이터·etcd 데이터·pgBackRest 백업이 모두 삭제됩니다."
  note "안전장치로 -e confirm_uninstall=yes 없이는 목록만 출력하고 멈춥니다."

  section "실행"
  cmd "ansible-playbook ${INV_OPT}playbooks/uninstall.yml"
  desc "무엇이 지워지는지 목록만 확인(실제로는 아무 것도 하지 않음)."
  cmd "ansible-playbook ${INV_OPT}playbooks/uninstall.yml -e confirm_uninstall=yes"
  desc "서비스 중지 → DCS 키 삭제 → 패키지 제거 → 설정·데이터 삭제 → 시스템 설정 원복."

  section "부분만"
  cmd "ansible-playbook playbooks/uninstall.yml -e confirm_uninstall=yes -e uninstall_remove_packages=false"
  desc "패키지는 남기고 설정·데이터만 초기화(재설치를 빠르게 하고 싶을 때)."
  cmd "ansible-playbook playbooks/uninstall.yml -e confirm_uninstall=yes -e uninstall_remove_users=false"
  desc "서비스 계정(etcd/postgres/pgbouncer)은 남깁니다."
  cmd "ansible-playbook playbooks/uninstall.yml -e confirm_uninstall=yes --tags files"
  desc "사용 가능한 태그: services dcs packages files users system"

  section "확인"
  cmd "ansible all -m shell -a 'systemctl is-active etcd patroni pgbouncer haproxy keepalived'"
  desc "모두 inactive/unknown 이면 정상적으로 걷힌 것입니다."
  note "chrony·python3-pip 같은 OS 공용 패키지는 일부러 남깁니다."
  note "sysctl 값은 설정 파일에서만 제거되며, 실행 중인 커널 값은 재부팅 후 기본값으로 돌아갑니다."
}

topic_troubleshoot() {
  title "문제 해결"
  section "자주 겪는 것"
  plain "No package postgresql16-server available"
  desc "PGDG 저장소 문제입니다. .repo 파일이 지워졌는지 확인:"
  cmd "ansible all -m shell -a 'rpm -V pgdg-redhat-repo'"
  desc "'missing ... .repo' 가 나오면 site.yml --tags postgresql 이 자동 복구합니다."
  plain ""
  plain "nothing provides libcrypto.so.3(OPENSSL_3.4.0)"
  desc "OS 마이너 버전보다 최신인 PGDG 빌드를 고른 경우입니다. 맞는 버전으로 고정하세요:"
  cmd "ansible <노드> -m shell -a 'dnf --showduplicates list postgresql16-server'"
  desc "group_vars/all/main.yml 의 postgresql_package_pin 에 지정(RHEL 9.4 검증: 16.14-1PGDG.rhel9.6)."
  plain ""
  plain "Attempting to decrypt but no vault secrets found"
  desc "→ ./help.sh vault"
  plain ""
  plain "VIP 로 접속이 안 됨"
  cmd "ansible-playbook playbooks/verify-cluster.yml --tags vip,sql"
  desc "VIP 보유 노드가 0대면 keepalived, 2대 이상이면 방화벽의 VRRP(프로토콜 112) 허용을 확인."

  section "정보 수집"
  cmd "ansible-playbook playbooks/verify-cluster.yml"
  desc "어느 계층이 깨졌는지 가장 빠르게 좁혀 줍니다."
  cmd "curl -s http://<노드IP>:$REST_PORT/ | python3 -m json.tool"
  desc "Patroni REST 로 해당 노드가 스스로를 어떻게 보는지 확인."
  cmd "curl -s 'http://haproxy_admin:<비번>@<노드IP>:$STATS_PORT/;csv'"
  desc "HAProxy 가 각 백엔드를 UP/DOWN 중 무엇으로 보는지."
}

usage() {
  title "Patroni PostgreSQL HA — 명령어 사용법"
  plain "사용법:  ./help.sh [주제]"
  plain ""
  plain "주제"
  desc "deploy        배포 (전체/부분/드라이런)"
  desc "verify        접속 정보 출력 · 동작 검증 · 상태 확인"
  desc "ops           리더 전환 · 롤링 재시작 · patronictl · 로그"
  desc "tuning        튜닝 파라미터 적용 · 접속 허용 대역 변경"
  desc "vault         비밀번호 생성 · 암호화 · 사용"
  desc "inventory     인벤토리/변수 확인과 수정 위치"
  desc "airgap        폐쇄망 번들 빌드 · 설치 · 배포"
  desc "uninstall     전부 걷어내기(데이터 삭제 — 되돌릴 수 없음)"
  desc "troubleshoot  자주 겪는 오류와 대처"
  desc "all           위 전부를 한 번에"
  show_current
  section "가장 자주 쓰는 3개"
  cmd "ansible-playbook ${INV_OPT}site.yml"
  cmd "ansible-playbook ${INV_OPT}playbooks/verify-cluster.yml"
  cmd "ansible-playbook ${INV_OPT}playbooks/connection-info.yml"
  printf '\n%s자세한 설명은 README.md 를 보세요.%s\n\n' "$DIM" "$R"
}

case "${1:-}" in
  ""|-h|--help|help) usage ;;
  deploy)            topic_deploy ;;
  verify)            topic_verify ;;
  ops)               topic_ops ;;
  tuning)            topic_tuning ;;
  vault)             topic_vault ;;
  inventory)         topic_inventory ;;
  airgap)            topic_airgap ;;
  uninstall)         topic_uninstall ;;
  troubleshoot)      topic_troubleshoot ;;
  all)
    topic_deploy; topic_verify; topic_ops; topic_tuning
    topic_vault; topic_inventory; topic_airgap; topic_uninstall
    topic_troubleshoot
    ;;
  *)
    printf '%s알 수 없는 주제: %s%s\n' "$Y" "$1" "$R" >&2
    usage >&2
    exit 1
    ;;
esac

printf '\n'
