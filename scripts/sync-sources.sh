#!/bin/bash
#
# sync-sources.sh - Sync external repositories for learning
#
# Usage:
#   ./scripts/sync-sources.sh              # Sync all repositories
#   ./scripts/sync-sources.sh pydantic-ai  # Sync specific repository
#   ./scripts/sync-sources.sh --status     # Show sync status
#   ./scripts/sync-sources.sh --clean      # Remove all cloned repos
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SOURCES_FILE="$ROOT_DIR/sources.json"
SOURCES_DIR="$ROOT_DIR/sources"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check dependencies
check_deps() {
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}Error: jq is required but not installed.${NC}"
        echo "Install with: brew install jq (macOS) or apt install jq (Linux)"
        exit 1
    fi
}

# Get current commit hash of a directory
get_commit_hash() {
    local dir="$1"
    if [ -d "$dir/.git" ]; then
        cd "$dir" && git rev-parse HEAD 2>/dev/null || echo "unknown"
    else
        echo "not_cloned"
    fi
}

# Sync a single repository
sync_repo() {
    local category="$1"
    local name="$2"
    local url="$3"
    local branch="$4"
    local depth="${5:-1}"

    local target_dir="$SOURCES_DIR/$category/$name"

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Syncing: $name${NC}"
    echo -e "  Category: $category"
    echo -e "  URL: $url"
    echo -e "  Branch: $branch"
    echo -e "  Depth: $depth"
    echo ""

    if [ -d "$target_dir" ]; then
        echo -e "${YELLOW}Repository exists, updating...${NC}"
        cd "$target_dir"

        # Fetch and reset to latest
        git fetch origin "$branch" --depth="$depth" 2>/dev/null || {
            echo -e "${RED}Failed to fetch. Trying fresh clone...${NC}"
            rm -rf "$target_dir"
            sync_repo "$category" "$name" "$url" "$branch" "$depth"
            return
        }

        git reset --hard "origin/$branch" 2>/dev/null || {
            echo -e "${RED}Failed to reset. Trying fresh clone...${NC}"
            cd "$ROOT_DIR"
            rm -rf "$target_dir"
            sync_repo "$category" "$name" "$url" "$branch" "$depth"
            return
        }

        echo -e "${GREEN}✓ Updated successfully${NC}"
    else
        echo -e "${YELLOW}Cloning new repository...${NC}"
        mkdir -p "$(dirname "$target_dir")"

        git clone --branch "$branch" --depth "$depth" "$url" "$target_dir" 2>&1 || {
            echo -e "${RED}✗ Failed to clone $name${NC}"
            return 1
        }

        echo -e "${GREEN}✓ Cloned successfully${NC}"
    fi

    # Update commit hash in sources.json
    local commit_hash
    commit_hash=$(get_commit_hash "$target_dir")

    # Use temp file for jq update to avoid issues
    local temp_file
    temp_file=$(mktemp)
    jq --arg category "$category" \
       --arg name "$name" \
       --arg commit "$commit_hash" \
       '.sources[$category] = [.sources[$category][] | if .name == $name then .commit = $commit else . end]' \
       "$SOURCES_FILE" > "$temp_file" && mv "$temp_file" "$SOURCES_FILE"

    cd "$ROOT_DIR"
}

# Show status of all repositories
show_status() {
    echo -e "${BLUE}Repository Sync Status${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    local categories
    categories=$(jq -r '.sources | keys[]' "$SOURCES_FILE")

    for category in $categories; do
        local count
        count=$(jq -r ".sources[\"$category\"] | length" "$SOURCES_FILE")

        if [ "$count" -eq 0 ]; then
            continue
        fi

        echo -e "${YELLOW}[$category]${NC}"

        jq -r ".sources[\"$category\"][] | \"\(.name)|\(.url)|\(.branch)|\(.commit // \"not_synced\")\"" "$SOURCES_FILE" | while IFS='|' read -r name url branch commit; do
            local target_dir="$SOURCES_DIR/$category/$name"
            local status
            local status_color

            if [ -d "$target_dir/.git" ]; then
                status="✓ synced"
                status_color="$GREEN"
            else
                status="○ not cloned"
                status_color="$YELLOW"
            fi

            echo -e "  $name"
            echo -e "    Status: ${status_color}${status}${NC}"
            echo -e "    Branch: $branch"
            if [ "$commit" != "null" ] && [ -n "$commit" ] && [ "$commit" != "not_synced" ]; then
                echo -e "    Commit: ${commit:0:8}"
            fi
            echo ""
        done
    done
}

# Clean all cloned repositories
clean_all() {
    echo -e "${YELLOW}Removing all cloned repositories...${NC}"
    rm -rf "$SOURCES_DIR"/*
    echo -e "${GREEN}✓ Cleaned${NC}"

    # Reset commit hashes in sources.json
    local temp_file
    temp_file=$(mktemp)
    jq '.sources = (.sources | map_values(map(.commit = null))) | .lastSync = null' "$SOURCES_FILE" > "$temp_file" && mv "$temp_file" "$SOURCES_FILE"
}

# Sync all repositories
sync_all() {
    local categories
    categories=$(jq -r '.sources | keys[]' "$SOURCES_FILE")

    local total=0
    local success=0
    local failed=0

    for category in $categories; do
        local repos
        repos=$(jq -r ".sources[\"$category\"][] | @base64" "$SOURCES_FILE")

        for repo in $repos; do
            local name url branch depth
            name=$(echo "$repo" | base64 -d | jq -r '.name')
            url=$(echo "$repo" | base64 -d | jq -r '.url')
            branch=$(echo "$repo" | base64 -d | jq -r '.branch')
            depth=$(echo "$repo" | base64 -d | jq -r '.depth // 1')

            ((total++))

            if sync_repo "$category" "$name" "$url" "$branch" "$depth"; then
                ((success++))
            else
                ((failed++))
            fi
            echo ""
        done
    done

    # Update lastSync timestamp
    local temp_file
    temp_file=$(mktemp)
    jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '.lastSync = $ts' "$SOURCES_FILE" > "$temp_file" && mv "$temp_file" "$SOURCES_FILE"

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Sync Complete${NC}"
    echo -e "  Total: $total"
    echo -e "  ${GREEN}Success: $success${NC}"
    if [ "$failed" -gt 0 ]; then
        echo -e "  ${RED}Failed: $failed${NC}"
    fi
}

# Sync specific repository
sync_specific() {
    local target_name="$1"
    local found=0

    local categories
    categories=$(jq -r '.sources | keys[]' "$SOURCES_FILE")

    for category in $categories; do
        local repo
        repo=$(jq -r ".sources[\"$category\"][] | select(.name == \"$target_name\") | @base64" "$SOURCES_FILE")

        if [ -n "$repo" ]; then
            found=1
            local name url branch depth
            name=$(echo "$repo" | base64 -d | jq -r '.name')
            url=$(echo "$repo" | base64 -d | jq -r '.url')
            branch=$(echo "$repo" | base64 -d | jq -r '.branch')
            depth=$(echo "$repo" | base64 -d | jq -r '.depth // 1')

            sync_repo "$category" "$name" "$url" "$branch" "$depth"
            break
        fi
    done

    if [ "$found" -eq 0 ]; then
        echo -e "${RED}Error: Repository '$target_name' not found in sources.json${NC}"
        exit 1
    fi
}

# Main
check_deps

case "${1:-}" in
    --status|-s)
        show_status
        ;;
    --clean|-c)
        clean_all
        ;;
    --help|-h)
        echo "Usage: $0 [OPTIONS] [REPOSITORY_NAME]"
        echo ""
        echo "Options:"
        echo "  --status, -s    Show sync status of all repositories"
        echo "  --clean, -c     Remove all cloned repositories"
        echo "  --help, -h      Show this help message"
        echo ""
        echo "Examples:"
        echo "  $0                    # Sync all repositories"
        echo "  $0 pydantic-ai        # Sync specific repository"
        echo "  $0 --status           # Show status"
        ;;
    "")
        sync_all
        ;;
    *)
        sync_specific "$1"
        ;;
esac
