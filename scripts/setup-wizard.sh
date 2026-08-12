#!/usr/bin/env bash
# =============================================================================
# setup-wizard.sh — 대화형 설정 마법사
# -----------------------------------------------------------------------------
# group_vars/all/main.yml 을 직접 손대다 값을 빠뜨려서 배포가 깨지는 일을 막기
# 위한 스크립트입니다. 필요한 값만 물어보고, "실제 노드에 접속해 확인"한 뒤
# 환경 전용 파일 두 개를 만들어 줍니다.
#
#   inventory/lab.yml            ← 노드 목록 (.gitignore 대상)
#   group_vars/all/zz-lab.yml    ← 이 환경의 변수 override (.gitignore 대상)
#
# 저장소 기본값(inventory/hosts.yml, group_vars/all/main.yml)은 공개용 예시라
# 건드리지 않습니다. group_vars/all/ 은 파일명 알파벳 순으로 로드되므로
# zz- 접두사가 main.yml 을 덮어씁니다.
#
# 핵심: 값을 "묻기만" 하지 않고 노드에서 직접 확인합니다.
#   - VIP 를 붙일 NIC 이름을 노드에서 읽어옵니다 (eth0/enp1s0 실수 원천 차단)
#   - VIP 가 노드와 같은 서브넷인지, 남이 이미 쓰고 있지 않은지 확인
#   - 접속 허용 대역을 노드 IP 에서 자동 산출
#   - OS/파이썬/sudo 사용 가능 여부를 미리 점검
#
# 사용법:
#   ./scripts/setup-wizard.sh              # 대화형 실행
#   ./scripts/setup-wizard.sh --dry-run    # 파일을 쓰지 않고 결과만 미리보기
#   ./scripts/setup-wizard.sh --deploy     # 설정 후 곧바로 site.yml 까지 실행
#
# 다시 실행하면 기존 파일의 값을 기본값으로 제시하므로 일부만 고칠 수 있습니다.
# =============================================================================
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# --- 색상 (터미널일 때만) ----------------------------------------------------
if [[ -t 1 ]]; then
  B=$'\033[1m'; DIM=$'\033[2m'; C=$'\033[36m'; Y=$'\033[33m'; G=$'\033[32m'; E=$'\033[31m'; R=$'\033[0m'
else
  B=''; DIM=''; C=''; Y=''; G=''; E=''; R=''
fi

INV_FILE=inventory/lab.yml
VAR_FILE=group_vars/all/zz-lab.yml
DRY_RUN=false
RUN_DEPLOY=false

for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=true ;;
    --deploy)  RUN_DEPLOY=true ;;
    -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "${E}알 수 없는 옵션: $a${R}"; exit 1 ;;
  esac
done

say()  { echo "$*"; }
head1() { echo; echo "${B}$*${R}"; echo "${DIM}$(printf '─%.0s' {1..70})${R}"; }
ok()   { echo "  ${G}✓${R} $*"; }
warn() { echo "  ${Y}!${R} $*"; }
err()  { echo "  ${E}✗${R} $*"; }
die()  { echo; echo "${E}중단: $*${R}"; exit 1; }

# =============================================================================
# 입력 도우미
# =============================================================================

# ask <변수명> <질문> <기본값>
ask() {
  local __var=$1 prompt=$2 def=${3:-} input
  if [[ -n "$def" ]]; then
    read -r -p "  ${prompt} ${DIM}[${def}]${R}: " input || die "입력이 끊겼습니다(EOF)."
    input=${input:-$def}
  else
    while :; do
      # EOF(파이프 입력 소진 등)에서 무한 루프에 빠지지 않도록 즉시 중단합니다.
      read -r -p "  ${prompt}: " input || die "입력이 끊겼습니다(EOF). 이 스크립트는 대화형으로 실행하세요."
      [[ -n "$input" ]] && break
      echo "    ${Y}값을 입력하세요.${R}"
    done
  fi
  printf -v "$__var" '%s' "$input"
}

# ask_yn <질문> <기본 y|n>  → 0(yes) / 1(no)
ask_yn() {
  local prompt=$1 def=${2:-y} input hint
  [[ $def == y ]] && hint="Y/n" || hint="y/N"
  read -r -p "  ${prompt} ${DIM}[${hint}]${R}: " input || die "입력이 끊겼습니다(EOF)."
  input=${input:-$def}
  [[ ${input,,} == y* ]]
}

# 비밀번호: 빈 입력이면 안전한 임의 문자열을 만들어 줍니다.
# 특수문자는 pgbouncer userlist / 접속 문자열에서 자주 문제를 일으켜 영숫자만 씁니다.
gen_pw() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-20}"; }

ask_pw() {
  local __var=$1 label=$2 def=${3:-} len=${4:-20} input
  if [[ -n "$def" ]]; then
    read -r -s -p "  ${label} ${DIM}[기존 값 유지 — Enter]${R}: " input || die "입력이 끊겼습니다(EOF)."; echo
    input=${input:-$def}
  else
    read -r -s -p "  ${label} ${DIM}[Enter = 자동 생성]${R}: " input || die "입력이 끊겼습니다(EOF)."; echo
    if [[ -z "$input" ]]; then
      input=$(gen_pw "$len")
      echo "    ${DIM}자동 생성됨 (${#input}자)${R}"
    fi
  fi
  printf -v "$__var" '%s' "$input"
}

# YAML 문자열 안전 인용 — 작은따옴표로 감싸고 내부 작은따옴표는 두 번 반복
yq() { local s=${1//\'/\'\'}; printf "'%s'" "$s"; }

# 터미널 표시 폭. 한글·CJK 는 두 칸을 차지하므로 printf 의 %-Ns 로는 정렬이
# 어긋납니다. 폭을 직접 세어 패딩합니다.
dwidth() {
  local s=$1 w=0 i c
  for (( i=0; i<${#s}; i++ )); do
    c=${s:i:1}
    case $c in
      [가-힣ㄱ-ㅎㅏ-ㅣ一-鿿ぁ-ゟ゠-ヿ]) w=$((w+2)) ;;
      *) w=$((w+1)) ;;
    esac
  done
  echo "$w"
}

# 레이블을 표시 폭 기준으로 정렬해 한 줄 출력
row() {
  # 주의: local 한 줄에서 앞의 변수를 참조하면 안 됩니다. bash 는 대입 전에
  # 줄 전체를 확장하므로 set -u 아래에서 "unbound variable" 이 납니다.
  local label=$1 value=$2 width=${3:-22} pad
  pad=$(( width - $(dwidth "$label") ))
  (( pad < 1 )) && pad=1
  printf "  %s%*s %s\n" "$label" "$pad" "" "$value"
}

valid_ip() {
  local ip=$1 o
  [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS='.' read -r -a o <<<"$ip"
  for x in "${o[@]}"; do ((x >= 0 && x <= 255)) || return 1; done
  return 0
}

# IP 를 32비트 정수로 (서브넷 비교용)
ip2int() { local IFS='.'; read -r -a o <<<"$1"; echo $(( (o[0]<<24) + (o[1]<<16) + (o[2]<<8) + o[3] )); }

same_subnet() {  # <ip1> <ip2> <prefix>
  local m=$(( 0xFFFFFFFF << (32 - $3) & 0xFFFFFFFF ))
  (( ($(ip2int "$1") & m) == ($(ip2int "$2") & m) ))
}

network_of() {   # <ip> <prefix> → a.b.c.d/prefix
  local m=$(( 0xFFFFFFFF << (32 - $2) & 0xFFFFFFFF ))
  local n=$(( $(ip2int "$1") & m ))
  echo "$(( (n>>24)&255 )).$(( (n>>16)&255 )).$(( (n>>8)&255 )).$(( n&255 ))/$2"
}

# 기존 파일에서 `키: 값` 을 읽어 재실행 시 기본값으로 씁니다.
prev() {  # <파일> <키> <대체 기본값>
  local f=$1 k=$2 d=${3:-} v=""
  [[ -f $f ]] && v=$(sed -nE "s/^${k}:[[:space:]]*//p" "$f" | head -1 | sed -E 's/[[:space:]]*#.*$//; s/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/')
  echo "${v:-$d}"
}

# =============================================================================
say
say "${B}┌────────────────────────────────────────────────────────────┐${R}"
say "${B}│  Patroni PostgreSQL HA — 설정 마법사                       │${R}"
say "${B}└────────────────────────────────────────────────────────────┘${R}"
say "${DIM}  값을 입력하면 실제 노드에 접속해 확인한 뒤 설정 파일을 만듭니다.${R}"
say "${DIM}  Enter 만 누르면 [대괄호] 안의 기본값이 쓰입니다. 중단은 Ctrl+C.${R}"
$DRY_RUN && say "  ${Y}--dry-run: 파일을 쓰지 않고 결과만 보여 줍니다.${R}"

command -v ansible >/dev/null || die "ansible 이 없습니다. 먼저 설치하세요."

# =============================================================================
head1 "1/6  노드 목록"
# =============================================================================
say "${DIM}  DB(Patroni) 노드의 IP 를 공백으로 구분해 입력하세요. 2대 이상, 홀수 권장.${R}"

DEF_IPS=$(sed -nE 's/^[[:space:]]+node_ip:[[:space:]]*([0-9.]+).*/\1/p' "$INV_FILE" 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ $//')
while :; do
  ask NODE_IPS_RAW "DB 노드 IP 들" "$DEF_IPS"
  read -r -a NODE_IPS <<<"$NODE_IPS_RAW"
  bad=false
  for ip in "${NODE_IPS[@]}"; do valid_ip "$ip" || { err "IP 형식이 아닙니다: $ip"; bad=true; }; done
  (( ${#NODE_IPS[@]} < 2 )) && { err "최소 2대가 필요합니다."; bad=true; }
  $bad || break
done

ask NODE_PREFIX "노드 이름 접두사" "pg-node"
ask SSH_USER    "SSH 접속 계정" "$(prev "$INV_FILE" '    ansible_user' root)"

NODE_NAMES=()
for i in "${!NODE_IPS[@]}"; do NODE_NAMES+=("${NODE_PREFIX}-$((i+1))"); done

say
for i in "${!NODE_IPS[@]}"; do say "    ${NODE_NAMES[$i]} → ${NODE_IPS[$i]}"; done

if (( ${#NODE_IPS[@]} % 2 == 0 )); then
  warn "노드가 짝수(${#NODE_IPS[@]}대)입니다. etcd 정족수 확보를 위해 홀수를 권장합니다."
fi

# etcd 배치
say
if ask_yn "etcd 를 DB 노드에 함께 올릴까요(co-location)?" y; then
  ETCD_COLOCATED=true
  (( ${#NODE_IPS[@]} < 3 )) && die "co-location 이면 etcd 정족수 때문에 노드가 3대 이상이어야 합니다."
else
  ETCD_COLOCATED=false
  while :; do
    ask ETCD_IPS_RAW "전용 etcd 노드 IP 3개"
    read -r -a ETCD_IPS <<<"$ETCD_IPS_RAW"
    bad=false
    for ip in "${ETCD_IPS[@]}"; do valid_ip "$ip" || { err "IP 형식이 아닙니다: $ip"; bad=true; }; done
    (( ${#ETCD_IPS[@]} % 2 == 0 )) && { err "홀수여야 합니다(3, 5 ...)."; bad=true; }
    $bad || break
  done
fi

# =============================================================================
head1 "2/6  노드 점검 — 실제로 접속해서 확인합니다"
# =============================================================================
PROBE_INV=$(mktemp)
trap 'rm -f "$PROBE_INV" "${PROBE_INV}.out" 2>/dev/null' EXIT
{
  echo "all:"
  echo "  vars:"
  echo "    ansible_user: $SSH_USER"
  echo "  hosts:"
  for i in "${!NODE_IPS[@]}"; do
    echo "    ${NODE_NAMES[$i]}:"
    echo "      ansible_host: ${NODE_IPS[$i]}"
  done
} >"$PROBE_INV"

say "${DIM}  ${#NODE_IPS[@]}대에 접속해 NIC 이름·OS·sudo 를 확인하는 중...${R}"

# 노드에서 실행할 점검 스크립트. 따옴표 중첩으로 깨지지 않도록 파일에 담아
# `ssh ... bash -s` 로 흘려 보냅니다(스크립트 자신의 stdin 은 건드리지 않음).
PROBE_SH=$(mktemp)
trap 'rm -f "$PROBE_INV" "$PROBE_SH" 2>/dev/null' EXIT
cat >"$PROBE_SH" <<'PROBE_EOF'
# 자기 IP 가 실제로 붙어 있는 NIC 을 찾습니다. VIP 도 같은 NIC 에 붙어야 합니다.
me=$(ip -4 -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
[ -z "$me" ] && me=$(hostname -I | awk '{print $1}')
read -r nic cidr <<EOS
$(ip -4 -o addr show scope global | awk -v ip="$me" '$4 ~ "^"ip"/" {print $2, $4; exit}')
EOS
os=$( . /etc/os-release 2>/dev/null; echo "${ID:-?} ${VERSION_ID:-?}" )
sudook=no; sudo -n true 2>/dev/null && sudook=yes
[ "$(id -u)" = "0" ] && sudook=yes
py=no; command -v python3 >/dev/null 2>&1 && py=yes
allips=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | paste -sd, -)
echo "PROBE|nic=${nic}|pfx=${cidr#*/}|ip=${me}|os=${os}|sudo=${sudook}|py=${py}|all=${allips}"
PROBE_EOF

declare -A NIC_OF PFX_OF OS_OF ALLIPS_OF
UNREACHABLE=()
for i in "${!NODE_IPS[@]}"; do
  n=${NODE_NAMES[$i]}; ip=${NODE_IPS[$i]}
  out=$(ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
           "${SSH_USER}@${ip}" bash -s <"$PROBE_SH" 2>/dev/null | grep '^PROBE|')
  if [[ -z $out ]]; then UNREACHABLE+=("$n ($ip)"); continue; fi
  NIC_OF[$n]=$(sed -n 's/.*|nic=\([^|]*\).*/\1/p' <<<"$out")
  PFX_OF[$n]=$(sed -n 's/.*|pfx=\([^|]*\).*/\1/p' <<<"$out")
  OS_OF[$n]=$(sed -n 's/.*|os=\([^|]*\).*/\1/p' <<<"$out")
  ALLIPS_OF[$n]=$(sed -n 's/.*|all=\([^|]*\).*/\1/p' <<<"$out")
  [[ $(sed -n 's/.*|sudo=\([^|]*\).*/\1/p' <<<"$out") == yes ]] || \
    warn "${n}: 무패스워드 sudo 불가 — 배포가 실패합니다. sudoers 를 먼저 정리하세요."
  [[ $(sed -n 's/.*|py=\([^|]*\).*/\1/p' <<<"$out") == yes ]] || \
    warn "${n}: python3 이 없습니다 — Ansible 이 동작하지 않습니다."
done

if (( ${#UNREACHABLE[@]} > 0 )); then
  err "SSH 접속 실패: ${UNREACHABLE[*]}"
  say "${DIM}    ssh ${SSH_USER}@<IP> 로 직접 붙어 키 인증이 되는지 확인하세요.${R}"
  die "모든 노드에 접속돼야 진행할 수 있습니다."
fi

for n in "${NODE_NAMES[@]}"; do
  ok "${n}: NIC=${B}${NIC_OF[$n]:-?}${R}  prefix=/${PFX_OF[$n]:-?}  OS=${OS_OF[$n]:-?}"
done

# Ansible 이 실제로 붙는지도 확인합니다(SSH 는 되는데 python/인터프리터 문제로
# Ansible 만 실패하는 경우를 배포 전에 잡아냅니다).
if ansible -i "$PROBE_INV" all -m ping >/dev/null 2>&1 </dev/null; then
  ok "Ansible 연결 확인 (${SSH_USER})"
else
  warn "Ansible 연결에 실패했습니다. 배포 전에 다음으로 원인을 확인하세요:"
  say  "${DIM}    ansible -i ${INV_FILE} all -m ping${R}"
fi

# NIC 이름이 노드마다 다르면 keepalived 설정이 한쪽에서 깨집니다.
NICS=$(printf '%s\n' "${NIC_OF[@]}" | sort -u)
if (( $(wc -l <<<"$NICS") > 1 )); then
  warn "노드별 NIC 이름이 다릅니다: $(tr '\n' ' ' <<<"$NICS")"
  warn "keepalived 는 노드마다 같은 이름을 기대합니다. 인벤토리에서 노드별로 vip_interface 를 따로 주세요."
  DETECTED_NIC=${NIC_OF[${NODE_NAMES[0]}]}
else
  DETECTED_NIC=$NICS
fi
DETECTED_PFX=${PFX_OF[${NODE_NAMES[0]}]:-24}

# =============================================================================
head1 "3/6  VIP (가상 IP)"
# =============================================================================
say "${DIM}  클라이언트가 바라볼 대표 IP 입니다. keepalived 가 현재 리더 노드에 붙입니다.${R}"

while :; do
  ask CLUSTER_VIP "VIP 주소" "$(prev "$VAR_FILE" cluster_vip)"
  valid_ip "$CLUSTER_VIP" || { err "IP 형식이 아닙니다."; continue; }

  # 노드와 같은 서브넷이어야 VIP 가 동작합니다.
  if ! same_subnet "$CLUSTER_VIP" "${NODE_IPS[0]}" "$DETECTED_PFX"; then
    err "VIP 가 노드와 다른 서브넷입니다 (노드: $(network_of "${NODE_IPS[0]}" "$DETECTED_PFX"))."
    ask_yn "그래도 이 값을 쓸까요?" n || continue
  fi

  # 노드 IP 와 겹치면 안 됩니다.
  clash=false
  for ip in "${NODE_IPS[@]}"; do [[ $CLUSTER_VIP == "$ip" ]] && clash=true; done
  $clash && { err "노드 IP 와 겹칩니다."; continue; }

  # 이미 남이 쓰고 있는 주소인지 확인.
  # 점검 단계에서 각 노드의 IP 목록을 모아 뒀으므로, 우리 노드가 이미 VIP 를
  # 들고 있는 경우(= 기존 배포)와 외부 장비가 쓰는 경우를 구분할 수 있습니다.
  vip_on_cluster=false
  for n in "${NODE_NAMES[@]}"; do
    [[ ,${ALLIPS_OF[$n]:-}, == *,${CLUSTER_VIP},* ]] && { vip_on_cluster=true; VIP_HOLDER=$n; }
  done
  if $vip_on_cluster; then
    ok "VIP 가 이미 ${VIP_HOLDER} 에 붙어 있습니다(기존 배포). 그대로 씁니다."
  elif ping -c1 -W1 "$CLUSTER_VIP" >/dev/null 2>&1; then
    err "이 IP 는 클러스터 밖의 누군가가 이미 쓰고 있습니다(ping 응답)."
    ask_yn "그래도 이 값을 쓸까요?" n || continue
  else
    ok "사용 중이지 않은 주소입니다."
  fi
  break
done

ask CLUSTER_VIP_CIDR "VIP 프리픽스 길이" "$DETECTED_PFX"

# 자동 감지된 NIC 을 기본값으로 제시합니다 — 이번 사고(eth0)의 재발 방지 지점.
say
ok "노드에서 감지한 NIC: ${B}${DETECTED_NIC}${R}"
ask VIP_INTERFACE "VIP 를 붙일 NIC" "$DETECTED_NIC"
if [[ $VIP_INTERFACE != "$DETECTED_NIC" ]]; then
  warn "감지값(${DETECTED_NIC})과 다릅니다. 존재하지 않는 NIC 이면 keepalived 가 기동에 실패합니다."
  ask_yn "그래도 진행할까요?" n || VIP_INTERFACE=$DETECTED_NIC
fi

# =============================================================================
head1 "4/6  클러스터 · 접속 허용 대역"
# =============================================================================
ask CLUSTER_NAME "Patroni 클러스터 이름" "$(prev "$VAR_FILE" cluster_name "$(prev group_vars/all/main.yml cluster_name pg-ha-cluster)")"
ask PG_VERSION   "PostgreSQL 메이저 버전" "$(prev "$VAR_FILE" postgresql_version "$(prev group_vars/all/main.yml postgresql_version 16)")"

say
say "${DIM}  DB 접속을 허용할 대역입니다(pg_hba.conf). 노드 IP 에서 자동 산출했습니다.${R}"
AUTO_CIDR=$(network_of "${NODE_IPS[0]}" "$DETECTED_PFX")
ask ALLOWED_CIDRS_RAW "허용 대역 (공백 구분)" "$AUTO_CIDR"
read -r -a ALLOWED_CIDRS <<<"$ALLOWED_CIDRS_RAW"

say
ask TUNING_PROFILE "튜닝 프로파일 ${DIM}(minimal|oltp|olap|mixed)${R}" "$(prev "$VAR_FILE" postgresql_tuning_profile "$(prev group_vars/all/main.yml postgresql_tuning_profile minimal)")"

# --- 설치 가능한 PostgreSQL 빌드 자동 결정 -----------------------------------
# PGDG 최신 빌드는 OS 보다 새로운 OpenSSL 을 요구하는 경우가 있습니다.
# (예: RHEL 9.4 = OpenSSL 3.0 인데 PGDG rhel9.7/9.8 빌드는 OPENSSL_3.4.0 요구)
# 빌드 이름의 rhelX.Y 접미사로는 판별할 수 없어서 — rhel9.7 빌드가 9.7 에서도
# 실패합니다 — 노드에서 실제로 depsolve 를 돌려 설치 가능한 최신 빌드를 찾습니다.
PKG_PIN=$(prev "$VAR_FILE" postgresql_package_pin)
say
say "${DIM}  설치 가능한 PostgreSQL ${PG_VERSION} 빌드를 노드에서 확인하는 중...${R}"

PGCHECK_SH=$(mktemp)
cat >"$PGCHECK_SH" <<PGEOF
V=${PG_VERSION}
SUDO=""; [ "\$(id -u)" != "0" ] && SUDO="sudo -n"
# PGDG 저장소가 아직 없으면 판정할 수 없습니다(최초 배포 전).
if ! \$SUDO dnf --showduplicates list "postgresql\${V}-server" >/dev/null 2>&1; then
  echo "PGCHECK|state=norepo"; exit 0
fi
vers=\$(\$SUDO dnf --showduplicates list "postgresql\${V}-server" 2>/dev/null \\
       | awk '/postgresql/ {print \$2}' | sort -Vr | head -8)
best=""; latest=\$(echo "\$vers" | head -1)
for v in \$vers; do
  out=\$(\$SUDO dnf --assumeno install "postgresql\${V}-server-\$v" "postgresql\${V}-contrib-\$v" 2>&1)
  # --assumeno 는 depsolve 가 성공해도 종료코드 1 이므로 메시지로 판정합니다.
  if ! echo "\$out" | grep -qiE 'Depsolve Error|nothing provides|no match for argument'; then
    best="\$v"; break
  fi
done
echo "PGCHECK|state=ok|best=\${best}|latest=\${latest}"
PGEOF

PGCHECK_OUT=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "${SSH_USER}@${NODE_IPS[0]}" \
                bash -s <"$PGCHECK_SH" 2>/dev/null | grep '^PGCHECK|')
rm -f "$PGCHECK_SH"

PG_STATE=$(sed -n 's/.*|state=\([^|]*\).*/\1/p' <<<"$PGCHECK_OUT")
PG_BEST=$(sed -n 's/.*|best=\([^|]*\).*/\1/p' <<<"$PGCHECK_OUT")
PG_LATEST=$(sed -n 's/.*|latest=\([^|]*\).*/\1/p' <<<"$PGCHECK_OUT")

if [[ $PG_STATE == ok && -n $PG_BEST ]]; then
  if [[ $PG_BEST == "$PG_LATEST" ]]; then
    ok "최신 빌드(${PG_LATEST})가 설치 가능합니다 — 버전 고정이 필요 없습니다."
    PKG_PIN=""
  else
    warn "최신 빌드(${PG_LATEST})는 이 OS 에 설치할 수 없습니다(OpenSSL 요구 불일치)."
    ok  "설치 가능한 최신 빌드: ${B}${PG_BEST}${R} — 이 값으로 고정합니다."
    PKG_PIN=$PG_BEST
  fi
elif [[ $PG_STATE == ok ]]; then
  err "설치 가능한 빌드를 찾지 못했습니다. PGDG 저장소/OS 조합을 확인하세요."
  ask_yn "그래도 계속할까요?" n || die "사용자가 취소했습니다."
else
  warn "PGDG 저장소가 아직 없어 지금은 판정할 수 없습니다(최초 배포 전이면 정상)."
  say  "${DIM}    배포가 OpenSSL 의존성 오류로 실패하면, 저장소가 생긴 뒤 이 마법사를${R}"
  say  "${DIM}    다시 실행하세요. 그때는 설치 가능한 빌드를 자동으로 찾아 줍니다.${R}"
fi

say
read -r -p "  패키지 버전 고정 ${DIM}[${PKG_PIN:-고정 안 함}]${R}: " _pin || die "입력이 끊겼습니다(EOF)."
[[ -n $_pin ]] && PKG_PIN=$_pin

# =============================================================================
head1 "5/6  비밀번호"
# =============================================================================
# 입력이 화면에 표시되지 않으므로(-s) 오타를 그 자리에서 알아챌 수 없습니다.
# 그래서 아래 확인 단계에서 입력값을 그대로 보여 주고, 틀렸으면 다시 받습니다.

# 레이블 / 변수명 / group_vars 키 / 길이 — 한 곳에서 관리합니다.
PW_LABELS=("PostgreSQL superuser" "복제 계정(replicator)" "pg_rewind 계정" \
           "애플리케이션 DB 계정" "Patroni REST API" "PgBouncer 관리자" "keepalived VRRP 인증")
PW_VARS=(PW_SUPER PW_REPL PW_REWIND PW_APP PW_REST PW_PGB PW_KA)
PW_KEYS=(postgres_superuser_password postgres_replication_password patroni_rewind_password \
         app_db_password patroni_restapi_password pgbouncer_admin_password keepalived_auth_pass)
PW_LENS=(20 20 20 20 20 20 8)

collect_passwords() {
  # 첫 입력과 재입력은 Enter 의 의미가 달라서(생성 / 유지) 안내를 나눕니다.
  if [[ ${1:-first} == first ]]; then
    say "${DIM}  Enter 만 누르면 임의 문자열이 만들어집니다(영숫자 — 접속 문자열 안전).${R}"
  else
    say "${DIM}  고칠 항목만 새로 입력하세요. Enter 를 누르면 기존 값이 유지됩니다.${R}"
  fi
  local i
  for i in "${!PW_VARS[@]}"; do
    # 재입력일 때는 방금 넣은 값이, 최초에는 기존 파일의 값이 기본값이 됩니다.
    local cur=${!PW_VARS[$i]:-}
    [[ -z $cur ]] && cur=$(prev "$VAR_FILE" "${PW_KEYS[$i]}")
    ask_pw "${PW_VARS[$i]}" "${PW_LABELS[$i]}" "$cur" "${PW_LENS[$i]}"
  done
}

# 입력한 비밀번호를 그대로 보여 주고 검토받습니다.
review_passwords() {
  local i v
  say
  say "  ${B}입력한 비밀번호${R} ${DIM}— 오타가 없는지 확인하세요.${R}"
  say "  ${DIM}$(printf '─%.0s' {1..60})${R}"
  for i in "${!PW_VARS[@]}"; do
    v=${!PW_VARS[$i]}
    printf "  %s%*s ${C}%s${R}  ${DIM}(%d자)${R}\n" \
      "${PW_LABELS[$i]}" "$(( 24 - $(dwidth "${PW_LABELS[$i]}") ))" "" "$v" "${#v}"
  done
  say "  ${DIM}$(printf '─%.0s' {1..60})${R}"
}

collect_passwords
while :; do
  review_passwords
  say
  ask_yn "이 비밀번호로 진행할까요?" y && break
  say
  collect_passwords again
done

# =============================================================================
head1 "6/6  확인"
# =============================================================================
row "노드"        "$(paste -d'=' <(printf '%s\n' "${NODE_NAMES[@]}") <(printf '%s\n' "${NODE_IPS[@]}") | tr '\n' ' ')"
row "etcd"        "$($ETCD_COLOCATED && echo 'DB 노드에 co-location' || echo "${ETCD_IPS[*]}")"
row "VIP"         "${CLUSTER_VIP}/${CLUSTER_VIP_CIDR} dev ${B}${VIP_INTERFACE}${R}"
row "클러스터 이름" "$CLUSTER_NAME"
row "PostgreSQL"  "${PG_VERSION}${PKG_PIN:+  (고정: $PKG_PIN)}"
row "튜닝 프로파일" "$TUNING_PROFILE"
row "접속 허용 대역" "${ALLOWED_CIDRS[*]}"

# 비밀번호는 5/6 에서 검토를 마쳤지만, 파일로 쓰기 직전에 한 번 더 보여 줍니다.
review_passwords
say
row "쓸 파일"      "$INV_FILE"
row ""            "$VAR_FILE  ${DIM}(0600 — 비밀번호 평문 저장)${R}"

if $DRY_RUN; then
  say; say "${Y}--dry-run 이므로 파일을 쓰지 않고 종료합니다.${R}"; exit 0
fi
say
ask_yn "이 내용으로 파일을 만들까요?" y || die "사용자가 취소했습니다."

# --- 기존 파일 백업 ----------------------------------------------------------
STAMP=$(date +%Y%m%d-%H%M%S)
for f in "$INV_FILE" "$VAR_FILE"; do
  [[ -f $f ]] && { cp -a "$f" "${f}.bak-${STAMP}"; ok "기존 파일 백업: ${f}.bak-${STAMP}"; }
done
mkdir -p "$(dirname "$INV_FILE")" "$(dirname "$VAR_FILE")"

# --- 인벤토리 ----------------------------------------------------------------
{
  echo "---"
  echo "# 이 파일은 scripts/setup-wizard.sh 가 생성했습니다 (${STAMP})."
  echo "# .gitignore 대상입니다 — 실제 환경 IP 는 저장소에 커밋하지 않습니다."
  echo "#   ansible-playbook -i ${INV_FILE} site.yml"
  echo
  echo "all:"
  echo "  vars:"
  echo "    ansible_user: ${SSH_USER}"
  echo
  echo "  children:"
  echo "    etcd:"
  echo "      hosts:"
  if $ETCD_COLOCATED; then
    for i in "${!NODE_IPS[@]}"; do
      echo "        ${NODE_NAMES[$i]}:"
      echo "          ansible_host: ${NODE_IPS[$i]}"
      echo "          node_ip: ${NODE_IPS[$i]}"
    done
  else
    for i in "${!ETCD_IPS[@]}"; do
      echo "        etcd-$((i+1)):"
      echo "          ansible_host: ${ETCD_IPS[$i]}"
      echo "          node_ip: ${ETCD_IPS[$i]}"
    done
  fi
  echo
  echo "    patroni_cluster:"
  echo "      hosts:"
  for i in "${!NODE_IPS[@]}"; do
    echo "        ${NODE_NAMES[$i]}:"
    echo "          ansible_host: ${NODE_IPS[$i]}"
    echo "          node_ip: ${NODE_IPS[$i]}"
    echo "          patroni_name: ${NODE_NAMES[$i]}"
    # NIC 이름이 노드마다 다를 때만 노드별로 지정합니다.
    [[ ${NIC_OF[${NODE_NAMES[$i]}]} != "$VIP_INTERFACE" ]] && \
      echo "          vip_interface: ${NIC_OF[${NODE_NAMES[$i]}]}"
  done
  echo
  echo "    pgbouncer:"
  echo "      hosts:"
  for n in "${NODE_NAMES[@]}"; do echo "        ${n}:"; done
  echo
  echo "    haproxy:"
  echo "      hosts:"
  # priority 는 5씩 낮춰 갑니다. keepalived 의 weight(-20)보다 간격이 작아야
  # HAProxy 장애 시 VIP 가 실제로 넘어갑니다.
  for i in "${!NODE_NAMES[@]}"; do
    echo "        ${NODE_NAMES[$i]}:"
    if (( i == 0 )); then
      echo "          keepalived_state: MASTER"
      echo "          keepalived_priority: 110"
    else
      echo "          keepalived_state: BACKUP"
      echo "          keepalived_priority: $((110 - i * 5))"
    fi
  done
} >"$INV_FILE"
ok "생성: $INV_FILE"

# --- 변수 override -----------------------------------------------------------
umask 077
{
  echo "---"
  echo "# 이 파일은 scripts/setup-wizard.sh 가 생성했습니다 (${STAMP})."
  echo "# .gitignore 대상입니다 — 비밀번호가 평문으로 들어 있으니 커밋 금지."
  echo "#"
  echo "# group_vars/all/ 은 파일명 알파벳 순으로 로드되며 뒤 파일이 앞을 덮어씁니다."
  echo "#   main.yml(공개용 예시)  →  zz-lab.yml(이 파일, 실제 값)"
  echo
  echo "cluster_name: $(yq "$CLUSTER_NAME")"
  echo
  echo "# --- 네트워크 (마법사가 노드에서 직접 감지한 값) ---"
  echo "cluster_vip: ${CLUSTER_VIP}"
  echo "cluster_vip_cidr: ${CLUSTER_VIP_CIDR}"
  echo "vip_interface: ${VIP_INTERFACE}"
  echo
  echo "postgresql_allowed_cidrs:"
  echo "  - 127.0.0.1/32"
  for c in "${ALLOWED_CIDRS[@]}"; do echo "  - ${c}"; done
  echo
  echo "# --- PostgreSQL ---"
  echo "postgresql_version: $(yq "$PG_VERSION")"
  echo "postgresql_package_pin: $(yq "$PKG_PIN")"
  echo "postgresql_tuning_profile: $(yq "$TUNING_PROFILE")"
  echo
  echo "# --- 비밀번호 ---"
  echo "postgres_superuser_password: $(yq "$PW_SUPER")"
  echo "postgres_replication_password: $(yq "$PW_REPL")"
  echo "patroni_rewind_password: $(yq "$PW_REWIND")"
  echo "app_db_password: $(yq "$PW_APP")"
  echo "patroni_restapi_password: $(yq "$PW_REST")"
  echo "pgbouncer_admin_password: $(yq "$PW_PGB")"
  echo "keepalived_auth_pass: $(yq "$PW_KA")"
} >"$VAR_FILE"
chmod 600 "$VAR_FILE"
umask 022
ok "생성: $VAR_FILE ${DIM}(0600)${R}"

# --- 문법 검증 ---------------------------------------------------------------
say
if ansible-inventory -i "$INV_FILE" --list >/dev/null 2>&1 </dev/null; then
  ok "인벤토리 문법 정상"
else
  err "인벤토리 문법 오류:"; ansible-inventory -i "$INV_FILE" --list 2>&1 | tail -5; exit 1
fi
if python3 -c "import yaml,sys; yaml.safe_load(open('$VAR_FILE'))" 2>/dev/null; then
  ok "변수 파일 문법 정상"
else
  err "변수 파일 YAML 오류"; exit 1
fi

# =============================================================================
say
say "${G}${B}설정이 끝났습니다.${R}"
say
say "  배포:      ${C}ansible-playbook -i ${INV_FILE} site.yml${R}"
say "  사전 점검: ${C}ansible-playbook -i ${INV_FILE} site.yml --check${R}"
say "  상태 확인: ${C}ansible-playbook -i ${INV_FILE} playbooks/verify-cluster.yml${R}"
say
say "${DIM}  값을 고치려면 이 스크립트를 다시 실행하세요(기존 값이 기본값으로 제시됩니다).${R}"

if $RUN_DEPLOY || ask_yn "지금 바로 배포할까요?" n; then
  say
  exec ansible-playbook -i "$INV_FILE" site.yml
fi
