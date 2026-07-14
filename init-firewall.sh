#!/usr/bin/env bash
set -euo pipefail

# Print status lines with a leading [tag] in orange, the rest in the default color.
_echo() {
  local msg="$*"
  if [[ "$msg" == \[*\]* ]]; then
    printf '\033[38;5;208m%s\033[0m%s\n' "${msg%%]*}]" "${msg#*]}"
  else
    printf '%s\n' "$msg"
  fi
}

_echo "[firewall] initializing egress allowlist..."

# --- Reset ---
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# --- Allow loopback ---
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# --- Allow DNS (needed to resolve the allowlisted domains) ---
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# --- Allow established/related return traffic ---
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# --- Build the allowed-IP set from the domain allowlist ---
ipset create allowed-domains hash:net

# Domains are supplied via the ALLOWED_DOMAINS env var (space/comma separated).
# sandbox.sh has already folded in the auth endpoint (Bedrock / api.anthropic.com
# / custom base URL), the git-over-ssh hosts, and pypi.
DOMAINS="${ALLOWED_DOMAINS:-}"
DOMAINS="${DOMAINS//,/ }"

for domain in $DOMAINS; do
  [ -z "$domain" ] && continue
  _echo "[firewall]   resolving $domain"
  ips=$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
  if [ -z "$ips" ]; then
    _echo "[firewall]   WARNING: could not resolve $domain (skipping)"
    continue
  fi
  while read -r ip; do
    [ -z "$ip" ] && continue
    ipset add allowed-domains "$ip" 2>/dev/null || true
    _echo "[firewall]     + $ip"
  done <<< "$ips"
done

# --- Allow outbound TCP only to the resolved allowlist, on allowed ports ---
# 443 https, 80 http, 22 ssh. Override/extend via the ALLOWED_PORTS env var
# (space/comma separated), e.g. add a corporate proxy port: "443 80 22 912".
PORTS="${ALLOWED_PORTS:-443 80 22}"
PORTS="${PORTS//,/ }"
for port in $PORTS; do
  [ -z "$port" ] && continue
  iptables -A OUTPUT -m set --match-set allowed-domains dst -p tcp --dport "$port" -j ACCEPT
  _echo "[firewall]   allow tcp/$port to allowlist"
done

# --- Default deny everything else ---
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

_echo "[firewall] done. Allowed domains: $DOMAINS"
