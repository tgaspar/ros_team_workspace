#!/bin/bash
# Copyright (c) 2026, ROS-Team-Workspace
# Setup script for Claude Code configuration in ROS 2 workspaces.
#
# Usage:
#   bash setup-claude-config.bash [OPTIONS]
#
# Options:
#   --path PATH        Target directory for .claude/ (used as-is, no src/ appended)
#   --force            Overwrite files even if locally modified
#   --dry-run          Show what would be done without making changes
#   --help             Show this help message

set -euo pipefail

# --- Colors (inline, no dependency on terminal_coloring.bash) ---
readonly NC='\e[0m'
readonly RED='\e[0;31m'
readonly GREEN='\e[0;32m'
readonly YELLOW='\e[1;33m'
readonly CYAN='\e[0;36m'
readonly BOLD='\e[1m'

# --- Globals ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
FORCE=false
DRY_RUN=false
EXPLICIT_PATH=""  # Set via --path flag
TARGET_DIR=""     # Final destination for .claude/
MANIFEST_FILE=".rtw-manifest"

# Files managed by this script (relative to templates/claude-code/)
MANAGED_FILES=(
  "CLAUDE.md"
  "agents/cpp_reviewer.md"
  "agents/pull-request-drafter.md"
  "agents/python-reviewer.md"
  "rules/cpp-rules.md"
  "rules/python-rules.md"
)

# --- Helpers ---

print_info() {
  echo -e "${CYAN}[RTW-Claude]${NC} $1"
}

print_success() {
  echo -e "${GREEN}[RTW-Claude]${NC} $1"
}

print_warn() {
  echo -e "${YELLOW}[RTW-Claude]${NC} $1"
}

print_error() {
  echo -e "${RED}[RTW-Claude]${NC} $1" >&2
}

print_dry() {
  echo -e "${BOLD}[DRY-RUN]${NC} $1"
}

usage() {
  sed -n '2,/^[^#]/{ /^#/s/^# \?//p }' "${BASH_SOURCE[0]}"
  exit 0
}

# --- Version & Checksum ---

# Extract version from RTW-Claude-Config header comment.
# Returns empty string if no header found.
parse_rtw_version() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo ""
    return
  fi
  # Match: <!-- RTW-Claude-Config | file: ... | version: X.Y.Z -->
  local header
  header=$(head -n 1 "$file")
  if [[ "$header" =~ version:\ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

# Compute sha256 checksum of a file (portable: sha256sum or shasum).
file_checksum() {
  local file="$1"
  if command -v sha256sum &>/dev/null; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum &>/dev/null; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    print_error "Neither sha256sum nor shasum found."
    exit 1
  fi
}

# --- Manifest ---

# Read a value from the manifest for a given file key.
# Usage: manifest_get <manifest_path> <file_key> <field>
# Fields: checksum, version, deployed_at
manifest_get() {
  local manifest="$1" key="$2" field="$3"
  if [[ ! -f "$manifest" ]]; then
    echo ""
    return
  fi
  # Manifest is a simple key-value file:
  #   <relative_path> <checksum> <version> <deployed_at>
  awk -v k="$key" -v f="$field" '
    $1 == k {
      if (f == "checksum")    print $2
      if (f == "version")     print $3
      if (f == "deployed_at") print $4
    }
  ' "$manifest"
}

# Write/update a manifest entry.
manifest_set() {
  local manifest="$1" key="$2" checksum="$3" version="$4" deployed_at="$5"
  local tmpfile
  tmpfile=$(mktemp)
  if [[ -f "$manifest" ]]; then
    # Remove old entry for this key
    grep -v "^${key} " "$manifest" > "$tmpfile" || true
  fi
  echo "${key} ${checksum} ${version} ${deployed_at}" >> "$tmpfile"
  # Sort for stable output
  sort "$tmpfile" -o "$manifest"
  rm -f "$tmpfile"
}

# --- Semver comparison ---
# Returns: 0 if equal, 1 if a > b, 2 if a < b
semver_compare() {
  local a="$1" b="$2"
  if [[ "$a" == "$b" ]]; then
    return 0
  fi
  local IFS='.'
  read -ra A <<< "$a"
  read -ra B <<< "$b"
  for i in 0 1 2; do
    if (( ${A[$i]:-0} > ${B[$i]:-0} )); then
      return 1
    elif (( ${A[$i]:-0} < ${B[$i]:-0} )); then
      return 2
    fi
  done
  return 0
}

# --- Sync Logic ---

# Determine the action needed for a single file.
# Prints one of: install, update, conflict, skip, up-to-date
determine_action() {
  local src="$1" dest="$2" manifest="$3" rel_path="$4"

  local src_version src_checksum
  src_version=$(parse_rtw_version "$src")
  src_checksum=$(file_checksum "$src")

  # Case 1: destination doesn't exist -> install
  if [[ ! -f "$dest" ]]; then
    echo "install"
    return
  fi

  local dest_checksum
  dest_checksum=$(file_checksum "$dest")

  # Case 2: destination is identical to source -> up-to-date
  if [[ "$src_checksum" == "$dest_checksum" ]]; then
    echo "up-to-date"
    return
  fi

  # Case 3: check manifest for three-way comparison
  local manifest_checksum manifest_version
  manifest_checksum=$(manifest_get "$manifest" "$rel_path" "checksum")
  manifest_version=$(manifest_get "$manifest" "$rel_path" "version")

  # No manifest entry (file exists but wasn't deployed by us)
  if [[ -z "$manifest_checksum" ]]; then
    # Check if destination has an RTW header -> was deployed by an older version of this script
    local dest_version
    dest_version=$(parse_rtw_version "$dest")
    if [[ -n "$dest_version" ]]; then
      # Has RTW header, treat as managed - compare versions
      if semver_compare "$src_version" "$dest_version"; then
        echo "up-to-date"
      else
        local cmp_result=$?
        if [[ $cmp_result -eq 1 ]]; then
          echo "update"
        else
          echo "up-to-date"
        fi
      fi
    else
      # No header, no manifest -> user's own file, conflict
      echo "conflict"
    fi
    return
  fi

  # Manifest entry exists: three-way check
  local user_modified=false upstream_changed=false

  # Did the user modify the deployed file?
  if [[ "$dest_checksum" != "$manifest_checksum" ]]; then
    user_modified=true
  fi

  # Did upstream (template) change since last deploy?
  if [[ "$src_checksum" != "$manifest_checksum" ]]; then
    upstream_changed=true
  fi

  if [[ "$upstream_changed" == false ]]; then
    # Template hasn't changed; user may have edited, but nothing to push
    echo "up-to-date"
  elif [[ "$user_modified" == false ]]; then
    # Template changed, user didn't touch it -> safe to update
    echo "update"
  else
    # Both changed -> conflict
    echo "conflict"
  fi
}

# Sync a single file from template to workspace.
sync_file() {
  local rel_path="$1"
  local src="${SCRIPT_DIR}/${rel_path}"
  local dest="${TARGET_DIR}/.claude/${rel_path}"
  local manifest="${TARGET_DIR}/.claude/${MANIFEST_FILE}"
  local backup_dir="${TARGET_DIR}/.claude/.rtw-backup"

  if [[ ! -f "$src" ]]; then
    print_error "Template file not found: ${src}"
    return 1
  fi

  local action
  action=$(determine_action "$src" "$dest" "$manifest" "$rel_path")

  local src_version src_checksum
  src_version=$(parse_rtw_version "$src")
  src_checksum=$(file_checksum "$src")

  case "$action" in
    up-to-date)
      print_info "  ${rel_path} — up-to-date"
      # Ensure manifest is current even if file was manually placed
      if [[ "$DRY_RUN" == false ]]; then
        manifest_set "$manifest" "$rel_path" "$src_checksum" "$src_version" "$(date -I)"
      fi
      ;;

    install)
      if [[ "$DRY_RUN" == true ]]; then
        print_dry "  Would install: ${rel_path} (v${src_version})"
      else
        mkdir -p "$(dirname "$dest")"
        cp "$src" "$dest"
        manifest_set "$manifest" "$rel_path" "$src_checksum" "$src_version" "$(date -I)"
        print_success "  Installed: ${rel_path} (v${src_version})"
      fi
      ;;

    update)
      if [[ "$DRY_RUN" == true ]]; then
        local old_version
        old_version=$(parse_rtw_version "$dest")
        print_dry "  Would update: ${rel_path} (v${old_version:-?} -> v${src_version})"
      else
        # Backup old file
        mkdir -p "$backup_dir"
        local timestamp
        timestamp=$(date +%Y%m%d-%H%M%S)
        cp "$dest" "${backup_dir}/${rel_path//\//_}.${timestamp}.bak"
        # Overwrite
        cp "$src" "$dest"
        manifest_set "$manifest" "$rel_path" "$src_checksum" "$src_version" "$(date -I)"
        local old_version
        old_version=$(parse_rtw_version "${backup_dir}/${rel_path//\//_}.${timestamp}.bak")
        print_success "  Updated: ${rel_path} (v${old_version:-?} -> v${src_version}) [backup saved]"
      fi
      ;;

    conflict)
      if [[ "$FORCE" == true ]]; then
        if [[ "$DRY_RUN" == true ]]; then
          print_dry "  Would force-overwrite: ${rel_path}"
        else
          mkdir -p "$backup_dir"
          local timestamp
          timestamp=$(date +%Y%m%d-%H%M%S)
          cp "$dest" "${backup_dir}/${rel_path//\//_}.${timestamp}.bak"
          cp "$src" "$dest"
          manifest_set "$manifest" "$rel_path" "$src_checksum" "$src_version" "$(date -I)"
          print_warn "  Force-updated: ${rel_path} (v${src_version}) [backup saved]"
        fi
      else
        if [[ "$DRY_RUN" == true ]]; then
          print_dry "  Would SKIP (conflict): ${rel_path} — locally modified, use --force to overwrite"
        else
          print_warn "  SKIPPED: ${rel_path} — locally modified, use --force to overwrite"
        fi
      fi
      ;;

    *)
      print_error "  Unknown action '${action}' for ${rel_path}"
      return 1
      ;;
  esac
}

# --- Target resolution ---

resolve_target() {
  # Case 1: Explicit --path flag -> use as-is
  if [[ -n "$EXPLICIT_PATH" ]]; then
    if [[ ! -d "$EXPLICIT_PATH" ]]; then
      print_error "Path does not exist: ${EXPLICIT_PATH}"
      exit 1
    fi
    TARGET_DIR="$EXPLICIT_PATH"
    return
  fi

  # Case 2: RTW workspace environment -> deploy to <workspace>/src/
  if [[ -z "${RosTeamWS_WS_NAME:-}" ]]; then
    print_error "No target specified."
    print_error "Either activate a workspace (via 'rtw ws ...') or pass --path PATH."
    exit 1
  fi

  if [[ -z "${RosTeamWS_WS_FOLDER:-}" ]]; then
    print_error "RosTeamWS_WS_NAME is set but RosTeamWS_WS_FOLDER is not."
    print_error "Make sure your workspace is properly configured or pass --path PATH."
    exit 1
  fi

  if [[ ! -d "$RosTeamWS_WS_FOLDER" ]]; then
    print_error "RosTeamWS_WS_FOLDER points to non-existent directory: ${RosTeamWS_WS_FOLDER}"
    exit 1
  fi

  TARGET_DIR="${RosTeamWS_WS_FOLDER}/src"
}

# --- Main ---

main() {
  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --path)
        EXPLICIT_PATH="$2"
        shift 2
        ;;
      --force)
        FORCE=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --help|-h)
        usage
        ;;
      *)
        print_error "Unknown option: $1"
        usage
        ;;
    esac
  done

  resolve_target

  if [[ ! -d "$TARGET_DIR" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      print_dry "Would create directory: ${TARGET_DIR}"
    else
      mkdir -p "$TARGET_DIR"
      print_success "Created: ${TARGET_DIR}"
    fi
  fi

  local claude_dir="${TARGET_DIR}/.claude"

  print_info "Syncing Claude Code configuration to: ${TARGET_DIR}"
  if [[ "$DRY_RUN" == true ]]; then
    print_info "Mode: dry-run (no changes will be made)"
  fi
  if [[ "$FORCE" == true ]]; then
    print_warn "Mode: force (local modifications will be overwritten)"
  fi
  echo ""

  # Create .claude directory if needed
  if [[ ! -d "$claude_dir" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      print_dry "Would create directory: ${claude_dir}"
    else
      mkdir -p "$claude_dir"
      print_success "Created: ${claude_dir}"
    fi
  fi

  # Sync each managed file
  for rel_path in "${MANAGED_FILES[@]}"; do
    sync_file "$rel_path"
  done

  echo ""
  if [[ "$DRY_RUN" == true ]]; then
    print_info "Dry-run complete. No files were modified."
  else
    print_success "Sync complete."
    print_info "Manifest: ${claude_dir}/${MANIFEST_FILE}"
    print_info "Backups:  ${claude_dir}/.rtw-backup/ (if any)"
  fi
}

main "$@"
