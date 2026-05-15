#!/command/with-contenv sh
set -eu

. /usr/local/bin/explo-runtime.sh

runtime_prepare_user
runtime_write_env_file
runtime_prepare_filesystem
runtime_generate_crontab
runtime_execute_on_start