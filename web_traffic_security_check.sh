i#!/bin/bash
# web_traffic_security_check.sh
# Web exploit / traffic scanner for Nginx access logs
# Usage: sudo /home/ubuntu/scripts/web_traffic_security_check.sh
# Author: Martok Expert
# Created: 2025-10-28

# --- env / safety ---
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LC_ALL=C

# --- Tools (absolute where possible) ---
AWK="$(command -v awk || echo /usr/bin/awk)"
GREP="$(command -v grep || echo /usr/bin/grep)"
SORT="$(command -v sort || echo /usr/bin/sort)"
HEAD="$(command -v head || echo /usr/bin/head)"
UNIQ="$(command -v uniq || echo /usr/bin/uniq)"
SED="$(command -v sed || echo /usr/bin/sed)"
WC="$(command -v wc || echo /usr/bin/wc)"
TAIL="$(command -v tail || echo /usr/bin/tail)"
TEE="$(command -v tee || echo /usr/bin/tee)"
DATE_BIN="$(command -v date || echo /bin/date)"
HOSTNAME_BIN="$(command -v hostname || echo /bin/hostname)"
GEOIPLOOKUP="$(command -v geoiplookup || echo /usr/bin/geoiplookup)"
XARGS="$(command -v xargs || echo /usr/bin/xargs)"

# --- Config ---
TMPDIR="/home/ubuntu/tmp"
REPORT="$TMPDIR/web_security_report.txt"
LOGFILE="$TMPDIR/web_traffic_security.log"
ACCESS_LOG="/var/log/nginx/access.log"
SEND_SES="/home/ubuntu/scripts/send-ses.sh"
EMAIL_TO="patrick@powdermonkey.eu"
NGINX_DENY_SNIPPET="/home/ubuntu/tmp/nginx_deny.conf"
IP_BLOCK_LIST="/home/ubuntu/tmp/block_ips.txt"
HOSTNAME="$($HOSTNAME_BIN)"
DATE="$($DATE_BIN '+%Y-%m-%d %H:%M:%S')"
RECENT_LINES=50000   # tuneable

# --- Ensure tmp dir exists ---
/bin/mkdir -p "$TMPDIR"

# --- Cleanup on exit (remove temp artifacts but keep the report until AFTER send) ---
cleanup() {
  /bin/rm -f "$LOGFILE" "$NGINX_DENY_SNIPPET" "$IP_BLOCK_LIST" 2>/dev/null || true
}
trap cleanup EXIT

# start fresh report file
: > "$REPORT"
: > "$LOGFILE"

# header
echo "📊 Web Traffic Security Report" | "$TEE" -a "$REPORT"
echo "Host: $HOSTNAME" | "$TEE" -a "$REPORT"
echo "Date: $DATE" | "$TEE" -a "$REPORT"
echo "" | "$TEE" -a "$REPORT"

# check log availability (fallback to .1)
if [ ! -f "$ACCESS_LOG" ]; then
  ACCESS_LOG="/var/log/nginx/access.log.1"
fi

if [ ! -f "$ACCESS_LOG" ]; then
  echo "   Nginx access log not found." | "$TEE" -a "$REPORT"
  if [ -x "$SEND_SES" ]; then
    "$SEND_SES" "  Web Security Check - No Log on $HOSTNAME" "$EMAIL_TO" "$REPORT"
  fi
  exit 1
fi

# read recent lines (avoid OOM and speed)
RECENT_LOG="$($TAIL -n $RECENT_LINES "$ACCESS_LOG" 2>/dev/null || true)"

# ===================== suspicious URL probes =====================
SUSPECT_COUNT=$(echo "$RECENT_LOG" | "$GREP" -E "/(\.env|\.git|\.svn|wp-login\.php|xmlrpc\.php|alfa\.php|chosen\.php|0x\.php|cong\.php|backup|old|new|main|home|css\.php)" | "$WC" -l || true)
if [ "$SUSPECT_COUNT" -gt 0 ]; then
  echo "❌ Detected $SUSPECT_COUNT suspicious URL hits (possible scan/exploit)." | "$TEE" -a "$REPORT"
  echo "   Example hits:" | "$TEE" -a "$REPORT"
  echo "$RECENT_LOG" | "$GREP" -E "/(\.env|\.git|\.svn|wp-login\.php|xmlrpc\.php|alfa\.php|chosen\.php|0x\.php|cong\.php|backup|old|new|main|home|css\.php)" | "$HEAD" -n 12 | "$SED" 's/^/   /' >> "$REPORT"
else
  echo "✅ No suspicious URL probes detected." | "$TEE" -a "$REPORT"
fi
echo "" | "$TEE" -a "$REPORT"

# ===================== top IPs =====================
echo "Top 5 IPs by request volume (recent $RECENT_LINES lines):" | "$TEE" -a "$REPORT"
echo "$RECENT_LOG" | "$AWK" '{print $1}' | "$SORT" | "$UNIQ" -c | "$SORT" -nr | "$HEAD" -5 | "$SED" 's/^/   /' >> "$REPORT"
TOP_COUNT=$(echo "$RECENT_LOG" | "$AWK" '{print $1}' | "$SORT" | "$UNIQ" -c | "$SORT" -nr | "$HEAD" -1 | "$AWK" '{print $1}' || echo 0)
TOP_IP=$(echo "$RECENT_LOG" | "$AWK" '{print $1}' | "$SORT" | "$UNIQ" -c | "$SORT" -nr | "$HEAD" -1 | "$AWK" '{print $2}' || echo "")
if [ "$TOP_COUNT" -gt 1000 ]; then
  echo "   High traffic from one IP ($TOP_IP: $TOP_COUNT requests) — possible scanner." | "$TEE" -a "$REPORT"
fi
echo "" | "$TEE" -a "$REPORT"

# ===================== suspicious User-Agents =====================
echo "Top suspicious User-Agents (by occurrence):" | "$TEE" -a "$REPORT"

# heuristics for suspicious UAs:
# - known crawler names (semrush, baidu, bytespider, petal, sogou, 360)
# - python/curl/wget/httpclients
# - fake browser versions (Chrome/13[0-9]|14[0-9]|Firefox/1[0-9][0-9])
# - indicators: 'bot' 'spider' 'scraper' 'scanner' 'masscan' 'sqlmap' etc.

echo "$RECENT_LOG" \
  | "$AWK" -F\" '{print $6}' \
  | "$GREP" -iE "(semrush|baiduspider|bytespider|petalbot|sogou|360Spider|mj12bot|ahrefsbot|majestic|bot|spider|crawler|scraper|masscan|sqlmap|python-requests|wget|curl|httpclient|apache-httpclient|okhttp|headlesschrome|phantom|nikto|scan)" \
  | "$SORT" | "$UNIQ" -c | "$SORT" -nr | "$HEAD" -20 | "$SED" 's/^/   /' >> "$REPORT"

# also show top overall UAs to catch spoofing
echo "" >> "$REPORT"
echo "Top 10 User-Agents overall (for context):" >> "$REPORT"
echo "$RECENT_LOG" | "$AWK" -F\" '{print $6}' | "$SORT" | "$UNIQ" -c | "$SORT" -nr | "$HEAD" -10 | "$SED" 's/^/   /' >> "$REPORT"

echo "" | "$TEE" -a "$REPORT"

# ===================== Top URIs targeted (to see patterns) =====================
echo "Top 10 requested URIs:" | "$TEE" -a "$REPORT"
echo "$RECENT_LOG" | "$AWK" '{print $7}' | "$SORT" | "$UNIQ" -c | "$SORT" -nr | "$HEAD" -10 | "$SED" 's/^/   /' >> "$REPORT"
echo "" | "$TEE" -a "$REPORT"

# ===================== top offending IPs -> optional deny snippet =====================
# create actionable lists: top N IPs (non-local) for operator review
echo "Generating actionable block list (top 20 IPs excluding local/private ranges)..." | "$TEE" -a "$REPORT"

# Exclude typical private/local ranges quickly (10.,172.16.,192.168.,127.)
echo "$RECENT_LOG" | "$AWK" '{print $1}' \
  | "$GREP" -v -E '^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)' \
  | "$SORT" | "$UNIQ" -c | "$SORT" -nr | "$HEAD" -20 \
  | "$AWK" '{print $2}' > "$IP_BLOCK_LIST" || true

if [ -s "$IP_BLOCK_LIST" ]; then
  echo "Top candidate IPs to consider blocking (stored in $IP_BLOCK_LIST):" | "$TEE" -a "$REPORT"
  "$AWK" '{print "   " $0}' "$IP_BLOCK_LIST" >> "$REPORT"

  # create nginx deny snippet (commented out by default — operator must review)
  {
    echo "# Generated deny list - review before enabling"
    echo "# Generated at: $DATE on $HOSTNAME"
    while read -r ip; do
      echo "deny $ip;"
    done < "$IP_BLOCK_LIST"
  } > "$NGINX_DENY_SNIPPET" || true

  echo "" >> "$REPORT"
  echo "To apply in nginx (after review):" >> "$REPORT"
  echo "  sudo cp $NGINX_DENY_SNIPPET /etc/nginx/conf.d/deny_blocked_ips.conf" >> "$REPORT"
  echo "  sudo nginx -t && sudo systemctl reload nginx" >> "$REPORT"
else
  echo "No external top offenders found to propose for blocking." | "$TEE" -a "$REPORT"
fi
echo "" | "$TEE" -a "$REPORT"

# ===================== geoip summary (optional) =====================
if [ -x "$GEOIPLOOKUP" ]; then
  echo "Top countries by IP (sample of top 20):" | "$TEE" -a "$REPORT"
  # limit to top 20 IPv4 only
  echo "$RECENT_LOG" | "$AWK" '{print $1}' | "$GREP" -v ":" | "$SORT" | "$UNIQ" -c | "$SORT" -nr | "$HEAD" -20 | "$AWK" '{print $2}' \
    | "$XARGS" -n1 -r "$GEOIPLOOKUP" 2>/dev/null | "$GREP" -oP "(Country: )\K.*" | "$SORT" | "$UNIQ" -c | "$SORT" -nr | "$HEAD" -10 | "$SED" 's/^/   /' >> "$REPORT"
else
  echo "geoiplookup not installed; skipping country summary." | "$TEE" -a "$REPORT"
fi
echo "" | "$TEE" -a "$REPORT"

# ===================== final note & send =====================
echo "✅ Web traffic scan completed successfully at $($DATE_BIN)" | "$TEE" -a "$REPORT"

SUBJECT="📊 Web Security Report - $HOSTNAME ($DATE)"
if [ -x "$SEND_SES" ]; then
  "$SEND_SES" "$SUBJECT" "$EMAIL_TO" "$REPORT"
else
  echo "  send-ses.sh not found/executable at $SEND_SES" | "$TEE" -a "$REPORT"
fi

# leave cleanup trap to remove helper files but keep report emailed
exit 0

~
~
~
~
~
~
~
~
~
