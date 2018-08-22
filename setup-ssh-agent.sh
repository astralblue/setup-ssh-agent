#!/bin/sh
#
# Copyright (c) 2014, Eugene M. Kim.  All rights reserved.
#

set -eu

unset progname progdir
progname="${0##*/}"
progdir="${0%/*}"

msg() {
	case $# in
	[1-9]*)
		echo "$progname: $*" >&2
		;;
	esac
}

: ${LOG_LEVEL=warning}
debug() { _debug DEBUG: "$@"; }
info() { _info INFO: "$@"; }
notice() { _notice NOTICE: "$@"; }
warning() { _warning WARNING: "$@"; }
err() { _err ERROR: "$@"; }
crit() { _crit CRITICAL: "$@"; }
alert() { _alert ALERT: "$@"; }
emerg() { _emerg EMERGENCY: "$@"; }
_debug() { case "$LOG_LEVEL" in debug) msg "$@";; *) : "$@";; esac; }
_info() { case "$LOG_LEVEL" in info) msg "$@";; *) _debug "$@";; esac; }
_notice() { case "$LOG_LEVEL" in notice) msg "$@";; *) _info "$@";; esac; }
_warning() { case "$LOG_LEVEL" in warning) msg "$@";; *) _notice "$@";; esac; }
_err() { case "$LOG_LEVEL" in err) msg "$@";; *) _warning "$@";; esac; }
_crit() { case "$LOG_LEVEL" in crit) msg "$@";; *) _err "$@";; esac; }
_alert() { case "$LOG_LEVEL" in alert) msg "$@";; *) _crit "$@";; esac; }
_emerg() { case "$LOG_LEVEL" in emerg) msg "$@";; *) _alert "$@";; esac; }
fatal() {
	"$@"
	echo "(exit 1);"
	exit 1
}

print_usage() {
	echo "usage: eval \`$progname\`"
}

usage() {
	err "$@"
	print_usage >&2
	exit 64 # EX_USAGE
}

main() {
	set_default_options
	process_options "$@"
	shift $(($OPTIND - 1))
	auto_shell_type
	case $# in
	[1-9]*)
		usage "extra arguments given"
		;;
	esac
	if $kill_agent
	then
		kill_agent
	else
		start_agent
	fi
}

start_agent() {
	while ! agent_env_valid
	do
		if read_agent_info
		then
			if agent_env_valid
			then
				break
			fi
			notice "agent info stale; deleting and restarting"
			delete_agent_info
		fi
		if ! make_agent_info
		then
			err "cannot create agent"
			return 69
		fi
	done
	emit_agent_env
	display_agent_info
}

kill_agent() {
	if ! agent_env_valid
	then
		err "there is no agent to kill"
		return 69
	fi
	if ! has_agent_pid
	then
		err "agent PID unknown, cannot kill agent ($SSH_AUTH_SOCK)"
		return 69
	fi
	notice "killing agent ($SSH_AUTH_SOCK) PID $SSH_AGENT_PID"
	kill "$SSH_AGENT_PID"
	case "$shell_type" in
	sh)
		echo "unset SSH_AUTH_SOCK; unset SSH_AGENT_PID;"
		;;
	csh)
		echo "unsetenv SSH_AUTH_SOCK; unsetenv SSH_AGENT_PID;"
		;;
	esac
}

set_default_options() {
	unset shell_type bind_address default_lifetime kill_agent
	shell_type=
	bind_address=
	default_lifetime=
	kill_agent=false
}

process_options() {
	local _opt
	while getopts :cska:t: _opt
	do
		case "$_opt" in
		':')
			usage "missing argument for -$OPTARG"
			;;
		'?')
			usage "unknown option -$OPTARG"
			;;
		*)
			process_one_option "-$_opt" "${OPTARG-}"
			;;
		esac
	done
}

process_one_option() {
	case "$1" in
	-c)
		shell_type=csh
		;;
	-s)
		shell_type=sh
		;;
	-k)
		kill_agent=true
		;;
	-a)
		bind_address="$2"
		;;
	-t)
		default_lifetime="$2"
		;;
	esac
}

auto_shell_type() {
	case "$shell_type" in
	?*)
		return
		;;
	esac
	case "$SHELL" in
	*csh)
		shell_type=csh
		;;
	*)
		shell_type=sh
		;;
	esac
}

agent_env_set() {
	case "${SSH_AUTH_SOCK+set}" in
	set)
		info "SSH_AUTH_SOCK set: $SSH_AUTH_SOCK"
		return 0
		;;
	*)
		info "SSH_AUTH_SOCK not set"
		return 1
		;;
	esac
}

has_agent_pid() {
	case "${SSH_AGENT_PID+set}" in
	set)
		info "SSH_AGENT_PID set: $SSH_AGENT_PID"
		return 0
		;;
	*)
		info "SSH_AGENT_PID not set"
		return 1
		;;
	esac
}

agent_env_valid() {
	local _code=
	ssh-add -l > /dev/null 2>&1 || _code=$?
	case "$_code" in
	'')
		info "SSH_AUTH_SOCK valid: agent is running with key(s)"
		return 0
		;;
	1)
		info "SSH_AUTH_SOCK valid: agent is running with no keys"
		return 0
		;;
	*)
		info "SSH_AUTH_SOCK invalid (ssh-add returned $_code)"
		return 1
		;;
	esac
}

agent_info_file="/tmp/$progname.`id -un`"

read_agent_info() {
	local _sock _pid
	if [ -e "$agent_info_file" -a ! -f "$agent_info_file" ]
	then
		fatal err "$agent_info_file exists but is not a file"
	fi
	if ! read -r _pid _sock < "$agent_info_file"
	then
		info "cannot read agent info from $agent_info_file"
		return 1
	fi
	SSH_AUTH_SOCK="$_sock"
	SSH_AGENT_PID="$_pid"
	export SSH_AUTH_SOCK SSH_AGENT_PID
}

delete_agent_info() {
	notice "deleting agent info file $agent_info_file"
	rm -f "$agent_info_file"
}

make_agent_info() {
	local _tmpfile
	if ! _tmpfile=$(mktemp "$agent_info_file.XXXXXX")
	then
		fatal err "cannot create a temporary agent info file"
	fi
	if ! build_agent_info_file "$_tmpfile"
	then
		err "cannot build a temporary agent info file"
		rm -f "$_tmpfile"
		exit 1
	fi
	if ! mv -n "$_tmpfile" "$agent_info_file"
	then
		err "cannot move temporary agent info file into place"
		rm -f "$_tmpfile"
		exit 1
	fi
	notice "new agent info file has created"
}

build_agent_info_file() {
	local _code
	_code=
	eval `run_ssh_agent || echo _code=$?` > /dev/null
	case "$_code" in
	?*)
		err "ssh-agent returned $_code"
		return $_code
		;;
	esac
	echo "$SSH_AGENT_PID $SSH_AUTH_SOCK" > "$1"
}

run_ssh_agent() {
	set -- -s
	case "$bind_address" in
	?*)
		set -- -a "$bind_address"
		;;
	esac
	case "$default_lifetime" in
	?*)
		set -- -t "$default_lifetime"
		;;
	esac
	ssh-agent "$@"
}

emit_agent_env() {
	case "$shell_type" in
	sh)
		echo "SSH_AUTH_SOCK='$SSH_AUTH_SOCK'; export SSH_AUTH_SOCK;"
		case "${SSH_AGENT_PID+set}" in
		set)
			echo "SSH_AGENT_PID='$SSH_AGENT_PID'; export SSH_AGENT_PID;"
			;;
		esac
		;;
	csh)
		echo "setenv SSH_AUTH_SOCK '$SSH_AUTH_SOCK';"
		case "${SSH_AGENT_PID+set}" in
		set)
			echo "setenv SSH_AGENT_PID '$SSH_AGENT_PID';"
			;;
		esac
		;;
	esac
}

display_agent_info() {
	echo 'echo "Agent running at $SSH_AUTH_SOCK${SSH_AGENT_PID+" (PID $SSH_AGENT_PID)"}";'
}

main "$@"
