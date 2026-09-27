#!/usr/bin/env bash
# Drive this Logos module catalog's GitHub Actions workflows from the
# terminal — the gh-CLI alternative to opening the repo's Actions tab
# and clicking "Run workflow".
#
# Works in this repo AND in any fork: the target is the repo the clone's
# 'origin' remote points at — resolved here and pinned on every `gh`
# call, never left to `gh` to work out for itself. (`gh` resolves against
# *all* of a clone's remotes: with the usual fork layout — origin = your
# fork, upstream = the base repo — it can land on upstream, and an
# `unpublish` dispatched there deletes releases from someone else's
# catalog.) Every run prints the repo it targets before it does anything.
#
# Usage:
#   ./scripts/catalog.sh <command> [args] [--watch]
#
# Commands:
#   release [<module>] [--force]
#                         Trigger release-<module>.yml. With no <module>,
#                         list the modules this catalog publishes.
#   release-all [--force] Trigger release-all.yml (re)release every module.
#   rebuild-index         Trigger rebuild-index.yml (regenerate index.json).
#   unpublish <module> [<version>] [--dry-run] [--keep-tags]
#                         Trigger unpublish.yml. Removes a module from the
#                         catalog — every version, or just <version> if
#                         given. DESTRUCTIVE: deletes for real by default;
#                         pass --dry-run first to preview the matches.
#   status                Show recent workflow runs for this repo.
#   watch [<run-id>]      Follow a run to completion (latest run if no id).
#
#   --watch  on release / release-all / rebuild-index / unpublish: follow
#            the run that was just triggered through to completion.
#   --force  on release / release-all: Force build — replace the current
#            published release if it has the same version (otherwise an
#            already-published version is skipped).
#
# Environment:
#   GH_REPO  Drive this repo instead of the one 'origin' points at, as
#            [HOST/]OWNER/REPO.
#
# Examples:
#   ./scripts/catalog.sh release logos-chat-module
#   ./scripts/catalog.sh release logos-chat-module --force
#   ./scripts/catalog.sh release-all --watch
#   ./scripts/catalog.sh rebuild-index
#   ./scripts/catalog.sh unpublish logos-chat-module --dry-run
#   ./scripts/catalog.sh unpublish logos-chat-module 1.2.3
#   ./scripts/catalog.sh status

set -euo pipefail

# Resolve our own absolute path BEFORE cd'ing away — print_usage seds
# this file, and a relative $0 wouldn't resolve from the repo root.
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

cd "$(git rev-parse --show-toplevel)"

WORKFLOW_DIR=".github/workflows"

die() { echo "error: $*" >&2; exit 1; }

print_usage() {
  # Echo the comment header (lines 2..first blank), stripping the `# `
  # prefix. Two plain substitutions — `\|` alternation isn't portable
  # to the BSD sed macOS ships. Reads SCRIPT_PATH (absolute) rather
  # than $0, which would be relative to the pre-cd directory.
  sed -n '2,/^$/p' "$SCRIPT_PATH" | sed -e 's/^# //' -e 's/^#$//'
}

# ── flag + positional split ──────────────────────────────────────────
# Flags may appear anywhere; everything else is a positional arg.
WATCH=0
DRY_RUN=0
KEEP_TAGS=0
FORCE=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --watch)      WATCH=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    --keep-tags)  KEEP_TAGS=1 ;;
    --force)      FORCE=1 ;;
    -h|--help)    print_usage; exit 0 ;;
    -*)           die "unknown flag: $a (see --help)" ;;
    *)            ARGS+=("$a") ;;
  esac
done

if [ "${#ARGS[@]}" -eq 0 ]; then
  print_usage
  exit 2
fi
CMD="${ARGS[0]}"

# ── preflight ─────────────────────────────────────────────────────────
command -v gh >/dev/null 2>&1 \
  || die "the GitHub CLI ('gh') is not installed — see https://cli.github.com"
gh auth status >/dev/null 2>&1 \
  || die "not logged in to GitHub — run 'gh auth login' first"
[ -f "${WORKFLOW_DIR}/_release-module.yml" ] \
  || die "not a Logos catalog repo (no ${WORKFLOW_DIR}/_release-module.yml) — run from a clone of logos-modules-release-base or a fork"

# ── target repo ───────────────────────────────────────────────────────
# Never let `gh` choose the repo. It resolves against every remote in the
# clone, so a fork that also has an 'upstream' remote can have its
# dispatches — `unpublish`'s deletions included — sent to the base repo.
# We read 'origin' ourselves and pass the result to each `gh` call as
# --repo. GH_REPO is exported too: it doubles as the user's override, and
# means a `gh` call added here later can't fall back to guessing.

# Set REPO from a remote's URL, in the shapes git accepts:
#   https://github.com/owner/repo[.git]        (optionally user[:pass]@)
#   ssh://git@github.com[:22]/owner/repo[.git]
#   git@github.com:owner/repo[.git]
# A non-github.com host is kept as a prefix — that's gh's own
# [HOST/]OWNER/REPO form, so Enterprise clones resolve too.
resolve_repo_from_remote() {
  # host/path start empty: bash 4.4+ treats a bare `local x` as unset, and
  # `set -u` would abort on it before the unparseable-URL die() below.
  local remote="$1" url rest owner name host="" path=""
  url="$(git remote get-url "$remote" 2>/dev/null || true)"
  [ -n "$url" ] \
    || die "this clone has no '${remote}' remote, so there's no catalog to target — add one, or set GH_REPO=<owner>/<repo>"

  case "$url" in
    *://*) rest="${url#*://}"; rest="${rest#*@}"   # drop scheme, then userinfo
           host="${rest%%/*}"; path="${rest#*/}" ;;
    *:*)   rest="${url#*@}"                        # scp-like: [user@]host:path
           host="${rest%%:*}"; path="${rest#*:}" ;;
    *)     path="" ;;                              # local path or something odd
  esac
  host="${host%%:*}"                               # drop any :port
  path="${path#/}"; path="${path%/}"; path="${path%.git}"; path="${path%/}"

  owner=""; name=""
  case "$path" in
    */*/*) : ;;                                    # deeper than owner/repo
    */*)   owner="${path%%/*}"; name="${path#*/}" ;;
  esac
  [ -n "$host" ] && [ -n "$owner" ] && [ -n "$name" ] \
    || die "can't read an owner/repo out of the '${remote}' URL (${url}) — set GH_REPO=<owner>/<repo> to name the catalog to drive"

  case "$host" in
    github.com|www.github.com) REPO="${owner}/${name}" ;;
    *)                         REPO="${host}/${owner}/${name}" ;;
  esac
}

if [ -n "${GH_REPO:-}" ]; then
  REPO="$GH_REPO"
  REPO_SOURCE="\$GH_REPO"
else
  resolve_repo_from_remote origin
  REPO_SOURCE="git remote 'origin'"
fi
export GH_REPO="$REPO"

echo "==> catalog repo: ${REPO}  (from ${REPO_SOURCE})"

# ── helpers ───────────────────────────────────────────────────────────

# Module names with a per-module release workflow: release-<module>.yml,
# excluding the umbrella release-all.yml and the .template.
list_modules() {
  local f name
  for f in "${WORKFLOW_DIR}"/release-*.yml; do
    [ -e "$f" ] || continue          # nullglob-safe: no matches -> skip
    name="$(basename "$f")"
    name="${name#release-}"
    name="${name%.yml}"
    [ "$name" = "all" ] && continue
    echo "$name"
  done
}

# Newest run id for a workflow file, or empty if none yet.
latest_run_id() {
  gh run list --repo "$REPO" --workflow "$1" --limit 1 \
     --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true
}

# Poll until a run newer than $2 appears for workflow $1, then watch it.
# `gh workflow run` returns no run id, so we diff against the pre-trigger
# newest. Returns non-zero if the run never registers within the window
# — the trigger itself still succeeded, but a caller that asked for
# --watch (e.g. from automation) must be able to tell watching failed.
follow_new_run() {
  local wf="$1" before="$2" id="" tries=0
  echo "==> waiting for the run to register…"
  while [ "$tries" -lt 20 ]; do
    sleep 2
    id="$(latest_run_id "$wf")"
    if [ -n "$id" ] && [ "$id" != "$before" ]; then
      gh run watch --repo "$REPO" "$id"
      return 0
    fi
    tries=$((tries + 1))
  done
  echo "    workflow was triggered, but couldn't resolve the new run to" >&2
  echo "    watch — check it with './scripts/catalog.sh status'." >&2
  return 1
}

# Trigger a workflow file; optionally follow the run it created.
# Extra args after the workflow name pass straight to `gh workflow run`
# (used for unpublish's -f inputs).
run_workflow() {
  local wf="$1"; shift
  local before=""
  [ "$WATCH" = "1" ] && before="$(latest_run_id "$wf")"

  echo "==> triggering ${wf} on ${REPO}"
  gh workflow run --repo "$REPO" "$wf" "$@"

  if [ "$WATCH" = "1" ]; then
    follow_new_run "$wf" "$before"
  else
    echo "    queued. Track it:  ./scripts/catalog.sh status   (or re-run with --watch)"
  fi
}

# ── commands ──────────────────────────────────────────────────────────
case "$CMD" in
  release)
    MODULE="${ARGS[1]:-}"
    if [ -z "$MODULE" ]; then
      echo "Modules in this catalog (pass one to 'release'):"
      mods="$(list_modules)"
      if [ -z "$mods" ]; then
        echo "  (none — add one with ./scripts/add-module.sh)"
      else
        echo "$mods" | sed 's/^/  /'
      fi
      exit 0
    fi
    WF="release-${MODULE}.yml"
    if [ ! -f "${WORKFLOW_DIR}/${WF}" ]; then
      echo "error: no release workflow for '${MODULE}'." >&2
      echo "known modules:" >&2
      list_modules | sed 's/^/  /' >&2
      exit 1
    fi
    if [ "$FORCE" = "1" ]; then
      run_workflow "$WF" -f "force_build=true"
    else
      run_workflow "$WF"
    fi
    ;;

  release-all)
    if [ "$FORCE" = "1" ]; then
      run_workflow "release-all.yml" -f "force_build=true"
    else
      run_workflow "release-all.yml"
    fi
    ;;

  rebuild-index)
    run_workflow "rebuild-index.yml"
    ;;

  unpublish)
    MODULE="${ARGS[1]:-}"
    VERSION="${ARGS[2]:-}"
    [ -n "$MODULE" ] || die "unpublish needs a module name (the <name> in <name>-v<version> release tags)"

    # Mirror the workflow input defaults: delete for real, drop tags too.
    DELETE_TAGS="true"
    [ "$KEEP_TAGS" = "1" ] && DELETE_TAGS="false"
    DRY="false"
    [ "$DRY_RUN" = "1" ] && DRY="true"

    if [ "$DRY" = "true" ]; then
      echo "==> dry run on ${REPO} — nothing will be deleted"
    else
      target="all versions of '${MODULE}'"
      [ -n "$VERSION" ] && target="'${MODULE}' v${VERSION}"
      echo "!!  this will DELETE ${target} from ${REPO} (irreversible)."
      # Confirm only at an interactive terminal — a fat-finger guard.
      # Piped / CI use proceeds straight through, matching how the
      # workflow itself runs (no confirmation step).
      if [ -t 0 ]; then
        printf '    continue? [y/N] '
        read -r reply
        case "$reply" in
          y|Y|yes|YES) ;;
          *) echo "    aborted."; exit 0 ;;
        esac
      fi
    fi

    run_workflow "unpublish.yml" \
      -f "module=${MODULE}" \
      -f "version=${VERSION}" \
      -f "delete_tags=${DELETE_TAGS}" \
      -f "dry_run=${DRY}"
    ;;

  status)
    echo "==> recent workflow runs"
    gh run list --repo "$REPO" --limit 15
    ;;

  watch)
    RUN_ID="${ARGS[1]:-}"
    if [ -z "$RUN_ID" ]; then
      RUN_ID="$(gh run list --repo "$REPO" --limit 1 --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true)"
      [ -n "$RUN_ID" ] || die "no runs found to watch"
    fi
    gh run watch --repo "$REPO" "$RUN_ID"
    ;;

  *)
    die "unknown command: ${CMD} (see --help)"
    ;;
esac
