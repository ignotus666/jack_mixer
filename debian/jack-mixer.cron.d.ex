#
# Regular cron jobs for the jack-mixer package
#
0 4	* * *	root	[ -x /usr/bin/jack-mixer_maintenance ] && /usr/bin/jack-mixer_maintenance
