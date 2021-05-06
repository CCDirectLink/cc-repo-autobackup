#!/usr/bin/env zsh

# http://redsymbol.net/articles/unofficial-bash-strict-mode/
setopt ERR_EXIT ERR_RETURN NO_UNSET PIPE_FAIL

ansi_reset="$(tput sgr0 || true)"
ansi_red="$(tput setaf 1 || true)"
ansi_yellow="$(tput setaf 3 || true)"
ansi_blue="$(tput setaf 4 || true)"
log_info()  { echo >&2 "${ansi_blue}[info]${ansi_reset}" "$@"; }
log_warn()  { echo >&2 "${ansi_yellow}[warn]${ansi_reset}" "$@"; }
log_error() { echo >&2 "${ansi_red}[ERROR]${ansi_reset}" "$@"; }
trap 'log_error line $LINENO' ERR

NETWORK_TIMEOUT=10
GITHUB_API_ORG_REPOS_URL="https://api.github.com/orgs/{}/repos?per_page=1000"
PROJECTS_DB_URL="https://gist.githubusercontent.com/dmitmel/d31f7aaf374f283f0834426b788e3ff5/raw/data.json"
PROJECTS_DB_FILE="projects.json"
BACKUP_DIR="backup"

# taken from https://github.com/getantibody/antibody/blob/0632d068e35a736a83178dd523ee8dfd33c3e3fe/project/git.go#L15
export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=0 SSH_ASKPASS=0

mkdir -pv "$BACKUP_DIR"

curl() {
  command curl --location --fail --max-time "$NETWORK_TIMEOUT" "$@"
}

log_info "fetching $PROJECTS_DB_URL"
curl "$PROJECTS_DB_URL" --output "$PROJECTS_DB_FILE"

log_info "reading $PROJECTS_DB_FILE"
projects=()
projects_db_version="$(jq '.version' $PROJECTS_DB_FILE)"
if [[ "$projects_db_version" == 1 ]]; then
  # https://unix.stackexchange.com/a/136216/411555
  projects+=("${(@f)$(
    jq --compact-output '(.people[], .organizations[] | select(.name != "CCDirectLink")).projects[].home' "$PROJECTS_DB_FILE"
  )}")
else
  log_error "unsupported $PROJECTS_DB_FILE version '$projects_db_version'"
fi

add_github_org_repos() {
  local org_name="$1"
  local api_url="${GITHUB_API_ORG_REPOS_URL/\{\}/"${org_name}"}"
  log_info "fetching repos from $api_url"
  projects+=("${(@f)$(
    curl "$api_url" | jq --compact-output --arg org_name "$org_name" '.[] | { type: "github", user: $org_name, repo: .name }'
  )}")
}

add_github_org_repos CCDirectLink
add_github_org_repos ccdirectlink3

cd "$BACKUP_DIR"

for (( i = 1, len = ${#projects[@]}; i <= len; i++ )); do
  project="${projects[$i]}"
  log_info "(${i}/${len}) ${project}"

  # An anonymous function is used to force ERR_RETURN to become effective.
  () {
    project_type="$(jq --raw-output '.type' <<< "$project")"

    case "$project_type" in
      github|gitlab) ;;
      *)
        log_warn "unsupported project type '$project_type'"
        false
        ;;
    esac

    tmp_file_path="$(jq --raw-output '"\(.type)/\(.user)/\(.repo).git"' <<< "$project")"
    git_clone_url="$(jq --raw-output '"https://\($project_type).com/\(.user)/\(.repo).git"' --arg project_type "$project_type" <<< "$project")"

    tmp_file_dir="$(dirname "$tmp_file_path")"
    tmp_file_name="$(basename "$tmp_file_path")"
    mkdir -pv "$tmp_file_dir"

    if [[ -e "$tmp_file_path" ]]; then
      log_info "deleting $tmp_file_path"
      rm -rf "$tmp_file_path"
    fi

    git clone --bare "$git_clone_url" "$tmp_file_path"

    archive_file_path="${tmp_file_path}.tar"
    log_info "creating archive $archive_file_path"
    # https://unix.stackexchange.com/a/13381/411555
    tar --create --force-local --file="$archive_file_path" --directory="$tmp_file_dir" "$tmp_file_name"

    log_info "deleting $tmp_file_path"
    rm -rf "$tmp_file_path"
  } || log_error "failed to backup!"
done
