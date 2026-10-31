#!/usr/bin/env bash
#
# pve-rolling-upgrade.sh
#
# Rolling Proxmox VE upgrade helper.
#
# Safety features:
#   - dry-run by default; --apply requires an explicit YES confirmation
#   - flock concurrency lock, umask 077
#   - pinned known_hosts (StrictHostKeyChecking=yes) + BatchMode=yes
#   - PVE major version guard
#   - reboot proven by boot-ID change, not just an SSH flap
#   - Ceph noout state preserved if pre-existing; a script-introduced noout
#     flag is never cleared automatically on abnormal exit (warning instead)
#   - Ceph baseline required before starting (HEALTH_OK, or HEALTH_WARN whose
#     only cause is a pre-existing noout flag)
#   - any APT package change uses HA maintenance and a reboot
#   - full expected Corosync membership and votes required before each phase
#   - evacuation check parses real `ha-manager status` output
#   - running guests must be HA-managed with requested state started/enabled
#   - pve-ha-lrm must be active before maintenance mode is trusted
#   - refuses to start (apply) / warns (dry run) when a vzdump backup is
#     running on any node; a rolling reboot mid-backup aborts the backup
#   - survivor health gate before each reboot: every remaining node is checked
#     for cluster-communication distress (pmxcfs CPG retry storm) and severe
#     CPU saturation, since they just absorbed the evacuated guests; rebooting
#     into a distressed survivor set risks an HA watchdog self-fence cascade
#
# Changes in this patched version:
#   1. Pattern matching uses here-strings, not `printf | grep -q`, which can
#      return 141 under pipefail on large input (misclassifying a node as
#      "no updates" and skipping HA maintenance).
#   2. Post-reboot quorum/membership check retries instead of dying on the
#      first try (corosync rejoins after sshd is already back).
#   3. Ceph detection distinguishes "not in use" from "installed but not
#      responding" (the latter aborts instead of silently skipping Ceph steps).
#   4. All ceph commands run under `timeout`.
#   5. Pre-existing noout is now actually supported (baseline/health checks
#      accept the "noout flag(s) set" warning only when noout pre-existed).
#   6. IFS no longer mangles ${NODES[*]} in messages.
#   - apt runs via systemd-run on the node (survives SSH drops) with
#     non-interactive conffile handling (keep existing config).
#   - ssh -n so ssh never consumes stdin.
#   - Dry run also performs the pve-ha-lrm, Ceph baseline and --no-reboot checks.
#   - wait_for_reboot also accepts a boot-ID change if the outage was too short
#     to observe; waits for pve-ha-lrm after reboot before leaving maintenance.
#   - Log tee is flushed/waited for at exit.
#
# Review fixes in this version (2026-10-17):
#   R1. Preflight refuses (apply) / warns (dry run) when a vzdump backup is
#       running on any node; a rolling reboot mid-backup aborts the backup.
#       Schedule around backup windows regardless.
#       (fixed 2026-10-17: plain `pgrep -f vzdump` also matched the remote
#       `sh -c` wrapper sshd spawns, so the check fired on every node even
#       with no backup running; now uses the '[v]zdump' bracket trick.)
#   R2. ha_sid_protected now uses a here-string (last remaining printf|awk
#       site from the SIGPIPE fix above).
#   R3. The apply-mode "inline upgrade" path for nodes with no package changes
#       was dead code (any Inst/Remv line already routes to the reboot path,
#       so a zero-change simulation means there is nothing to install); it now
#       just logs and returns.
#
# Changes in reviewed4 (2026-10-17):
#   S2. The survivor health gate now also runs in dry-run mode (advisory,
#       warnings only) instead of apply mode only. Rationale: the gate is
#       fully read-only, so there was no reason to skip it in dry-run — and
#       as written in reviewed3, its first-ever execution would have been
#       during a real --apply run, seconds before a reboot, which is the
#       worst moment to discover a plumbing problem. Dry-run now exercises
#       the gate's SSH/journalctl/awk/loadavg paths on every survivor and
#       reports current survivor health; an --apply run still aborts
#       fail-closed on any gate problem. In dry-run the gate reports
#       warnings and continues to the next survivor rather than aborting
#       the dry run.
#
# Changes in reviewed3 (2026-10-17):
#   S1. New pre-reboot survivor health gate. Before
#       rebooting a node, every other node is checked for (a) a pmxcfs CPG
#       retry storm in the last 10 minutes and (b) 5-minute load average
#       above SURVIVOR_MAX_LOAD_FACTOR x CPU count. Either condition aborts
#       an --apply run (fail-closed; the node is left parked in maintenance
#       mode and a re-run resumes cleanly). Rationale: on 2026-10-17, pve2
#       and pve3 self-fenced via the HA hardware watchdog within seconds of
#       pve1's planned reboot — journals showed CPG/corosync already
#       degrading before pve1 left, with the survivors likely saturated by
#       evacuated guests. Thresholds are tunable via the SURVIVOR_*
#       variables below. In dry-run mode the gate is advisory (warnings,
#       no abort) so its plumbing gets exercised before any real run.
#
# Recovery: every step is idempotent. If the run is interrupted (Ctrl-C, SSH
# drop), just re-run it: maintenance mode re-enables harmlessly, evacuation
# is re-verified, apt re-runs cleanly, and an already-completed node is a
# no-op. A node left in maintenance and/or with a script-set noout flag
# produces an explicit warning; clear noout manually only after verifying
# Ceph health.
#
# Usage:
#   ./pve-rolling-upgrade.sh              # dry run (default)
#   ./pve-rolling-upgrade.sh --apply      # perform upgrades (asks YES)
#   ./pve-rolling-upgrade.sh --apply --no-reboot
#   ./pve-rolling-upgrade.sh --apply -y   # skip confirmation (careful!)
#
# Setup:
#   ssh-keyscan pve1 pve2 pve3 > ~/.ssh/known_hosts_pve
#   chmod 600 ~/.ssh/known_hosts_pve

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

NODES=("pve1" "pve2" "pve3")
SSH_USER="root"
EXPECTED_PVE_MAJOR="9"   # set to "" to disable check
KNOWN_HOSTS_FILE="${HOME}/.ssh/known_hosts_pve"

SSH_OPTS=(
    -n
    -o BatchMode=yes
    -o ConnectTimeout=5
    -o ServerAliveInterval=10
    -o ServerAliveCountMax=3
    -o StrictHostKeyChecking=yes
    -o UserKnownHostsFile="${KNOWN_HOSTS_FILE}"
)

EVAC_TIMEOUT=1800
DOWN_TIMEOUT=300
SSH_UP_TIMEOUT=900
QUORUM_TIMEOUT=300
LRM_TIMEOUT=300
CEPH_TIMEOUT=1800
CEPH_CMD_TIMEOUT=30     # per ceph CLI invocation, enforced on the node
POLL_INTERVAL=10
# Survivor health gate (reviewed3): checked on every node except the one about
# to reboot, after evacuation. Tune to the cluster; raise if false positives
# occur under normal load, lower for extra caution.
SURVIVOR_MAX_CPG_RETRIES=25  # max pmxcfs "cpg_send_message retry" lines per survivor in the last 10 min
SURVIVOR_MAX_LOAD_FACTOR=2    # max 5-min loadavg as a multiple of the survivor's CPU count
LOG_DIR="${HOME}/pve"
MODE="dry-run"
ALLOW_REBOOT=1
SKIP_CONFIRM=0
LOCK_FILE="${LOG_DIR}/.pve-upgrade.lock"
CEPH_NOOUT_SET=0       # noout was introduced by this script and still needs removal
CEPH_NOOUT_NODE=""
QUORUM_MSG=""
TEE_PID=""

usage() {
    cat <<'USAGE'
Usage: pve-rolling-upgrade.sh [--apply] [--no-reboot] [-y|--yes] [--help]

  (default)     Read-only preflight and APT simulation; do not change systems.
  --apply       Run apt-get update/dist-upgrade and perform planned reboots.
  --no-reboot   With --apply, refuse to upgrade any node that has package
                changes (they would require a reboot under this script's
                policy). The run aborts at the first such node, before
                installing anything on it. Only nodes with nothing to
                install are processed. The dry run warns when this applies.
  -y, --yes     Skip YES confirmation (still requires --apply)
  --help        Show this help.

Setup:
  Pre-populate known hosts: ssh-keyscan pve1 pve2 pve3 > ~/.ssh/known_hosts_pve
  chmod 600 ~/.ssh/known_hosts_pve
USAGE
}

while (($#)); do
    case "$1" in
        --apply) MODE="apply" ;;
        --no-reboot) ALLOW_REBOOT=0 ;;
        -y|--yes) SKIP_CONFIRM=1 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

TIMESTAMP="$(date +'%Y%m%d-%H%M%S')"
mkdir -p "$LOG_DIR"
mkdir -p "$(dirname "$KNOWN_HOSTS_FILE")"
LOG_FILE="${LOG_DIR}/${TIMESTAMP}-upgrade-run.log"
exec > >(tee -i "$LOG_FILE") 2>&1
TEE_PID=$!

log() { printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

# Space-joined node list (IFS is newline/tab, so "${NODES[*]}" would not be).
nodes_str() { local IFS=' '; printf '%s' "${NODES[*]}"; }

# --- concurrency lock ---
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    die "Another upgrade run is active (lock: $LOCK_FILE)"
fi
log "Acquired lock: $LOCK_FILE"

cleanup() {
    local rc=$?
    # Deliberately do not clear noout automatically after an abnormal exit:
    # Ceph may be degraded or the reboot may have failed. Leaving noout set is
    # safer than changing cluster-wide OSD behavior without checking health.
    if (( CEPH_NOOUT_SET )); then
        log "WARNING: this run introduced Ceph noout (via ${CEPH_NOOUT_NODE:-unknown node}) and exited before clearing it."
        log "Inspect Ceph health first; when safe, clear it manually with: ceph osd unset noout"
    fi
    # Close our stdout/stderr so tee sees EOF, then let it finish writing the log.
    if [[ -n "${TEE_PID:-}" ]]; then
        exec >&- 2>&-
        wait "$TEE_PID" 2>/dev/null || true
    fi
    # lock auto-released when fd 9 closes
    return "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

check_known_hosts() {
    if [[ ! -f "$KNOWN_HOSTS_FILE" ]]; then
        die "Known hosts file not found: $KNOWN_HOSTS_FILE — run: ssh-keyscan $(nodes_str) > $KNOWN_HOSTS_FILE && chmod 600 $KNOWN_HOSTS_FILE"
    fi
    for n in "${NODES[@]}"; do
        if ! ssh-keygen -F "$n" -f "$KNOWN_HOSTS_FILE" >/dev/null 2>&1; then
            die "Node $n not in $KNOWN_HOSTS_FILE - add it with ssh-keyscan"
        fi
    done
}

node_ssh() {
    local node="$1"; shift
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${node}" "$@"
}

ssh_is_up() { ssh "${SSH_OPTS[@]}" "${SSH_USER}@$1" 'true' >/dev/null 2>&1; }

wait_for() {
    local timeout="$1" interval="$2"; shift 2
    local elapsed=0
    until "$@" >/dev/null 2>&1; do
        if (( elapsed >= timeout )); then return 1; fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    return 0
}

# quorum_status <node>: non-dying check. Returns 0 if the cluster is quorate
# and every configured node is a member; otherwise returns 1. Sets QUORUM_MSG
# either way (success summary or failure reason). Safe to use with wait_for.
quorum_status() {
    local node="$1" status expected_votes total_votes member_count
    QUORUM_MSG=""

    if ! status="$(node_ssh "$node" 'pvecm status' 2>/dev/null)"; then
        QUORUM_MSG="Could not read pvecm status from ${node}."
        return 1
    fi
    if ! grep -Eq 'Quorate:[[:space:]]*Yes' <<< "$status"; then
        QUORUM_MSG="Cluster is not quorate (checked via ${node})."
        return 1
    fi

    # Quorum alone is not enough for a safe rolling reboot: a 3-node cluster
    # can remain quorate with only two members. Require every configured node
    # to be represented in Corosync membership before proceeding.
    expected_votes="$(awk -F: '/^[[:space:]]*Expected votes:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' <<< "$status")"
    total_votes="$(awk -F: '/^[[:space:]]*Total votes:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' <<< "$status")"
    member_count="$(awk '
        /Membership information/ { in_membership=1; next }
        in_membership && /^[[:space:]]*0x[[:xdigit:]]+/ { count++ }
        END { print count+0 }
    ' <<< "$status")"

    if ! [[ "$expected_votes" =~ ^[0-9]+$ ]]; then QUORUM_MSG="Could not parse Expected votes from pvecm status on ${node}; refusing to proceed."; return 1; fi
    if ! [[ "$total_votes" =~ ^[0-9]+$ ]]; then QUORUM_MSG="Could not parse Total votes from pvecm status on ${node}; refusing to proceed."; return 1; fi
    if ! [[ "$member_count" =~ ^[0-9]+$ ]]; then QUORUM_MSG="Could not parse Corosync membership count on ${node}; refusing to proceed."; return 1; fi
    if (( expected_votes != ${#NODES[@]} )); then
        QUORUM_MSG="Expected votes is ${expected_votes}, but script is configured for ${#NODES[@]} nodes. Check NODES and cluster configuration."
        return 1
    fi
    if (( total_votes != expected_votes )); then
        QUORUM_MSG="Only ${total_votes}/${expected_votes} votes are present (checked via ${node}); refusing rolling upgrade."
        return 1
    fi
    if (( member_count != ${#NODES[@]} )); then
        QUORUM_MSG="Only ${member_count}/${#NODES[@]} Corosync members are present (checked via ${node}); refusing rolling upgrade."
        return 1
    fi
    QUORUM_MSG="Quorum/membership verified via ${node}: ${member_count} members, ${total_votes}/${expected_votes} votes."
    return 0
}

check_quorum() {
    quorum_status "$1" || die "$QUORUM_MSG"
    log "$QUORUM_MSG"
}

check_pve_version() {
    local node="$1"
    if [[ -z "$EXPECTED_PVE_MAJOR" ]]; then return; fi
    local ver
    ver="$(node_ssh "$node" 'pveversion')" || die "Could not read pveversion on ${node}."
    grep -Eq "pve-manager/${EXPECTED_PVE_MAJOR}\." <<< "$ver" || die "Node ${node} is not PVE major ${EXPECTED_PVE_MAJOR}: ${ver}"
}

get_running_guests() {
    local node="$1"
    node_ssh "$node" '{
            qm list 2>/dev/null | awk '\''NR > 1 && $3 == "running" { print "vm:" $1 }'\''
            pct list 2>/dev/null | awk '\''NR > 1 && $2 == "running" { print "ct:" $1 }'\''
        }'
}

# ha_sid_protected <ha-config> <sid>: true only if sid is HA-managed with
# requested state started/enabled. PVE 9.x states: a running guest whose HA
# state is stopped/disabled/ignored will NOT be migrated, so it must count
# as unprotected. Missing/unparseable state is treated as unprotected.
ha_sid_protected() {
    local config="$1" sid="$2" state
    state="$(awk -v s="$sid" '
        $0 == s { in_block=1; found=1; next }
        in_block && /^[^[:space:]]/ { exit }
        in_block && $1 == "state" { print $2; exit }
        END { if (!found) exit 2 }
    ' <<< "$config")" || return 1
    # Fail closed if the resource or its requested state cannot be parsed.
    [[ -n "$state" && ( "$state" == "started" || "$state" == "enabled" ) ]]
}

check_running_guests_are_ha_managed() {
    local node="$1" guests sid bad=0 config
    config="$(node_ssh "$node" 'ha-manager config')" || die "Could not read HA config from ${node}."
    guests="$(get_running_guests "$node")" || die "Could not list running guests on ${node}."
    if [[ -z "$guests" ]]; then log "No running guests reported on ${node}."; return; fi
    while IFS= read -r sid; do
        [[ -n "$sid" ]] || continue
        if ! ha_sid_protected "$config" "$sid"; then
            log "UNPROTECTED: running guest ${sid} on ${node} is not HA-protected (unmanaged, or HA state is not started)."; bad=1
        fi
    done <<< "$guests"
    (( bad == 0 )) || die "Running guests are not all HA-protected on ${node}; refusing to proceed."
}

# check_backups: a rolling reboot mid-backup aborts the backup. Refuse to
# start in apply mode; warn in dry-run mode.
# NOTE: the pattern uses the '[v]zdump' bracket trick on purpose. A plain
# `pgrep -f vzdump` also matches the remote `sh -c` wrapper that sshd spawns
# to run this very command, so the check fired on every node even with no
# backup running. The bracketed form matches a real vzdump command line but
# not the wrapper's own.
check_backups() {
    local node="$1"
    if node_ssh "$node" "pgrep -f '[v]zdump' >/dev/null 2>&1"; then
        if [[ "$MODE" == "apply" ]]; then
            die "A vzdump backup appears to be running on ${node}; refusing to start the rolling upgrade mid-backup."
        fi
        log "WARNING (dry run): a vzdump backup appears to be running on ${node}; an --apply run would refuse to start."
    fi
}

# ceph_state <node>:
#   0 = Ceph is configured on this cluster and the CLI responds
#   1 = Ceph is not in use here (CLI not installed, or no /etc/pve/ceph.conf)
#   2 = Ceph appears to be in use but is NOT responding (or SSH failed)
ceph_state() {
    local node="$1" rc=0
    node_ssh "$node" 'command -v ceph >/dev/null 2>&1 && test -e /etc/pve/ceph.conf' || rc=$?
    case "$rc" in
        0) ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
    node_ssh "$node" "timeout ${CEPH_CMD_TIMEOUT} ceph -s >/dev/null 2>&1" || return 2
    return 0
}

ceph_health_line() { node_ssh "$1" "timeout ${CEPH_CMD_TIMEOUT} ceph health 2>/dev/null | head -n 1"; }

# ceph_noout_enabled <node>: 0 = noout set, 1 = not set, 2 = could not determine
ceph_noout_enabled() {
    local node="$1" flags
    flags="$(node_ssh "$node" "timeout ${CEPH_CMD_TIMEOUT} ceph osd dump 2>/dev/null | awk \"/^flags / {print \\\$2; exit}\"")" || return 2
    [[ -n "$flags" ]] || return 2
    [[ ",$flags," == *",noout,"* ]]
}

# ceph_health_acceptable <node> <noout_preexisting 0|1>
# HEALTH_OK is always acceptable. If noout pre-existed this run, the single
# warning "noout flag(s) set" is also acceptable (and nothing else).
ceph_health_acceptable() {
    local node="$1" noout_pre="$2" health
    health="$(ceph_health_line "$node")" || return 1
    if [[ "$health" == "HEALTH_OK" ]]; then return 0; fi
    if (( noout_pre )) && [[ "$health" == "HEALTH_WARN noout flag(s) set" ]]; then return 0; fi
    return 1
}

require_ceph_healthy_baseline() {
    local node="$1" noout_pre="$2" health
    health="$(ceph_health_line "$node")" || die "Unable to read Ceph health from ${node}."
    if ceph_health_acceptable "$node" "$noout_pre"; then
        log "Ceph baseline OK on ${node}: ${health}"
        return 0
    fi
    die "Ceph baseline is ${health:-unknown} (checked via ${node}); expected HEALTH_OK$( (( noout_pre )) && echo ' (or only the pre-existing noout warning)')."
}

# check_survivor_health <node> [dry]: fail-closed pre-reboot gate on the health of
# every node except <node> (the one about to reboot). The survivors just
# absorbed <node>'s evacuated guests; if any survivor shows cluster
# communication distress or severe CPU saturation, rebooting now risks an HA
# watchdog self-fence cascade (observed 2026-10-17: pve2 and pve3 fenced
# within seconds of pve1's planned reboot after CPG/corosync degraded).
# In apply mode (dry=0) any problem aborts the run; the node is left parked
# in maintenance mode and a re-run resumes cleanly once the survivors are
# healthy. The gate is fully read-only, so it also runs in dry-run mode
# (dry=1) as an advisory check: problems are logged as warnings instead of
# aborting, which exercises the gate's plumbing and reports current survivor
# health before any changes are made. Thresholds are tunable via
# SURVIVOR_MAX_CPG_RETRIES and SURVIVOR_MAX_LOAD_FACTOR.
check_survivor_health() {
    local node="$1" dry="${2:-0}" survivor cpg_retries load5 nproc load_limit
    for survivor in "${NODES[@]}"; do
        if [[ "$survivor" == "$node" ]]; then continue; fi
        log "Checking survivor health on ${survivor} before rebooting ${node}..."

        # CPG retry storm: sustained pmxcfs "cpg_send_message retry" lines mean
        # cluster communication is already degraded. Count with awk (exits 0
        # even on zero matches, unlike grep -c); the trailing exit propagates
        # journalctl's status so a broken journal fails closed instead of
        # reading as "no retries".
        cpg_retries="$(node_ssh "$survivor" 'journalctl --since "10 minutes ago" --no-pager 2>/dev/null | awk "/cpg_send_message retry/ {c++} END {print c+0}"; exit ${PIPESTATUS[0]}')" \
            || { gate_problem "$dry" "$node" "Could not read journal on ${survivor} for the survivor health check."; continue; }
        if ! [[ "$cpg_retries" =~ ^[0-9]+$ ]]; then
            gate_problem "$dry" "$node" "Could not parse CPG retry count from ${survivor}."; continue
        fi
        log "  ${survivor}: ${cpg_retries} pmxcfs CPG retries in the last 10 minutes (limit ${SURVIVOR_MAX_CPG_RETRIES})."
        if (( cpg_retries > SURVIVOR_MAX_CPG_RETRIES )); then
            gate_problem "$dry" "$node" "Survivor ${survivor} shows ${cpg_retries} pmxcfs CPG retries in the last 10 minutes (limit ${SURVIVOR_MAX_CPG_RETRIES}): cluster communication is degraded. Rebooting ${node} now risks an HA watchdog self-fence cascade. Investigate ${survivor} first."; continue
        fi

        # CPU saturation: a 5-minute load average far above CPU count can
        # starve the realtime cluster stack (corosync/pmxcfs/HA watchdog).
        load5="$(node_ssh "$survivor" "awk '{print \$1}' /proc/loadavg")" \
            || { gate_problem "$dry" "$node" "Could not read load average on ${survivor}."; continue; }
        nproc="$(node_ssh "$survivor" 'nproc')" \
            || { gate_problem "$dry" "$node" "Could not read CPU count on ${survivor}."; continue; }
        if ! [[ "$load5" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            gate_problem "$dry" "$node" "Could not parse load average from ${survivor}."; continue
        fi
        if ! [[ "$nproc" =~ ^[0-9]+$ ]] || (( nproc == 0 )); then
            gate_problem "$dry" "$node" "Could not parse CPU count from ${survivor}."; continue
        fi
        load_limit="$(awk -v f="$SURVIVOR_MAX_LOAD_FACTOR" -v n="$nproc" 'BEGIN { printf "%g", f * n }')"
        log "  ${survivor}: 5-minute load average ${load5} on ${nproc} CPUs (limit ${load_limit})."
        if awk -v l="$load5" -v f="$SURVIVOR_MAX_LOAD_FACTOR" -v n="$nproc" 'BEGIN { exit !(l > f * n) }'; then
            gate_problem "$dry" "$node" "Survivor ${survivor} is saturated: 5-minute load average ${load5} exceeds ${SURVIVOR_MAX_LOAD_FACTOR}x CPU count (${nproc} CPUs, limit ${load_limit}). Rebooting ${node} now risks an HA watchdog self-fence cascade. Investigate ${survivor} first."; continue
        fi
    done
    if (( dry )); then
        log "Survivor health advisory check done for ${node} (dry run; any warnings above would abort an --apply run)."
    else
        log "Survivor health OK for reboot of ${node}."
    fi
}

# gate_problem <dry> <node> <message>: report a survivor-gate problem. In
# apply mode (dry=0) aborts the run via die (fail closed). In dry-run mode
# (dry=1) logs a warning and returns 0 so the caller moves on to the next
# survivor instead of aborting the dry run. Note: it must return 0, not 1, in
# dry-run mode — callers invoke it as `gate_problem ...; continue`, and under
# `set -e` a non-zero return there would kill the whole dry run instead of
# warning and continuing.
gate_problem() {
    local dry="$1" node="$2"; shift 2
    if (( dry )); then
        log "WARNING (dry run): $* (an --apply run would abort here instead of rebooting ${node})."
        return 0
    fi
    die "$* Refusing to reboot ${node}."
}

# Return success only when every service assigned to this node has a known
# inactive state. Unknown formats/states fail closed rather than permitting a
# reboot while an HA service may still be active here.
node_evacuated() {
    local node="$1" status line state re
    status="$(node_ssh "$node" 'ha-manager status')" || return 1
    re="^service[[:space:]]+[^[:space:]]+[[:space:]]+\(${node},[[:space:]]*([^)]*)\)"
    while IFS= read -r line; do
        [[ "$line" == service\ * ]] || continue
        if [[ "$line" =~ $re ]]; then
            state="${BASH_REMATCH[1]}"
            case "$state" in
                stopped|disabled|ignored) ;;
                *) return 1 ;;
            esac
        elif [[ "$line" == *"(${node},"* ]]; then
            # A service is assigned to this node but its state format is not
            # recognized. Do not assume it is safe to reboot.
            return 1
        fi
    done <<< "$status"
    return 0
}

wait_for_reboot() {
    local node="$1" old_boot_id="$2"
    local elapsed=0 down_seen=0 new_boot_id=""
    log "Waiting up to ${DOWN_TIMEOUT}s for ${node} to stop answering SSH..."
    while (( elapsed < DOWN_TIMEOUT )); do
        if ssh_is_up "$node"; then
            # If the outage was too short to observe, a changed boot ID still
            # proves the reboot happened.
            new_boot_id="$(node_ssh "$node" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)"
            if [[ -n "$new_boot_id" && "$new_boot_id" != "$old_boot_id" ]]; then
                log "${node} reboot verified (boot ID changed; outage was too brief to observe)."
                return 0
            fi
        else
            down_seen=1; break
        fi
        sleep 5; elapsed=$((elapsed + 5))
    done
    (( down_seen )) || die "${node} never became unreachable and its boot ID did not change. Not treating this as a reboot."
    log "SSH down for ${node}; waiting up to ${SSH_UP_TIMEOUT}s for return..."
    wait_for "$SSH_UP_TIMEOUT" 10 ssh_is_up "$node" || die "${node} did not return over SSH."
    new_boot_id="$(node_ssh "$node" 'cat /proc/sys/kernel/random/boot_id')" || die "SSH returned on ${node}, but boot ID unreadable."
    [[ -n "$new_boot_id" && "$new_boot_id" != "$old_boot_id" ]] || die "${node} SSH returned but boot ID did not change."
    log "${node} reboot verified (boot ID changed)."
}

# Any package install/upgrade/removal goes through HA maintenance and a reboot;
# APT's simulation cannot reliably predict package-triggered reboot needs.
# Here-string (not a pipe) so grep -q's early exit cannot trigger SIGPIPE/141.
detect_upgrade_candidate() {
    grep -Eq '^(Inst|Remv)[[:space:]]+' <<< "$1"
}

# Run dist-upgrade on the node inside a transient systemd unit so it keeps
# running (and finishes cleanly) even if the SSH session drops. Keeps existing
# config files on conffile conflicts instead of prompting.
remote_dist_upgrade() {
    local node="$1" unit="pve-rolling-upgrade-${TIMESTAMP}-${node}"
    node_ssh "$node" "systemd-run --quiet --wait --pipe --collect --unit='${unit}' --setenv=DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade"
}

run_node() {
    local node="$1" apt_sim current_kernel reboot_candidate=0 use_ceph=0 noout_pre=0
    local old_boot_id new_kernel ceph_rc=0 noout_rc=0

    log "========== Node ${node} =========="
    check_quorum "$node"
    check_pve_version "$node"
    check_running_guests_are_ha_managed "$node"
    check_backups "$node"

    if [[ "$MODE" == "apply" ]]; then
        log "Refreshing APT package lists on ${node}..."
        node_ssh "$node" 'apt-get update'
    else
        log "DRY RUN: skipping apt-get update; simulation uses cached lists."
    fi

    apt_sim="$(node_ssh "$node" 'apt-get --just-print dist-upgrade')" || die "APT simulation failed on ${node}."
    current_kernel="$(node_ssh "$node" 'uname -r')" || die "Could not read current kernel on ${node}."
    log "Current kernel on ${node}: ${current_kernel}"
    log "APT simulation tail on ${node}:"
    printf '%s\n' "$apt_sim" | tail -n 25

    if detect_upgrade_candidate "$apt_sim"; then
        reboot_candidate=1
        log "APT simulation shows package changes; using HA maintenance and reboot for safety."
    elif node_ssh "$node" 'test -e /var/run/reboot-required'; then
        # Note: this marker is Ubuntu-style and normally absent on PVE.
        reboot_candidate=1
        log "Node already has /var/run/reboot-required."
    else
        log "APT simulation shows no package changes and no reboot-required marker."
    fi

    if (( reboot_candidate )); then
        if (( ALLOW_REBOOT == 0 )); then
            if [[ "$MODE" == "apply" ]]; then
                die "${node} has package changes that this safety policy routes through a reboot, but --no-reboot was specified. No packages were installed on this node (apt-get update was already run)."
            fi
            log "WARNING (dry run): ${node} needs a reboot but --no-reboot is set; an --apply run would abort here."
        fi

        # Read-only preflight checks (also run in dry-run mode).
        node_ssh "$node" 'systemctl is-active --quiet pve-ha-lrm' \
            || die "pve-ha-lrm is not active on ${node}; HA maintenance/evacuation cannot be trusted. Aborting."

        ceph_rc=0
        ceph_state "$node" || ceph_rc=$?
        case "$ceph_rc" in
            0)
                use_ceph=1
                noout_rc=0
                ceph_noout_enabled "$node" || noout_rc=$?
                case "$noout_rc" in
                    0) noout_pre=1; log "Ceph noout is already set on the cluster; it will be preserved." ;;
                    1) noout_pre=0 ;;
                    *) die "Could not determine current Ceph noout state via ${node}; refusing to alter it." ;;
                esac
                require_ceph_healthy_baseline "$node" "$noout_pre"
                ;;
            1)
                log "Ceph is not configured/installed on ${node}; Ceph steps skipped."
                ;;
            *)
                die "Ceph appears to be in use on ${node} but is not responding to 'ceph -s' (timeout ${CEPH_CMD_TIMEOUT}s) or SSH failed; refusing to continue."
                ;;
        esac
    fi

    # The survivor health gate is fully read-only, so run it in dry-run mode
    # too: this exercises its plumbing (journalctl/awk/loadavg paths on every
    # survivor) and reports current survivor health before any changes are
    # made. In dry-run it warns instead of aborting.
    if (( reboot_candidate )) && [[ "$MODE" == "dry-run" ]]; then
        check_survivor_health "$node" 1
    fi

    if [[ "$MODE" == "dry-run" ]]; then
        if (( reboot_candidate )); then
            log "DRY RUN: would use HA maintenance, upgrade, and reboot ${node}."
        else
            log "DRY RUN: would find no package changes and leave ${node} running."
        fi
        return
    fi

    if (( reboot_candidate == 0 )); then
        # Unreachable in practice: any Inst/Remv line sets reboot_candidate=1
        # above, so a zero-change simulation means there is nothing to install.
        log "No package changes on ${node}; nothing to install."
        return
    fi

    old_boot_id="$(node_ssh "$node" 'cat /proc/sys/kernel/random/boot_id')" || die "Could not capture boot ID on ${node}."

    log "Enabling HA node maintenance on ${node}..."
    node_ssh "$node" "ha-manager crm-command node-maintenance enable ${node}"
    check_quorum "$node"

    log "Waiting up to ${EVAC_TIMEOUT}s for HA evacuation of ${node}..."
    wait_for "$EVAC_TIMEOUT" "$POLL_INTERVAL" node_evacuated "$node" || die "HA evacuation timed out for ${node}. Left in maintenance mode."
    log "HA evacuation verified for ${node}."

    if (( use_ceph )); then
        if (( noout_pre )); then
            log "Ceph noout was already set; preserving its pre-existing state."
        else
            log "Setting Ceph noout flag (cluster-wide)..."
            # Mark as ours before issuing the command, so an ambiguous failure
            # (e.g. timeout after the flag was applied) still produces a warning.
            CEPH_NOOUT_SET=1
            CEPH_NOOUT_NODE="$node"
            node_ssh "$node" "timeout ${CEPH_CMD_TIMEOUT} ceph osd set noout"
        fi
    fi

    # Re-check full membership immediately before making a node unavailable.
    check_quorum "$node"

    # The survivors just absorbed this node's evacuated guests. If any of them
    # shows cluster-communication distress or severe load, rebooting now risks
    # an HA watchdog self-fence cascade; abort fail-closed instead.
    check_survivor_health "$node" 0

    log "Applying dist-upgrade on ${node}..."
    remote_dist_upgrade "$node"

    log "Scheduling reboot on ${node}..."
    node_ssh "$node" "shutdown -r +1 'PVE rolling upgrade'"

    wait_for_reboot "$node" "$old_boot_id"

    new_kernel="$(node_ssh "$node" 'uname -r')" || die "Could not read kernel after reboot on ${node}."
    log "Kernel after reboot on ${node}: ${new_kernel} (was ${current_kernel})"

    # sshd returns before corosync/pmxcfs rejoin; retry rather than fail fast.
    log "Waiting up to ${QUORUM_TIMEOUT}s for ${node} to rejoin with full membership..."
    wait_for "$QUORUM_TIMEOUT" 10 quorum_status "$node" || die "Cluster did not return to full membership after reboot of ${node}: ${QUORUM_MSG}"
    log "$QUORUM_MSG"

    log "Waiting up to ${LRM_TIMEOUT}s for pve-ha-lrm on ${node}..."
    wait_for "$LRM_TIMEOUT" 10 node_ssh "$node" 'systemctl is-active --quiet pve-ha-lrm' || die "pve-ha-lrm did not become active on ${node} after reboot. Left in maintenance mode."

    if (( use_ceph )); then
        if (( CEPH_NOOUT_SET )); then
            log "Removing Ceph noout flag introduced by this run..."
            node_ssh "$node" "timeout ${CEPH_CMD_TIMEOUT} ceph osd unset noout"
            CEPH_NOOUT_SET=0
            CEPH_NOOUT_NODE=""
        else
            log "Leaving pre-existing Ceph noout flag untouched."
        fi
        log "Waiting up to ${CEPH_TIMEOUT}s for Ceph health to recover..."
        if ! wait_for "$CEPH_TIMEOUT" 15 ceph_health_acceptable "$node" "$noout_pre"; then
            die "Ceph did not return to a healthy state after the reboot/noout handling. Inspect before continuing."
        fi
        log "Ceph health OK."
    fi

    log "Disabling HA node maintenance on ${node}..."
    node_ssh "$node" "ha-manager crm-command node-maintenance disable ${node}"
    check_quorum "$node"
    log "Node ${node} completed."
}

log "Log file: ${LOG_FILE}"
log "Mode: ${MODE}; nodes: $(nodes_str); expected PVE major: ${EXPECTED_PVE_MAJOR:-any}"
check_known_hosts

if [[ "$MODE" == "dry-run" ]]; then
    log "DRY RUN ONLY. No changes will be made."
else
    log "APPLY MODE. Packages may be changed and nodes may reboot."
    if (( SKIP_CONFIRM == 0 )); then
        echo ""
        echo "You are about to APPLY upgrades to: $(nodes_str)"
        echo "Log: $LOG_FILE"
        read -r -p "Type YES to continue: " confirm
        [[ "$confirm" == "YES" ]] || die "Aborted by user."
    fi
fi

for node in "${NODES[@]}"; do
    ssh_is_up "$node" || die "Cannot SSH to ${node} as ${SSH_USER}."
    check_pve_version "$node"
done
check_quorum "${NODES[0]}"

for node in "${NODES[@]}"; do
    run_node "$node"
done

log "All nodes processed successfully."
