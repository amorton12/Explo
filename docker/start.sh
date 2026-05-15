#!/bin/sh

# Shared helper functions used by s6 init and service scripts.

# If user incorrectly mounts the config path as a directory, we'll try to automatically append it to .env inside it instead of failing.
runtime_resolve_web_env_path() {
  env_path="${WEB_ENV_PATH:-/opt/explo/.env}"
  if [ -d "$env_path" ]; then
    env_path="$env_path/.env"
    echo "[setup] Config path is a directory, using $WEB_ENV_PATH"
  fi
  printf '%s\n' "$env_path"
}

# Load *_SCHEDULE and *_FLAGS from .env if not already set in the environment.
# This allows the web UI to configure schedules by writing to the .env file.
runtime_load_schedule_envs() {
  env_path="$1"

  if [ ! -f "$env_path" ]; then
    return 0
  fi

  while IFS= read -r line; do
    case "$line" in \
      \#*|'') continue ;;
    esac

    key="${line%%=*}"
    case "$key" in
      *_SCHEDULE|*_FLAGS)
        if [ -z "$(printenv "$key" 2>/dev/null)" ]; then
          export "$key=${line#*=}"
        fi
        ;;
    esac
  done < "$env_path"
}

# Create a user and group based on PUID and PGID, or use existing ones if they already exist.
# This allows the container to run with the same permissions as the host user, avoiding permission issues with mounted volumes.
# Retain root as default for backwards compatibility, so if PUID/PGID are not set, we'll just run as root.
runtime_prepare_user() {
  PUID="${PUID:-0}"
  PGID="${PGID:-0}"

  if getent group "$PGID" >/dev/null 2>&1; then
    EXPLO_GROUP="$(getent group "$PGID" | cut -d: -f1)"
  else
    EXPLO_GROUP="explo"
    groupadd -g "$PGID" "$EXPLO_GROUP"
  fi

  if getent passwd "$PUID" >/dev/null 2>&1; then
    EXPLO_USER="$(getent passwd "$PUID" | cut -d: -f1)"
  else
    EXPLO_USER="explo"
    useradd -u "$PUID" -g "$PGID" -M -s /sbin/nologin "$EXPLO_USER"
  fi

  export PUID PGID EXPLO_USER EXPLO_GROUP
}

# Prepare the filesystem by creating necessary directories and files with correct ownership.
runtime_prepare_filesystem() {
  runtime_cfg_path="$(runtime_resolve_web_env_path)"
  runtime_cfg_dir="$(dirname "$runtime_cfg_path")"

  mkdir -p /opt/explo/config
  mkdir -p "$runtime_cfg_dir"
  mkdir -p "$runtime_cfg_dir/logs"
  mkdir -p "$runtime_cfg_dir/cache/covers"

  if [ ! -e "$runtime_cfg_path" ]; then
    : > "$runtime_cfg_path"
  fi

  chown -R "$EXPLO_USER:$EXPLO_GROUP" /opt/explo/config
  chown -R "$EXPLO_USER:$EXPLO_GROUP" "$runtime_cfg_dir/logs" "$runtime_cfg_dir/cache"
  chown "$EXPLO_USER:$EXPLO_GROUP" "$runtime_cfg_path"
}

# Write environment variables to a file that will be sourced by the s6 init script
runtime_write_env_file() {
  runtime_env_path="$(runtime_resolve_web_env_path)"

  mkdir -p /etc/default
  cat > /etc/default/explo-runtime <<EOF
export PUID='$PUID'
export PGID='$PGID'
export EXPLO_USER='$EXPLO_USER'
export EXPLO_GROUP='$EXPLO_GROUP'
export WEB_ENV_PATH='$runtime_env_path'
EOF
}

# Loop over all *_SCHEDULE environment variables and generate corresponding cron jobs for root (these will be run with su-exec to the correct user) 
runtime_generate_crontab() {
  runtime_env_path="$(runtime_resolve_web_env_path)"
  runtime_load_schedule_envs "$runtime_env_path"

  echo "[setup] Initializing cron jobs..."

  : > /etc/crontabs/root

  # $CRON_SCHEDULE was deprecated in v0.11.0, keeping this block for backwards compatibility
  if [ -n "${CRON_SCHEDULE:-}" ]; then
    printf '%s %s\n' "$CRON_SCHEDULE" '/usr/local/bin/explo-cron-run' >> /etc/crontabs/root
    echo "[setup] Registered single CRON_SCHEDULE job: $CRON_SCHEDULE"
  fi

  for var in $(env | grep '_SCHEDULE=' | cut -d= -f1); do
    case "$var" in
      CRON_SCHEDULE) continue ;;
    esac

    job="${var%_SCHEDULE}"              # Job name (e.g WEEKLY_EXPLORATION)
    schedule="$(printenv "$var")"       # Cron schedule
    flags_var="${job}_FLAGS"
    flags="$(printenv "$flags_var")"    # e.g. --playlist weekly-exploration

    if [ -z "$schedule" ]; then
      echo "[setup] Skipping $job: schedule is empty"
      continue
    fi

    if [ -n "$flags" ]; then
      printf '%s %s %s\n' "$schedule" '/usr/local/bin/explo-cron-run' "$flags" >> /etc/crontabs/root
    else
      printf '%s %s\n' "$schedule" '/usr/local/bin/explo-cron-run' >> /etc/crontabs/root
    fi

    echo "[setup] Registered job: $job"
    echo "        Schedule: $schedule"
    echo "        Command : /usr/local/bin/explo-cron-run $flags"
  done

  chmod 600 /etc/crontabs/root
}

runtime_execute_on_start() {
  if [ "${EXECUTE_ON_START:-false}" = "true" ]; then
    echo "[setup] Executing startup task..."
    apk add --upgrade yt-dlp
    cd /opt/explo
    env WEB_UI=false su-exec "$EXPLO_USER:$EXPLO_GROUP" /opt/explo/explo ${START_FLAGS:-} || true
  fi
}

runtime_start_webui() {
  runtime_env_path="$(runtime_resolve_web_env_path)"
  echo "[setup] Starting web UI with environment from $runtime_env_path"
  echo "[setup] Web UI available at http://localhost:${WEB_ADDR##*:}"
  exec env WEB_UI=true WEB_ENV_PATH="$runtime_env_path" WEB_ADDR="${WEB_ADDR:-:7288}" \
    su-exec "$EXPLO_USER:$EXPLO_GROUP" /opt/explo/explo
}

runtime_run_cron_job() {
  apk add --upgrade yt-dlp
  cd /opt/explo
  exec env WEB_UI=false su-exec "$EXPLO_USER:$EXPLO_GROUP" /opt/explo/explo "$@"
}