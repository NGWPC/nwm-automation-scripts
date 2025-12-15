#!/bin/bash

# Array of repository URLs
repos=(
    "https://github.com/NGWPC/ngencerf-server"
    "https://github.com/NGWPC/ngen"
    "https://github.com/NGWPC/ngen-forcing"
    "https://github.com/NGWPC/nwm-cal-mgr"
    "https://github.com/NGWPC/nwm-fcst-mgr"
)

# GitHub Personal Access Token (optional but recommended)
# Set this as an environment variable: export GITHUB_TOKEN="your_token_here"
if [ -z "$GITHUB_TOKEN" ]; then
    echo "Note: GITHUB_TOKEN not set. Using anonymous API access (rate limited)."
    echo "To set token: export GITHUB_TOKEN='your_token_here'"
    echo ""
    AUTH_HEADER=""
else
    AUTH_HEADER="Authorization: token $GITHUB_TOKEN"
fi

echo "╔════════════════════════════════════════════════════════════════════════════╗"
echo "║                    NGWPC Repository Status Report                          ║"
echo "╚════════════════════════════════════════════════════════════════════════════╝"
echo ""

for repo_url in "${repos[@]}"; do
    repo_name=$(basename "$repo_url")
    repo_path=$(echo "$repo_url" | sed 's/https:\/\/github.com\///')
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📦 Repository: $repo_name"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Get latest commit on HEAD
    latest_commit=$(git ls-remote "$repo_url" HEAD 2>/dev/null | awk '{print substr($1,1,7)}')
    
    if [ -n "$latest_commit" ]; then
        echo "🔹 Latest commit (HEAD):    $latest_commit"
        
        # Get commit date by doing a shallow clone
        temp_dir=$(mktemp -d)
        if git clone --depth 1 "$repo_url" "$temp_dir" &>/dev/null; then
            cd "$temp_dir" || exit
            commit_date=$(git log -1 --format="%cd" --date=format:"%Y-%m-%d %H:%M:%S")
            commit_timestamp=$(git log -1 --format="%ct")
            commit_author=$(git log -1 --format="%an")
            commit_message=$(git log -1 --format="%s" | head -c 60)
            cd - > /dev/null || exit
            
            # Calculate time ago with precision down to minutes
            current_timestamp=$(date +%s)
            seconds_ago=$((current_timestamp - commit_timestamp))
            
            if [ $seconds_ago -lt 60 ]; then
                time_ago="${seconds_ago} seconds ago"
            elif [ $seconds_ago -lt 3600 ]; then
                minutes_ago=$((seconds_ago / 60))
                time_ago="${minutes_ago} minutes ago"
            elif [ $seconds_ago -lt 86400 ]; then
                hours_ago=$((seconds_ago / 3600))
                minutes_ago=$(((seconds_ago % 3600) / 60))
                time_ago="${hours_ago} hours, ${minutes_ago} minutes ago"
            elif [ $seconds_ago -lt 2592000 ]; then
                days_ago=$((seconds_ago / 86400))
                hours_ago=$(((seconds_ago % 86400) / 3600))
                time_ago="${days_ago} days, ${hours_ago} hours ago"
            elif [ $seconds_ago -lt 31536000 ]; then
                months_ago=$((seconds_ago / 2592000))
                days_ago=$(((seconds_ago % 2592000) / 86400))
                time_ago="${months_ago} months, ${days_ago} days ago"
            else
                years_ago=$((seconds_ago / 31536000))
                months_ago=$(((seconds_ago % 31536000) / 2592000))
                time_ago="${years_ago} years, ${months_ago} months ago"
            fi
            
            echo "   📅 Date: $commit_date ($time_ago)"
            echo "   👤 Author: $commit_author"
            echo "   💬 Message: $commit_message..."
            
            rm -rf "$temp_dir"
        else
            echo "   ⚠ Could not fetch commit details"
        fi
    else
        echo "🔹 Latest commit (HEAD):    Error fetching"
    fi
    
    echo ""
    echo "🔄 Last 5 Workflow Runs:"
    echo "   ──────────────────────────────────────────────────────────────────"
    echo "      Status [Commit] Branch                    Date & Time"
    echo "   ──────────────────────────────────────────────────────────────────"
    
    # Try to fetch workflow runs from GitHub API
    if [ -n "$AUTH_HEADER" ]; then
        api_response=$(curl -s -H "$AUTH_HEADER" "https://api.github.com/repos/$repo_path/actions/runs?per_page=5" 2>/dev/null)
    else
        api_response=$(curl -s "https://api.github.com/repos/$repo_path/actions/runs?per_page=5" 2>/dev/null)
    fi
    
    # Check if we got valid JSON response
    if [ -n "$api_response" ] && echo "$api_response" | grep -q "workflow_runs"; then
        # Parse the workflow runs
        echo "$api_response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    runs = data.get('workflow_runs', [])
    if not runs:
        print('   ℹ No workflow runs found (repo may not have GitHub Actions)')
    else:
        for i, run in enumerate(runs[:5], 1):
            status = run.get('status', 'unknown')
            conclusion = run.get('conclusion', 'in_progress')
            created_full = run.get('created_at', '')
            created_date = created_full[:10]  # YYYY-MM-DD
            created_time = created_full[11:16]  # HH:MM
            commit = run.get('head_sha', '')[:7]
            branch = run.get('head_branch', 'unknown')[:25]
            
            # Determine status icon
            if conclusion == 'success':
                icon = '✓'
            elif conclusion == 'failure':
                icon = '✗'
            elif conclusion == 'cancelled':
                icon = '⊘'
            elif status == 'in_progress':
                icon = '⟳'
            else:
                icon = '?'
            
            print(f'   {i}. {icon} [{commit}] {branch:<25} {created_date} {created_time}')
except Exception as e:
    print(f'   ⚠ Error parsing workflow data: {e}')
" 2>/dev/null || echo "   ⚠ Error: Python3 required for workflow parsing"
    else
        # API didn't work - check why
        if echo "$api_response" | grep -q "rate limit"; then
            echo "   ⚠ API rate limit exceeded - set GITHUB_TOKEN to increase limit"
        elif echo "$api_response" | grep -q "Not Found"; then
            echo "   ℹ Repository not found or no access to workflows"
        elif [ -z "$api_response" ]; then
            echo "   ⚠ Network error or API not accessible from this environment"
        else
            echo "   ⚠ Could not fetch workflow data from GitHub API"
        fi
    fi
    
    echo ""
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Report completed at: $(date)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
