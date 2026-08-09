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
# Entries carry a timeout so the set self-prunes over a long session. Every
# lookup re-adds the IP and resets its clock, so anything actively in use never
# expires; anything the load balancer has moved off of ages out.
ipset create allowed-domains hash:net timeout "${ALLOWED_IP_TTL:-86400}"

# Domains are supplied via the ALLOWED_DOMAINS env var (space/comma separated).
# sandbox.sh has already folded in the auth endpoint (Bedrock / api.anthropic.com
# / custom base URL), the git-over-ssh hosts, and pypi.
DOMAINS="${ALLOWED_DOMAINS:-}"
DOMAINS="${DOMAINS//,/ }"

# Capture the upstream resolvers before we point resolv.conf at our own dnsmasq.
UPSTREAM_NS=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf)

# Seed the set with one resolution per domain, so the very first connection
# works even before anything has gone through dnsmasq.
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

# --- Keep the set in sync with DNS ---
# Seeding once is NOT enough. Endpoints behind a global load balancer hand out a
# different pool member every time the record expires -- Intel's GSLB
# (gnai.intel.com -> gnai.iglb.intel.com) uses a 25 second TTL and rotates
# across a /24. A set pinned at container start therefore goes stale within
# minutes: the client resolves the new IP, sends a SYN to an address that is not
# in the set, and the packet is silently discarded. That is the intermittent
# multi-minute "hang" -- ~127s of SYN retransmits per attempt, several attempts
# deep -- and it never reproduces outside the sandbox because the host has no
# such filter.
#
# The fix is to populate the set at resolve time rather than at boot: dnsmasq
# adds every A record it hands back for an allowlisted name straight into the
# ipset (following CNAMEs), so the allowlist tracks the load balancer by
# construction and can never lag behind it.
DNS_SYNC="none"
if command -v dnsmasq >/dev/null 2>&1 && [ -n "$UPSTREAM_NS" ]; then
  {
    echo "listen-address=127.0.0.1"
    echo "bind-interfaces"
    echo "no-resolv"            # use only the servers listed below
    echo "user=root"            # needs NET_ADMIN to write to the ipset
    echo "cache-size=1000"
    for ns in $UPSTREAM_NS; do echo "server=$ns"; done
    # Matches the domain and everything under it.
    for domain in $DOMAINS; do [ -n "$domain" ] && echo "ipset=/$domain/allowed-domains"; done
  } > /etc/dnsmasq-allowlist.conf

  if dnsmasq -C /etc/dnsmasq-allowlist.conf; then
    printf 'nameserver 127.0.0.1\noptions timeout:2 attempts:2\n' > /etc/resolv.conf
    DNS_SYNC="dnsmasq"
    _echo "[firewall]   DNS sync: dnsmasq (ipset updated at resolve time)"
  else
    _echo "[firewall]   WARNING: dnsmasq failed to start, falling back to polling"
  fi
fi

if [ "$DNS_SYNC" = "none" ]; then
  # Fallback: re-resolve on a timer. Coarser than dnsmasq (a rotation can still
  # blackhole a connection for up to one interval) but far better than never.
  (
    while :; do
      sleep "${ALLOWLIST_REFRESH_SECS:-15}"
      for domain in $DOMAINS; do
        [ -z "$domain" ] && continue
        dig +short A "$domain" 2>/dev/null \
          | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
          | while read -r ip; do ipset add allowed-domains "$ip" -exist 2>/dev/null || true; done
      done
    done
  ) &
  DNS_SYNC="poll/${ALLOWLIST_REFRESH_SECS:-15}s"
  _echo "[firewall]   DNS sync: polling every ${ALLOWLIST_REFRESH_SECS:-15}s"
fi

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
# REJECT rather than relying on the DROP policy alone: a blocked connection then
# fails instantly with "connection refused" instead of blackholing the SYN for
# ~2 minutes. A forgotten domain should look like an error, not like a hang.
# The LOG rule (rate-limited, lands in the *host* dmesg since the kernel ring
# buffer is shared) tells you which address was refused:
#   sudo dmesg -w | grep sandbox-blocked
iptables -A OUTPUT -m limit --limit 10/min -j LOG --log-prefix "[sandbox-blocked] " --log-level 4
iptables -A OUTPUT -p tcp -j REJECT --reject-with tcp-reset
iptables -A OUTPUT -j REJECT --reject-with icmp-port-unreachable

iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

# IPv6 has no allowlist, so deny it outright. Without this it defaults to ACCEPT
# and is a hole straight through the filter for any dual-stack destination.
if command -v ip6tables >/dev/null 2>&1 && ip6tables -L >/dev/null 2>&1; then
  ip6tables -F || true
  ip6tables -A INPUT  -i lo -j ACCEPT || true
  ip6tables -A OUTPUT -o lo -j ACCEPT || true
  ip6tables -P INPUT   DROP || true
  ip6tables -P FORWARD DROP || true
  ip6tables -P OUTPUT  DROP || true
  _echo "[firewall]   IPv6: denied"
fi

_echo "[firewall] Done"
_echo "[firewall] DNS sync: $DNS_SYNC"
_echo "[firewall] Allowed domains: $DOMAINS"
