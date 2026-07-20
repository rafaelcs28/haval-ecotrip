#!/usr/bin/env bash
# Failover Ethernet → WiFi quando o cabo do Mac Mini fica "half-up":
# porta com link físico mas 0 pacotes passam (macOS não faz failover sozinho
# nesse cenário). Ping externo cai → watchdog desliga o serviço Ethernet,
# WiFi assume automaticamente pelo service order. Retry ativa Ethernet
# depois de RETRY_AFTER_S. Se cair de novo em <QUICK_FAIL_S, mantém OFF e
# alerta pro dono ir em casa (intervenção física).
#
# Requer sudoers NOPASSWD pra `networksetup -setnetworkserviceenabled Ethernet *`.
# Rodado pelo launchd (com.haval.net-failover).
set -uo pipefail

LOG=/Users/consorciolimpagyn/haval-ecotrip/logs/net-failover.log
NTFY_URL="https://ntfy.sh/infra-limpagyn-a7f3b9c2e18d"

POLL_S=15                # intervalo de ping
FAIL_THRESHOLD=3         # falhas seguidas antes de failover (~45s)
RETRY_AFTER_S=300        # 5min OFF antes de tentar religar Ethernet
QUICK_FAIL_S=120         # se cair de novo em <2min pós-recovery = ruim mesmo
PING_TARGET=8.8.8.8

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }
ntfy() {
  local title="$1"; local body="$2"; local priority="${3:-default}"
  curl -s -X POST -H "Title: $title" -H "Priority: $priority" -H "Tags: satellite,warning" \
    -d "$body" "$NTFY_URL" >/dev/null 2>&1 || true
}

ethernet_enabled() {
  # `*Ethernet` (asterisco colado) = desabilitado
  networksetup -listallnetworkservices 2>/dev/null | grep -q "^\*Ethernet$" && return 1 || return 0
}
ethernet_link_active() {
  ifconfig en0 2>/dev/null | grep -q "status: active"
}
ethernet_on()  { sudo -n /usr/sbin/networksetup -setnetworkserviceenabled Ethernet on  >/dev/null 2>&1; }
ethernet_off() { sudo -n /usr/sbin/networksetup -setnetworkserviceenabled Ethernet off >/dev/null 2>&1; }
check_internet() { ping -c 1 -W 1500 "$PING_TARGET" >/dev/null 2>&1; }

# Estado limpo no start: garante Ethernet ligado (se estava OFF por bug/crash)
if ! ethernet_enabled; then
  log "boot: Ethernet estava desligado — reativando"
  ethernet_on
  sleep 3
fi

fails=0
failover_active=false
last_failover=0
recovery_ts=0
manual_hold=false        # true = watchdog desistiu, aguarda intervenção física

log "watchdog iniciado. poll=${POLL_S}s threshold=${FAIL_THRESHOLD} target=${PING_TARGET}"

while true; do
  now=$(date +%s)
  if check_internet; then
    if [ "$fails" -gt 0 ]; then log "internet voltou (após $fails falhas)"; fi
    fails=0
    if $failover_active && [ $((now - last_failover)) -ge $RETRY_AFTER_S ] && ! $manual_hold; then
      log "tentando reativar Ethernet após ${RETRY_AFTER_S}s"
      ethernet_on
      failover_active=false
      recovery_ts=$now
    fi
  else
    fails=$((fails + 1))
    log "ping ${PING_TARGET} falhou (${fails}/${FAIL_THRESHOLD})"
    if [ "$fails" -ge "$FAIL_THRESHOLD" ] && ! $failover_active && ! $manual_hold; then
      if ethernet_enabled && ethernet_link_active; then
        if [ "$recovery_ts" -gt 0 ] && [ $((now - recovery_ts)) -lt "$QUICK_FAIL_S" ]; then
          log "Ethernet falhou de novo em <${QUICK_FAIL_S}s após recovery — segurando OFF, precisa vir em casa"
          ethernet_off
          failover_active=true
          manual_hold=true
          ntfy "Ethernet Mac Mini pediu intervenção" \
               "Cabo/porta caiu 2x em sequência. WiFi assumiu — watchdog parou de tentar. Vem em casa reencaixar o cabo quando puder." "high"
        else
          log "failover: desativando Ethernet, WiFi assume"
          ethernet_off
          failover_active=true
          last_failover=$now
          ntfy "Failover Ethernet→WiFi" \
               "Ethernet do Mac Mini caiu. Desativei — WiFi assumiu. Retry em ${RETRY_AFTER_S}s." "default"
        fi
      else
        log "internet caiu mas Ethernet já OFF ou link inactive — problema é upstream (roteador/ISP), não intervém"
      fi
    fi
  fi
  sleep $POLL_S
done
