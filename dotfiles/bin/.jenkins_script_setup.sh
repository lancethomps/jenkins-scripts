#!/usr/bin/env bash
export JENKINS_JOB_URL_REGEX='^(https?):\/\/([^\/:]+)(:[0-9]+)?(?:\/)(?:job|blue\/organizations\/jenkins)\/(([^\/]+(?:\/job\/[^\/]+)?)(?:\/(?:view\/[^\/]+\/)?(?:job|detail)\/([^\/]+))?)\/([0-9]+|lastStableBuild|lastSuccessfulBuild|lastFailedBuild|lastUnstableBuild|lastUnsuccessfulBuild|lastCompletedBuild)\/?(?:pipeline\/?|display\/redirect|console|consoleText)?$'
export JOB_URL_TYPE_BRANCH="branch"
export JOB_URL_TYPE_PR="pr"
export JOB_URL_TYPE_TAG="tag"

function init_jenkins_vars() {
  local specified_host="${1-}"
  local job_var="${2-}"
  local job_num_opt="${3-}"

  if test -n "${job_var-}"; then
    if is_dl_directory "${job_var}" && ! is_full_job_url "$job_var" && test -z "${job_num_opt}"; then
      job_var="$(jq --raw-output '.url' "${job_var}/job.json")"
    fi

    if is_full_job_url "$job_var"; then
      JOB_URL="${job_var}"
      JOB_NAME="$(get_job_name_from_url "${JOB_URL}")"
      JOB_NUM="$(get_job_num_from_url "${JOB_URL}")"
      if test -z "${specified_host-}" && test -z "${JENKINS_HOST-}"; then
        JENKINS_HOST="$(get_jenkins_host_from_url "$job_var")"
        export JENKINS_HOST
      fi
      if is_blueocean_job_url "$JOB_URL"; then
        JOB_URL="$(get_full_job_url_from_blueocean_job_url "$JOB_URL")"
      fi
    else
      JOB_NAME="${job_var}"
      JOB_NUM="${job_num_opt}"
    fi
    export JOB_NAME JOB_NUM
  fi

  JENKINS_HOST="$(_get_jenkins_host "$specified_host")"
  export JENKINS_HOST

  if test -n "${job_var-}"; then
    if test -z "${JOB_URL-}"; then
      JOB_URL="$(get_full_job_url "${JOB_NAME}" "${JOB_NUM}")"
    fi
    export JOB_URL
  fi

  return 0
}

function is_dl_directory() {
  test -d "$1" && test -e "${1}/job.json"
}

function is_full_job_url() {
  if [[ $1 =~ https?://.* ]]; then
    return 0
  fi
  return 1
}

function is_blueocean_job_url() {
  if is_full_job_url "$@"; then
    if [[ $1 =~ .*/blue/organizations/jenkins/.* ]] || [[ $1 =~ .*/display/redirect$ ]]; then
      return 0
    fi
  fi
  return 1
}

function get_full_job_url_from_blueocean_job_url() {
  local url_scheme url_port
  url_scheme="$(echo "$1" | pcregrep -o1 "$JENKINS_JOB_URL_REGEX")"
  url_port="$(echo "$1" | pcregrep -o3 "$JENKINS_JOB_URL_REGEX")"
  echo "${url_scheme}://$(get_jenkins_host_from_url "$1")${url_port}/job/$(get_job_name_from_url "$1")/$(get_job_num_from_url "$1")"
}

function get_full_job_url() {
  if is_full_job_url "$1"; then
    if is_blueocean_job_url; then
      get_full_job_url_from_blueocean_job_url "$1"
    else
      echo "${1%/}"
    fi
  fi
  echo "https://${JENKINS_HOST}/job/${1}/${2:-${JOB_NUM}}"
}

function get_jenkins_host_from_url() {
  echo "$1" | pcregrep -o2 "$JENKINS_JOB_URL_REGEX"
}

function get_job_name_from_url() {
  local parent_name child_name

  parent_name="$(echo "$1" | pcregrep -o5 "$JENKINS_JOB_URL_REGEX")"
  child_name="$(echo "$1" | pcregrep -o6 "$JENKINS_JOB_URL_REGEX")"

  if test -z "${child_name-}" || test "${parent_name-}" = "${child_name-}"; then
    echo "${parent_name,,}"
  else
    if echo "${parent_name,,}" | grep -q '%2f'; then
      parent_name="$(_url_decode_old "${parent_name,,}" | sed -E 's/\//\/job\//g')"
    fi
    echo "${parent_name,,}/job/${child_name}"
  fi
}

function get_job_num_from_url() {
  echo "$1" | pcregrep -o7 "$JENKINS_JOB_URL_REGEX"
}

function get_job_url_from_repo() {
  local job_url_type repo_name job_name_for_type top_job_name full_job_name blueocean_job_url job_url base_url
  job_url_type="${JOB_URL_TYPE:-${1-}}"
  repo_name="$(git repo-name --keep-case)"
  top_job_name="upstart/job"

  if test -z "${job_url_type-}" || test "${job_url_type-}" = "${JOB_URL_TYPE_BRANCH}"; then
    job_name_for_type="$(git current-branch)"
    if git is-default-branch; then
      top_job_name="upstart_prod/job"
    fi
  elif test "${job_url_type-}" = "${JOB_URL_TYPE_PR}"; then
    if ! job_name_for_type="$(git prs-latest-number)"; then
      echo "FATAL Could not find last PR number: ${job_name_for_type}"
      exit 1
    fi
    job_name_for_type="PR-${job_name_for_type}"
  elif test "${job_url_type-}" = "${JOB_URL_TYPE_TAG}"; then
    if ! job_name_for_type="$(git tags --simple | head -1)"; then
      echo "FATAL Could not find last tag: ${job_name_for_type}"
      exit 1
    fi
  else
    echo "FATAL job_url_type not recognized: ${job_url_type-}"
    exit 1
  fi

  top_job_name="${top_job_name}/${repo_name}"
  top_job_name="$(check_for_custom_job_name "$top_job_name")"
  full_job_name="$(check_for_custom_job_name "${top_job_name}/job/${job_name_for_type//\//%2F}")"

  base_url="$(check_for_custom_base_url "${repo_name}" "${JENKINS_BASE_URL}")"

  if test "${USE_BLUEOCEAN-}" = "true"; then
    blueocean_job_url="${top_job_name/\/job\//\/}"
    blueocean_job_url="${blueocean_job_url//\//%2F}"
    job_url="${base_url}/blue/organizations/jenkins/${blueocean_job_url}/activity"
  else
    job_url="${base_url}/job/${full_job_name}"
  fi
  echo "$job_url"
}

function check_for_custom_base_url() {
  local custom_config_file="${XDG_CONFIG_HOME:-${HOME}/.config}/jenkins_job_custom_base_urls.yml"
  local job_name="$1"
  local def_value="$2"

  if ! test -e "$custom_config_file"; then
    echo "$def_value"
    return 0
  fi

  _get_yaml_prop "$custom_config_file" "$job_name" "$def_value" || true
}

function check_for_custom_job_name() {
  local custom_config_file="${XDG_CONFIG_HOME:-${HOME}/.config}/jenkins_job_custom_names.yml"
  local job_name="$1"
  local def_value="$job_name"

  if ! test -e "$custom_config_file"; then
    echo "$def_value"
    return 0
  fi

  _get_yaml_prop "$custom_config_file" "$job_name" "$def_value" || true
}

function get_jenkins_dir_from_url() {
  local dir_from_url

  init_jenkins_vars "" "${1}"
  dir_from_url="${HOME}/Documents/jenkins/${JOB_NAME}/${JOB_NUM}"

  if [[ $dir_from_url != *'%'* ]]; then
    echo "$dir_from_url"
    return 0
  fi

  _url_decode_old "$(_url_decode_old "${HOME}/Documents/jenkins/${JOB_NAME}/${JOB_NUM}")"
}

function _get_jenkins_host() {
  local tmp_host="${1-}"

  if test -n "$tmp_host"; then
    true
  elif test -n "${JENKINS_HOST-}"; then
    tmp_host="$JENKINS_HOST"
  elif test -n "${DEFAULT_JENKINS_HOST-}"; then
    tmp_host="${DEFAULT_JENKINS_HOST}"
  else
    echo "Please set either the JENKINS_HOST or DEFAULT_JENKINS_HOST environment variable."
    exit 1
  fi

  echo "$tmp_host"
}

function _get_yaml_prop() {
  { yq -r --exit-status ".[\"${2}\"] | select(. != null)" "$1" || echo "${3-}"; } | envsubst
}

function _url_decode_old() {
  local url_encoded="${1//+/ }"
  printf '%b' "${url_encoded//%/\\x}"
}
