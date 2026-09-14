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
#
#   scripts/sqllint.sh                 lint every file in sql/
#   scripts/sqllint.sh sql/p13_x.sql   lint one
#
set -uo pipefail

FILES=("$@")
if [ ${#FILES[@]} -eq 0 ]; then
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

if [ "$fail" -eq 0 ]; then
    echo "clean: ${#FILES[@]} file(s)"
fi
exit "$fail"
