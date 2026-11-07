# Saved node endpoint assignments are data: node HTTP SOCKS, one row per line.
# Plan from saved/catalogue/local-slot data only; never adopt or allocate owners.
_node_ports_plan() {  # [extra canonical name] [catalogue/local slot]
    {
        printf 'B|%s|%s|%s|%s\n' "$CLAUDE_HTTP_PORT" "$CLAUDE_SOCKS_PORT" "$CLAUDE_NODE_HTTP_BASE" "$CLAUDE_NODE_SOCKS_BASE"
        printf '%s\n' "${CLAUDE_NODE_PORTS:-}" | while IFS= read -r row; do printf 'R|%s\n' "$row"; done
        _nodes_tsv 2>/dev/null | while IFS='|' read -r idx name alias rest; do
            [ -z "$name" ] || printf 'K|%s|%s|%s\n' "$name" "$idx" "$alias"
        done
        if [ -n "${CLAUDE_PROXY_LOCAL_NODES:-}" ] && [ -f "$CLAUDE_PROXY_LOCAL_NODES" ]; then
            while read -r name idx rest; do
                case "$name" in ''|\#*) continue;; esac
                printf 'L|%s|%s\n' "$name" "$idx"
            done < "$CLAUDE_PROXY_LOCAL_NODES"
        fi
        [ -z "${1:-}" ] || printf 'K|%s|%s|\n' "$1" "$2"
    } | awk -F'|' -v allow_conflicts="${3:-0}" '
        function fail(message) { print "[Err] Node ports: " message > "/dev/stderr"; bad=1 }
        function port(p) { return p ~ /^[1-9][0-9]*$/ && length(p)<=5 && p+0<=65535 }
        function nameok(n) { return n ~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/ }
        function add(n, h, s) { if (!(n in listed)) { order[++count]=n; listed[n]=1 }; http[n]=h; socks[n]=s }
        function claim(p, label) { if (allow_conflicts==1) return; if (p in occupied) fail(label " conflicts with " occupied[p] " on port " p); else occupied[p]=label }
        $1=="B" { mainh=$2; mains=$3; baseh=$4; bases=$5; next }
        $1=="R" {
            row=substr($0,3); sub(/#.*/,"",row); gsub(/^[ \t]+|[ \t]+$/,"",row)
            if (row=="") next
            fields=split(row,a,/[ \t]+/); n=a[1]
            if (fields!=3 || !nameok(n) || !port(a[2]) || !port(a[3])) { fail("invalid assignment: " row); next }
            if (n in saved) { fail("duplicate node " n); next }
            saved[n]=1; add(n,a[2],a[3]); next
        }
        $1=="K" {
            if ($2 in known) { if (known[$2]!=$3) fail("conflicting catalogue slots for " $2); next }
            known[$2]=$3; aliases[$4]=1; kn[++nk]=$2; next
        }
        $1=="L" { ln[++nl]=$2; li[nl]=$3; next }
        END {
            if (!port(mainh) || !port(mains) || !port(baseh) || !port(bases)) fail("main ports and node bases must be from 1 to 65535 without leading zeroes")
            claim(mainh,"main HTTP"); claim(mains,"main SOCKS")
            for (i=1;i<=nk;i++) {
                n=kn[i]; idx=known[n]
                if (!nameok(n) || idx !~ /^[0-9]+$/ || length(idx)>5) { fail("invalid node or slot: " n); continue }
                if (!(n in saved)) add(n,baseh+idx,bases+idx)
            }
            for (i=1;i<=nl;i++) {
                n=ln[i]; idx=li[i]
                if (n in aliases || n in known) continue
                # Machine-written slot file: skip malformed lines like _node_local_slot does.
                if (!nameok(n) || idx !~ /^[0-9]+$/ || length(idx)>5) continue
                if (!(n in listed)) add(n,baseh+idx,bases+idx)
            }
            for (i=1;i<=count;i++) {
                n=order[i]; h=http[n]; s=socks[n]
                if (!port(h) || !port(s)) { fail("ports for " n " must be from 1 to 65535 without leading zeroes"); continue }
                claim(h,n " HTTP"); claim(s,n " SOCKS")
            }
            if (bad) exit 1
            for (i=1;i<=count;i++) { n=order[i]; print n "|" http[n] "|" socks[n] }
        }'
}
_node_ports_saved() {  # <canonical name> <catalogue/local slot> -> HTTP SOCKS
    local plan
    plan=$(_node_ports_plan "$1" "$2" 1) || return 1
    printf '%s\n' "$plan" | awk -F'|' -v name="$1" '$1==name {print $2 " " $3; found=1; exit} END {if (!found) exit 1}'
}
_node_ports_validate() { _node_ports_plan >/dev/null; }
_node_ports_rows() {
    local plan
    plan=$(_node_ports_plan '' '' 1) || return 1
    printf '%s\n' "$plan" | tr '|' ' '
}
_node_ports_editor_section() {
    local rows
    rows=$(_node_ports_rows) || return 1
    printf "%s\n%s\n%s\n%s\n" '# BEGIN CLAUDE NODE PORTS' "CLAUDE_NODE_PORTS='" "$rows'" '# END CLAUDE NODE PORTS'
}
