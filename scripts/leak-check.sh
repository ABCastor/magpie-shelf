#!/usr/bin/env bash
# Fails when a tracked file carries something that belongs to one machine or
# one person rather than to the product.
#
# The patterns are generic on purpose. A workflow that greps for the author's
# actual name or actual home directory publishes them, which is the thing it
# was written to prevent.
#
# Runs over tracked files only, so a local scratch file cannot fail the build.
#
# The commit-author check below reads history, and it is EXPECTED TO FAIL in a
# working repository whose history predates the decision to publish. That is
# the check telling the truth: that history is exactly what must not go out.
# The fix is a fresh repository built from an audited export, not a weaker
# pattern here. It passes in the repository that actually gets published,
# which is the one the CI job runs in.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

fail=0

report() {
    fail=1
    printf '%s\n' "$1"
}

# A real home directory. `/Users/<name>/` where <name> is not a documented
# placeholder. Anything user-specific belongs behind $HOME or ~.
home_hits=$(
    git grep -nIE '/Users/[A-Za-z0-9._-]+/' -- . \
        | grep -vE '/Users/(you|user|username|me|example|someone|CHANGE-ME|<[^>]+>|\$\{?[A-Z_]+\}?)/' \
        || true
)
[ -n "$home_hits" ] && report "Absolute home paths (use \$HOME, ~, or a runtime path):
$home_hits"

# A real email address. The noreply form used for commit identity is fine;
# so is anything at example.com.
#
# This block once carried a second filter meant to skip URLs, written as
# '^\S+:\s*//'. Because a grep hit begins "path:line:", that pattern matched
# every "//" comment in the codebase and the check could not fail at all. It
# was caught by planting an address and watching nothing happen. Removed
# rather than repaired: the address pattern needs an @, which a bare URL
# does not have.
email_hits=$(
    git grep -nIE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' -- . \
        | grep -vE '@(example\.(com|org|net)|users\.noreply\.github\.com|sparkle-project\.org|2x)' \
        || true
)
[ -n "$email_hits" ] && report "Email addresses:
$email_hits"

# Files that describe how the work gets made rather than what the product is.
for f in AGENTS.md CHANGES.log PRODUCT.md docs/FEATURE-RESEARCH.md; do
    if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
        report "Working-notes file is tracked and would be published: $f"
    fi
done

# A personal address in commit METADATA rather than in a file.
#
# This block exists because the file scan above was blind to it: every commit
# in this repository was authored with a real personal address for months, and
# nothing noticed, because an author line is not file content. GitHub's
# per-user noreply form is the one to use, and it is set repo-locally.
author_hits=$(
    git log --format='%an <%ae>%n%cn <%ce>' -n 500 \
        | sort -u \
        | grep -vE '@users\.noreply\.github\.com>' \
        || true
)
[ -n "$author_hits" ] && report "Commit authors carrying a real address (use the GitHub noreply form, set repo-locally):
$author_hits"

# Attribution that claims a non-human wrote part of this.
attrib_hits=$(git log --format='%H %s%n%b' -n 200 | grep -iE 'co-authored-by|generated with' || true)
[ -n "$attrib_hits" ] && report "Commit trailers claiming non-human authorship:
$attrib_hits"

if [ "$fail" -ne 0 ]; then
    echo
    echo "leak-check failed."
    exit 1
fi

echo "leak-check passed."
