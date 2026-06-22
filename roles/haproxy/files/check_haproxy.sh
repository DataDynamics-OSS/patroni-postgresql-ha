#!/usr/bin/env bash
# Keepalived 헬스체크 스크립트.
# HAProxy 가 떠 있을 때만 성공(0)을 반환합니다.
# HAProxy 가 죽으면 실패 → Keepalived 가 우선순위를 낮춰 VIP 가 다른 노드로 넘어갑니다.
/bin/pidof haproxy >/dev/null 2>&1
exit $?
