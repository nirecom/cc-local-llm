#!/bin/sh
# The writer's half of the litellm-server/config.yaml tier contract: read the
# whole file strictly, then rewrite one route in place. Grammar and rationale:
# docs/architecture.md. Sourced, never executed.
_llc_read() {
    # `_llc_read <config>` -- one line per finding, field one before the `|`:
    #   err|<message>        a schema violation; the caller must refuse the run
    #   name|<model_name>    a route, in file order
    #   map|<tier>|<name>    the route that claims <tier>
    #   model|<name>|<value> that route's litellm_params.model value
    # The launchers read this grammar leniently, but set-model.sh publishes
    # what it reads, so anything ambiguous stops it before every host sees it.
    awk '
        function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }
        function bad(m) { print "err|config.yaml: " m }
        function claim(tok) {
            if (tok !~ /^(haiku|sonnet|fable|opus|subagent)$/) {
                bad("\"" tok "\" is not a Claude Code tier (haiku, sonnet, fable, opus, subagent).")
                return
            }
            if (tok in anntok) {
                bad("the " tok " tier is repeated inside one annotation on route \"" cur "\".")
                return
            }
            anntok[tok] = 1
            if (tok in owner) {
                bad("the " tok " tier is claimed twice, by \"" owner[tok] "\" and by \"" cur "\".")
                return
            }
            owner[tok] = cur
            print "map|" tok "|" cur
        }
        function tokens(payload, sep,   n, parts, i, t) {
            split("", anntok)
            if (sep == "P") n = split(payload, parts, ",")
            else n = split(payload, parts, /[ \t]+/)
            for (i = 1; i <= n; i++) {
                t = trim(parts[i])
                if (t != "") claim(t)
            }
        }
        BEGIN { open = 0; startline = -1; nann = 0; nP = 0; nF = 0 }
        {
            line = $0
            sub(/\r$/, "", line)

            # Any model_name line closes the block before it, so a malformed
            # name never lends its annotation to the route above.
            if (line ~ /^  - model_name:/) {
                open = 0
                rest = substr(line, 16)
                name = trim(rest)
                if (name == "") {
                    bad("a route has an empty model_name, so the tier annotated on it maps to a record no client can address.")
                    next
                }
                if (name ~ /^os\.environ\//) {
                    bad("model_name \"" name "\" is still delegated to an environment variable; os.environ/ is the pre-migration shape and a routing name must be a literal.")
                    next
                }
                if (name ~ /^["'"'"']/ || name ~ /["'"'"']$/) {
                    bad("model_name " name " is quoted; a quoted literal reads as one string to a YAML parser and another to a line reader, so routing names are written unquoted.")
                    next
                }
                if (rest !~ /^[ ]+[^ \t]+[ ]*$/ || name !~ /^[A-Za-z0-9._-]+$/) {
                    bad("model_name \"" name "\" is outside the routing-name contract (A-Za-z0-9, dot, underscore, hyphen).")
                    next
                }
                if (name in seen) {
                    bad("the routing name \"" name "\" is a duplicate -- two routes answer to it, so which backend serves it is whatever the router picks.")
                    next
                }
                seen[name] = 1
                print "name|" name
                open = 1; cur = name; startline = NR; nann = 0
                next
            }
            if (line != "" && line !~ /^[ \t]/) { open = 0 }

            look = (tolower(line) ~ /ccgw[-_]?tiers?/)
            if (open == 0) {
                if (look) bad("the annotation \"" trim(line) "\" sits outside every route block, so no route is annotated by it.")
                next
            }
            if (line ~ /^      ccgw_tiers:[ ]*\[[^]]*\][ ]*$/) {
                payload = line
                sub(/^      ccgw_tiers:[ ]*\[/, "", payload)
                sub(/\][ ]*$/, "", payload)
                nP++; nann++
                if (nann > 1) bad("route \"" cur "\" carries a duplicate tier annotation; two annotation lines on one route make a first-wins and a last-wins reader disagree.")
                tokens(payload, "P")
                next
            }
            if (NR == startline + 1 && line ~ /^    # ccgw-tiers:[ ]+.+$/) {
                payload = line
                sub(/^    # ccgw-tiers:[ ]+/, "", payload)
                nF++; nann++
                if (nann > 1) bad("route \"" cur "\" carries a duplicate tier annotation; two annotation lines on one route make a first-wins and a last-wins reader disagree.")
                tokens(payload, "F")
                next
            }
            if (look) {
                bad("the annotation \"" trim(line) "\" on route \"" cur "\" is in neither accepted form -- the bracket form indented six spaces inside the block, or the comment form indented four on the line right after it.")
                next
            }
            if (line ~ /^      model:[ ]+/ && !(cur in modelled)) {
                modelled[cur] = 1
                print "model|" cur "|" trim(substr(line, 13))
            }
        }
        END {
            if (nP > 0 && nF > 0)
                print "err|config.yaml: both annotation formats are mixed in one file; every route has to use the same form, or two readers resolve the file differently."
        }
    ' "$1"
}

_llc_rewrite() {
    # `_llc_rewrite <config> <old-name> <new-name> <provider>` prints the file
    # with that route's model_name and litellm_params.model moved to the new
    # key. Every other byte, annotation and line ending included, is copied
    # through: an operator who chose the comment form did so to keep their own
    # YAML validator quiet, and a rebuilt block hands them back the error.
    awk -v oldname="$2" -v newname="$3" -v provider="$4" '
        BEGIN { intarget = 0; done = 0 }
        {
            line = $0
            cr = ""
            if (sub(/\r$/, "", line)) cr = "\r"
            if (line ~ /^  - model_name:/) {
                nm = substr(line, 16)
                gsub(/^[ \t]+/, "", nm); gsub(/[ \t]+$/, "", nm)
                if (nm == oldname) {
                    intarget = 1
                    print "  - model_name: " newname cr
                    next
                }
                intarget = 0
            } else if (line != "" && line !~ /^[ \t]/) {
                intarget = 0
            }
            if (intarget && !done && line ~ /^      model:[ ]+/) {
                done = 1
                print "      model: " provider "/" newname cr
                next
            }
            print $0
        }
    ' "$1"
}
