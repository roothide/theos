#!/usr/bin/env bash
#
# Fork Sync — rebase roothide/theos and its forked submodules onto upstream theos/*.
#
# Policy: "follow the superproject gitlink".
#   A forked submodule is rebased onto the EXACT upstream commit that the upstream
#   SUPERPROJECT references via its gitlink — NOT the submodule's branch tip. If
#   upstream did not move a submodule's gitlink, that submodule is left untouched.
#   This keeps the three forks consistent with upstream's integrated/tested state,
#   and means an upstream submodule that advanced without the superproject bumping
#   its reference is intentionally ignored.
#
# Order (chosen so the only rebase that needs a clean work tree runs first):
#   0. fetch + short-circuit if upstream already merged
#   1. rebase the superproject (submodules still clean at recorded gitlinks)
#   2. rebase each forked submodule onto its upstream gitlink target
#   3. pin the superproject gitlinks to the rebased submodule tips
#   4. empty-result guard (compare trees, not commits)
#   5. push — submodules FIRST, then superproject (force-with-lease, explicit SHA)
#
# On any real conflict (or infra error) the script exits non-zero so the Actions run
# fails and GitHub sends its built-in failure email. No issues are filed.
#
# Env:
#   THEOS_SYNC_TOKEN  PAT with contents:write + workflows:write on roothide/{theos,headers,lib} (push only)
#   DRY_RUN                "true" => do everything locally but never push
#
# NOTE: `set -x` is deliberately NOT used — the push URL embeds the PAT.
set -euo pipefail

UPSTREAM_SUPER_URL="https://github.com/theos/theos.git"
FORKED_SUBS=(vendor/include vendor/lib)
# The gitlink bumps live in their own clearly-labelled commit (not folded into a roothide
# code patch). This exact subject is also the marker used to find/amend it across syncs.
POINTER_COMMIT_SUBJECT="[submodules] fork-sync pointers"

# forked submodule path -> upstream (theos) repo url, used as the rebase target source
sub_upstream_url() {
  case "$1" in
    vendor/include) echo "https://github.com/theos/headers.git" ;;
    vendor/lib)     echo "https://github.com/theos/lib.git" ;;
    *) return 1 ;;
  esac
}
# forked submodule path -> roothide "owner/repo", used to build the push URL
sub_origin_slug() {
  case "$1" in
    vendor/include) echo "roothide/headers" ;;
    vendor/lib)     echo "roothide/lib" ;;
    *) return 1 ;;
  esac
}
# forked submodule path -> short label used for summaries
sub_label() {
  case "$1" in
    vendor/include) echo "headers" ;;
    vendor/lib)     echo "lib" ;;
    *) echo "${1##*/}" ;;
  esac
}

DRY_RUN="${DRY_RUN:-false}"
PAT="${THEOS_SYNC_TOKEN:-}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

sum() { printf '%s\n' "$*" >>"$SUMMARY"; }
log() { printf '>>> %s\n' "$*"; }

# Tiny key/value store keyed by submodule path (bash 3.2 compatible, no assoc arrays).
kv_set() { local ns="$1" key; key="${2//\//_}"; printf -v "kv_${ns}_${key}" '%s' "$3"; }
kv_get() { local ns="$1" key; key="${2//\//_}"; eval "printf '%s' \"\${kv_${ns}_${key}:-}\""; }

# true (exit 0) if path $1 has an unmerged index entry at stage $2
sub_has_stage() { git ls-files -u -- "$1" | awk -v s="$2" '$3==s{f=1} END{exit f?0:1}'; }

bail_conflict() { # $1=label (theos|headers|lib)  $2=detail
  local label="$1" detail="$2"
  log "CONFLICT ($label)"; printf '%s\n' "$detail"
  sum "### ❌ Fork sync: rebase conflict in \`roothide/${label}\`"
  sum ""
  sum '```'
  sum "$detail"
  sum '```'
  sum "Automatic sync stopped; no repository was pushed. Manual rebase required."
  # Exit non-zero -> the Actions run fails -> GitHub emails the maintainer.
  exit 1
}

# --- safety guard: real (pushing) runs only from master -----------------------
# The script always operates on origin/master and force-pushes it, so a real run must
# come from master. A manual workflow_dispatch can be launched from any branch (which
# runs THAT branch's copy of this script) — allow that only in dry-run (handy for
# testing the workflow), and refuse a real push from a non-master ref. Only enforced
# inside Actions (GITHUB_REF is set there); local invocations are unaffected.
if [ -n "${GITHUB_REF:-}" ] && [ "$GITHUB_REF" != "refs/heads/master" ] && [ "$DRY_RUN" != "true" ]; then
  echo "ERROR: refusing a real sync from '$GITHUB_REF' (would force-push master). Run from master, or use dry_run."
  exit 1
fi

# --- identity -----------------------------------------------------------------
# Use --global: the forked submodules are SEPARATE git repos, so a superproject-local
# identity would not reach them, and a clean runner has none — making `git rebase` inside a
# submodule fail with "Committer identity unknown" (or stamp a bogus auto-detected one).
git config --global user.name  "${GITHUB_ACTOR:-roothide-sync}"
git config --global user.email "${GITHUB_ACTOR:-roothide-sync}@users.noreply.github.com"

# --- fetch --------------------------------------------------------------------
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$UPSTREAM_SUPER_URL"
log "fetching superproject remotes"
git fetch --quiet origin
git fetch --quiet upstream

PRE_SUPER=$(git rev-parse origin/master)   # expected remote value for force-with-lease

# Initialise the forked submodules up front (full history, needed to rebase them and to
# stage their gitlinks during the superproject rebase). This also doubles as a consistency
# health-check: `submodule update` checks out the exact gitlink origin/master records, so a
# gitlink that was never pushed to its fork (e.g. the superproject was advanced without
# pushing the submodule) fails here with a clear error instead of being silently reported
# "up to date" below. Non-forked submodules are untouched by our patches, so we skip them.
log "initialising forked submodules (also verifies gitlink consistency)"
if ! git submodule update --init -- "${FORKED_SUBS[@]}"; then
  echo "ERROR: a forked-submodule gitlink recorded in origin/master is not reachable on its fork remote"
  echo "       (the superproject references a submodule commit never pushed to roothide/headers or roothide/lib)."
  sum "### ❌ Fork sync: inconsistent submodule gitlink"
  sum "A forked-submodule commit referenced by \`origin/master\` is missing from its fork remote — manual fix needed."
  exit 1
fi

# --- short-circuit ------------------------------------------------------------
if git merge-base --is-ancestor upstream/master origin/master; then
  log "upstream already contained in origin/master — nothing to do"
  sum "### ✅ Fork sync: already up to date"
  exit 0
fi

MB=$(git merge-base origin/master upstream/master)
log "merge-base=$(git rev-parse --short "$MB")  upstream=$(git rev-parse --short upstream/master)"

# ============================================================================
# 1) Rebase the SUPERPROJECT first (work tree clean: submodules sit at their
#    recorded gitlinks). Auto-resolve ONLY the two forked gitlinks (they are
#    pinned to exact SHAs in step 3); any other unmerged path is a real code
#    conflict -> bail to a human.
#    During rebase: ours = upstream, theirs = roothide patch.
# ============================================================================
log "rebasing superproject ${MB:0:10}..origin/master --onto upstream/master"
git checkout -q -B sync-tmp origin/master

set +e
GIT_EDITOR=true git rebase --empty=drop --onto upstream/master "$MB" sync-tmp
rc=$?
set -e

guard=0
while [ $rc -ne 0 ]; do
  guard=$((guard + 1))
  [ $guard -gt 100 ] && { git rebase --abort || true; bail_conflict theos "superproject rebase did not converge (see run log)"; }

  U="$(git diff --name-only --diff-filter=U || true)"
  if [ -z "$U" ]; then
    # Stopped with no conflicts: almost always a patch that became empty/redundant.
    # --empty=drop handles the usual empty cases WITHOUT stopping, so reaching here is
    # unusual — record which commit we skip so it can never be silently lost.
    skipped=$(git rev-parse --short REBASE_HEAD 2>/dev/null || echo '?')
    log "WARN: superproject rebase stopped with no conflicts; skipping presumed-empty commit $skipped"
    sum "> ⚠️ skipped presumed-empty superproject commit \`$skipped\` during rebase"
    set +e; GIT_EDITOR=true git rebase --skip; rc=$?; set -e
    continue
  fi

  bad=""
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    case "$p" in
      vendor/include|vendor/lib)
        if sub_has_stage "$p" 2; then
          git add -- "$p"               # placeholder value; pinned exactly in step 3
        else
          bad="$bad ${p}(deleted-upstream)"
        fi ;;
      *)
        bad="$bad $p" ;;
    esac
  done <<< "$U"

  if [ -n "$bad" ]; then
    git rebase --abort || true
    bail_conflict theos "$(printf 'real conflict — unmerged paths need manual resolution:%s\n---\n%s' "$bad" "$U")"
  fi

  set +e; GIT_EDITOR=true git rebase --continue; rc=$?; set -e
done
log "superproject rebase done"

# ---- drop any pre-existing pointer commit(s) ----
# They are sync artifacts (regenerated fresh at the tip in step 3). Dropping them here keeps
# exactly ONE pointer commit even if you committed your own work on top of a previous one —
# otherwise the old pointer would sit stranded in the middle and step 3 would add a duplicate.
while :; do
  ptr=""
  # scan ONLY the fork's own commits (upstream/master..) — never upstream's, so an upstream
  # commit that ever shares this subject can't be mistaken for our pointer and dropped.
  for c in $(git rev-list upstream/master..sync-tmp); do
    [ "$(git log -1 --format='%s' "$c")" = "$POINTER_COMMIT_SUBJECT" ] && { ptr="$c"; break; }
  done
  [ -z "$ptr" ] && break
  log "dropping stale pointer commit ${ptr:0:10} (regenerated at the tip below)"
  set +e; GIT_EDITOR=true git rebase --empty=drop --onto "${ptr}^" "$ptr" sync-tmp; rc=$?; set -e
  [ $rc -ne 0 ] && { git rebase --abort 2>/dev/null || true; bail_conflict theos "conflict while dropping stale pointer commit ${ptr:0:10}"; }
done

# ============================================================================
# 2) Rebase each forked submodule onto the upstream gitlink target.
#    old_base/target are read straight from the superproject trees, so this does
#    not depend on the submodule's own branch topology.
# ============================================================================
for sub in "${FORKED_SUBS[@]}"; do
  old=$(git ls-tree "$MB"           "$sub" | awk '{print $3}')
  tgt=$(git ls-tree upstream/master "$sub" | awk '{print $3}')
  kv_set REBASED "$sub" 0

  if [ "$old" = "$tgt" ]; then
    log "$sub: upstream gitlink unchanged (${tgt:0:10}) — skip"
    continue
  fi

  label="$(sub_label "$sub")"
  log "$sub: rebase roothide patches ${old:0:10}..origin/master --onto ${tgt:0:10}"
  git -C "$sub" remote get-url upstream >/dev/null 2>&1 || \
    git -C "$sub" remote add upstream "$(sub_upstream_url "$sub")"
  git -C "$sub" fetch --quiet origin
  git -C "$sub" fetch --quiet upstream
  git -C "$sub" fetch --quiet upstream "$tgt" 2>/dev/null || true
  git -C "$sub" cat-file -e "${tgt}^{commit}" 2>/dev/null || \
    bail_conflict "$label" "target commit $tgt is not fetchable from $(sub_upstream_url "$sub")"

  kv_set SUB_PRE "$sub" "$(git -C "$sub" rev-parse origin/master)"
  git -C "$sub" checkout -q -B sync origin/master

  set +e
  git -C "$sub" rebase --empty=drop --onto "$tgt" "$old" sync
  rc=$?
  set -e
  guard=0
  while [ $rc -ne 0 ]; do
    guard=$((guard + 1))
    [ $guard -gt 100 ] && { git -C "$sub" rebase --abort || true; bail_conflict "$label" "submodule rebase did not converge"; }
    U="$(git -C "$sub" diff --name-only --diff-filter=U || true)"
    if [ -z "$U" ]; then
      skipped=$(git -C "$sub" rev-parse --short REBASE_HEAD 2>/dev/null || echo '?')
      log "WARN: $sub rebase stopped with no conflicts; skipping presumed-empty commit $skipped"
      sum "> ⚠️ skipped presumed-empty commit \`$skipped\` in \`$sub\` during rebase"
      set +e; git -C "$sub" rebase --skip; rc=$?; set -e
      continue
    fi
    # a leaf submodule has no gitlinks -> any unmerged path is a real code conflict
    git -C "$sub" rebase --abort || true
    bail_conflict "$label" "$(printf 'conflict rebasing %s onto %s:\n%s' "$(sub_origin_slug "$sub")" "${tgt:0:10}" "$U")"
  done

  kv_set NEW_TIP "$sub" "$(git -C "$sub" rev-parse HEAD)"
  kv_set REBASED "$sub" 1
  log "$sub: new tip $(git -C "$sub" rev-parse --short HEAD)"
done

# ============================================================================
# 3) Record the forked-submodule gitlinks in ONE dedicated commit at the tip. The value is
#    what each fork's master will hold after this sync: the freshly rebased tip for a rebased
#    submodule, or the fork's current master tip for an unchanged one. Any previous pointer
#    commit was dropped above, so we always create a single fresh one here — which also means
#    we never rewrite upstream's own tip when all roothide patches dropped (HEAD==upstream).
#
#    KNOWN LIMITATION (accepted): only this tip commit is guaranteed to reference reachable
#    submodule commits. Earlier roothide patches that touch a gitlink still record the
#    pre-rebase submodule SHA (unreachable after the fork is force-pushed), so
#    `git checkout <older-sync-commit> && git submodule update` may fail — only relevant for
#    bisecting across a sync. A fresh clone / `submodule update` of master always works.
# ============================================================================
for sub in "${FORKED_SUBS[@]}"; do
  if [ "$(kv_get REBASED "$sub")" = "1" ]; then
    tip="$(kv_get NEW_TIP "$sub")"                   # freshly rebased tip (pushed in step 5)
  else
    git -C "$sub" fetch -q origin 2>/dev/null || log "WARN: could not refresh $(sub_origin_slug "$sub") — pin is re-verified before any push"
    tip="$(git -C "$sub" rev-parse origin/master)"   # fork master unchanged this sync (re-verified at push time)
  fi
  git -C "$sub" cat-file -e "${tip}^{commit}"        # must exist before we point at it
  git update-index --cacheinfo "160000,${tip},$sub"
done
if ! git diff --cached --quiet; then
  git commit -m "$POINTER_COMMIT_SUBJECT" >/dev/null
fi

# ============================================================================
# 4) Empty-result guard. A fresh rebase mints new commit SHAs even for an
#    identical tree, so compare TREES to decide whether anything really changed.
# ============================================================================
if [ "$(git rev-parse 'sync-tmp^{tree}')" = "$(git rev-parse 'origin/master^{tree}')" ]; then
  log "resulting tree identical to origin/master — nothing to push"
  sum "### ✅ Fork sync: no effective change"
  exit 0
fi

# --- summary of the planned change -------------------------------------------
sum "### 🔄 Fork sync"
sum ""
sum "- superproject: $(git rev-list --count upstream/master..sync-tmp) roothide patch(es) rebased onto upstream \`$(git rev-parse --short upstream/master)\` (was \`${PRE_SUPER:0:10}\`)"
for sub in "${FORKED_SUBS[@]}"; do
  if [ "$(kv_get REBASED "$sub")" = "1" ]; then
    tip="$(kv_get NEW_TIP "$sub")"
    sum "- \`$sub\`: roothide patches rebased → \`${tip:0:10}\`"
  else
    sum "- \`$sub\`: upstream gitlink unchanged — left as-is"
  fi
done

# ============================================================================
# 5) Push. Submodules FIRST so the superproject gitlink is reachable, then the
#    superproject. force-with-lease with an explicit expected SHA (captured before
#    any fetch) so a human push in the meantime is not clobbered.
# ============================================================================
if [ "$DRY_RUN" = "true" ]; then
  log "DRY-RUN: skipping all pushes"
  sum ""
  sum "> dry-run — nothing was pushed."
  exit 0
fi

[ -n "$PAT" ] || { echo "THEOS_SYNC_TOKEN is empty — cannot push"; exit 1; }

push_repo() { # $1=dir  $2=owner/repo  $3=local-ref-or-sha  $4=expected-remote-sha
  local dir="$1" slug="$2" ref="$3" expect="$4"
  git -C "$dir" push --force-with-lease="master:${expect}" \
    "https://x-access-token:${PAT}@github.com/${slug}.git" "${ref}:master"
}

# (a) Re-check origin/master hasn't moved since job start. A concurrent push would make our
# superproject force-with-lease fail *after* we'd already rewritten the submodule forks, so
# abort now — before touching anything. Not an error; the next run retries.
git fetch --quiet origin
if [ "$(git rev-parse origin/master)" != "$PRE_SUPER" ]; then
  log "origin/master moved since job start — skipping push this run (will retry)"
  sum "### ⏭️ Fork sync: origin/master changed mid-run — nothing pushed, will retry"
  exit 0
fi

# (a2) Re-verify any UNCHANGED forked submodule's fork master still equals the SHA we pinned.
# We don't push those forks (only rebased ones are pushed+lease-protected below), so if a
# concurrent force-push rewrote one mid-run, our pinned SHA may already be orphaned and
# publishing the superproject would leave it pointing at an unreachable commit (which the next
# run's consistency check couldn't recover from). Nothing is pushed yet -> just skip and retry.
for sub in "${FORKED_SUBS[@]}"; do
  [ "$(kv_get REBASED "$sub")" = "1" ] && continue
  # Must fetch successfully to verify before publishing — a swallowed failure would compare
  # against a stale origin/master and could wave through an already-orphaned pin.
  if ! git -C "$sub" fetch -q origin; then
    log "could not fetch $(sub_origin_slug "$sub") to verify before publishing — skipping (will retry)"
    sum "### ⏭️ Fork sync: could not fetch $(sub_origin_slug "$sub") to verify — nothing pushed, will retry"
    exit 0
  fi
  pinned="$(git ls-tree sync-tmp "$sub" | awk '{print $3}')"
  if [ "$(git -C "$sub" rev-parse origin/master)" != "$pinned" ]; then
    log "$(sub_origin_slug "$sub") master changed mid-run — skipping push this run (will retry)"
    sum "### ⏭️ Fork sync: $(sub_origin_slug "$sub") changed mid-run — nothing pushed, will retry"
    exit 0
  fi
done

# (b) If any push fails after we've already force-pushed a submodule fork, roll those forks
# back to their pre-run tips. Otherwise roothide/theos would keep referencing a submodule
# commit we just orphaned — a state the next run's consistency check cannot recover from.
# Lease-guarded (master:newtip) so a concurrent writer is never clobbered.
PUSHED=()
rollback_submodules() {
  [ "${#PUSHED[@]}" -eq 0 ] && return 0
  local sub newtip oldtip
  for sub in "${PUSHED[@]}"; do
    newtip="$(kv_get NEW_TIP "$sub")"; oldtip="$(kv_get SUB_PRE "$sub")"
    if git -C "$sub" push --force-with-lease="master:${newtip}" \
         "https://x-access-token:${PAT}@github.com/$(sub_origin_slug "$sub").git" "${oldtip}:master"; then
      echo "  rolled back $(sub_origin_slug "$sub") -> ${oldtip:0:10}"
    else
      echo "  WARNING: rollback of $(sub_origin_slug "$sub") failed — check it manually"
    fi
  done
}

# push submodules first (so the superproject gitlink is reachable once we push it)
for sub in "${FORKED_SUBS[@]}"; do
  [ "$(kv_get REBASED "$sub")" = "1" ] || continue
  log "pushing $(sub_origin_slug "$sub")"
  if ! push_repo "$sub" "$(sub_origin_slug "$sub")" sync "$(kv_get SUB_PRE "$sub")"; then
    echo "ERROR: push to $(sub_origin_slug "$sub") failed; rolling back"
    rollback_submodules
    sum "### ❌ Fork sync: submodule push failed — rolled back, will retry next run"
    exit 1
  fi
  PUSHED+=("$sub")
done

# then the superproject; if it fails, undo the submodule pushes to keep all repos consistent
log "pushing roothide/theos"
if ! push_repo "." "roothide/theos" sync-tmp "$PRE_SUPER"; then
  echo "ERROR: superproject push failed after submodule push(es); rolling back submodule fork(s)"
  rollback_submodules
  sum "### ❌ Fork sync: superproject push failed — submodule fork(s) rolled back, will retry next run"
  sum "If a rollback WARNING appears in the log, check roothide/headers & roothide/lib manually."
  exit 1
fi

sum ""
sum "> ✅ pushed."
