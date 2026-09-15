#!/usr/bin/env bash
#
# Catch the four mistakes this project keeps making, before Snowflake does.
#
# Each of these has cost at least one round trip, and three of the four are
# already written down as lessons in the build log -- which is the argument
# for a script rather than a better memory.
#
#   1. Reserved words used as column aliases. ROWS and CHECK have each bitten
#      twice. "SELECT x AS ROWS" is a syntax error at the alias, and the error
#      points at the alias rather than saying the word is reserved.
#   2. A literal $$ inside a $$-quoted procedure body. Ends the body early and
#      the error lands somewhere unrelated.
#   3. Unqualified DROP PROCEDURE / DROP TABLE after an application package is
#      created, because that makes itself the current database and dropping it
#      leaves the session with none.
#   4. Backslash escapes inside a Python procedure body that are meant to reach
#      SQL as real characters. "\n" written in a heredoc arrives as two
#      characters, not a newline.
#   5. A file in sql/ that scripts/rebuild.sh has never heard of, or a build
#      step pointing at a file that no longer exists. The manifest in
#      rebuild.sh is the only record of which of these files are build steps,
#      so a rename that misses it breaks a rebuild months later and silently.
#      Corpus-level, so it runs only on a full lint.
#
#   scripts/sqllint.sh                 lint every file in sql/
#   scripts/sqllint.sh sql/p13_x.sql   lint one
#
set -uo pipefail

ARGC=$#
FILES=("$@")
if [ "$ARGC" -eq 0 ]; then
    FILES=(sql/*.sql)
fi

# Not exhaustive -- the ones that plausibly read as good column names. A full
# reserved-word list would flag half the corpus and get ignored, which is worse
# than a short list that gets believed.
RESERVED='ROWS|CHECK|ROW|ORDER|GROUP|VALUES|TABLE|VIEW|SELECT|FROM|WHERE|CASE|WHEN|THEN|ELSE|END|IS|IN|NOT|AND|OR|NULL|TRUE|FALSE|LIKE|ASC|DESC|UNION|ALL|DISTINCT|INTO|SET|WITH|AS|ON|BY|CONSTRAINT|CROSS|CURRENT|GRANT|INCREMENT|LEFT|RIGHT|FULL|INNER|JOIN|NATURAL|OF|QUALIFY|SAMPLE|SOME|START|TO|TRIGGER|UNIQUE|USING|WHENEVER'

fail=0

for f in "${FILES[@]}"; do
    [ -f "$f" ] || continue
    problems=""

    # 1. Reserved-word aliases. Strip comments first: the fix that finally made
    #    the Part 12 validator trustworthy was ordering literals, then dollar
    #    blocks, then comments -- a comment containing "AS ROWS" is not a bug.
    hits=$(sed 's/--.*//' "$f" \
           | grep -nEi "[[:space:]]AS[[:space:]]+($RESERVED)[[:space:]]*(,|$|\))" \
           || true)
    [ -n "$hits" ] && problems+="  reserved word used as an alias:"$'\n'"$(echo "$hits" | sed 's/^/    /')"$'\n'

    # 2. A dollar pair inside a dollar-quoted body.
    body=$(awk '/\$\$/{n++; next} n==1' "$f" 2>/dev/null || true)
    if [ -n "$body" ] && echo "$body" | grep -q '\$\$'; then
        problems+="  literal \$\$ inside a \$\$-quoted body -- build it from chr(36)"$'\n'
    fi

    # 3. Unqualified DROP in a file that creates an application package.
    if grep -qi 'CREATE APPLICATION PACKAGE' "$f"; then
        hits=$(sed 's/--.*//' "$f" \
               | grep -nEi '^[[:space:]]*DROP[[:space:]]+(PROCEDURE|TABLE|VIEW|FUNCTION)[[:space:]]+(IF[[:space:]]+EXISTS[[:space:]]+)?[A-Z_]+\.' \
               | grep -viE '[A-Z_]+\.[A-Z_]+\.' || true)
        [ -n "$hits" ] && problems+="  unqualified DROP in a file that creates an application package:"$'\n'"$(echo "$hits" | sed 's/^/    /')"$'\n'
    fi

    # 4. Backslash escapes inside the procedure body.
    if [ -n "$body" ] && echo "$body" | grep -qE '\\\\[nrt]'; then
        problems+="  double-escaped \\\\n inside a procedure body -- arrives as two characters, use chr(10)"$'\n'
    fi

    if [ -n "$problems" ]; then
        echo "$f"
        printf '%s' "$problems"
        fail=1
    fi
done

# 5. Every file in sql/ is either a build step or explicitly excluded, and
#    every build step exists. Only meaningful over the whole corpus.
if [ "$ARGC" -eq 0 ] && [ -f scripts/rebuild.sh ]; then
    known=$( { grep -oE 'sql/[a-z0-9_]+\.sql' scripts/rebuild.sh | sed 's|^sql/||; s|\.sql$||'
               sed -n '/^NOT_IN_BUILD=/,/^Each records/p' scripts/rebuild.sh \
                 | grep -oE '\b(p[0-9]+_[a-z_0-9]+|teardown)\b'; } | sort -u )
    have=$(ls sql/*.sql | sed 's|^sql/||; s|\.sql$||' | sort -u)

    orphans=$(comm -23 <(echo "$have") <(echo "$known"))
    if [ -n "$orphans" ]; then
        echo "scripts/rebuild.sh"
        echo "  in sql/ but neither a build step nor listed as excluded:"
        echo "$orphans" | sed 's|^|    sql/|; s|$|.sql|'
        fail=1
    fi

    for path in $(grep -oE 'sql/[a-z0-9_]+\.sql' scripts/rebuild.sh | sort -u); do
        [ -f "$path" ] && continue
        echo "scripts/rebuild.sh"
        echo "  build step points at a file that does not exist: $path"
        fail=1
    done
fi

# 6. The same check over scripts/. sql/ has had coverage since this linter was
#    written and scripts/ never did, which is how scripts/p10_truth.sh -- the
#    only thing that creates OPS.COMPLAINT_TRUTH, read by three later steps --
#    sat in neither the manifest nor the exclusion list while this linter
#    reported clean over 58 files. A build step that is invisible to the runner
#    is invisible to the linter too unless the linter looks.
if [ "$ARGC" -eq 0 ] && [ -f scripts/rebuild.sh ]; then
    excluded=$(sed -n '/^NOT_IN_BUILD=/,/^Each records/p' scripts/rebuild.sh \
                 | grep -oE '\b[a-z0-9_]+\.sh\b' | sort -u)
    for path in scripts/*.sh; do
        base=$(basename "$path")
        grep -qF "$base" scripts/rebuild.sh && continue
        printf '%s\n' "$excluded" | grep -qxF "$base" && continue
        echo "scripts/rebuild.sh"
        echo "  in scripts/ but neither run by the build nor listed as excluded: $path"
        fail=1
    done
fi

if [ "$fail" -eq 0 ]; then
    echo "clean: ${#FILES[@]} file(s), and rebuild.sh accounts for all of them"
fi
exit "$fail"
