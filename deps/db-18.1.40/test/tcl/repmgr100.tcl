# Copyright (c) 2009, 2020 Oracle and/or its affiliates.  All rights reserved.
#
# See the file LICENSE for license information.
#

# TEST repmgr100
# TEST Basic test of repmgr's multi-process master support.
# TEST
# TEST Set up a simple 2-site group, create data and replicate it.
# TEST Add a second process at the master and have it write some
# TEST updates.  It does not explicitly start repmgr (nor do any
# TEST replication configuration, for that matter).  Its first
# TEST update triggers initiation of connections, and so it doesn't
# TEST get to the client without a log request.  But later updates
# TEST should go directly.

proc repmgr100 {  } {
	set tnum "100"
	set testopts { none prefmas }
	foreach to $testopts {
		puts "Repmgr$tnum ($to): Basic repmgr multi-process\
		    master support."
		repmgr100_sub $tnum $to
	}
}

proc repmgr100_sub { tnum testopt } {
	global testdir
	global ipversion

	set site_prog [setup_site_prog]

	env_cleanup $testdir

	set masterdir $testdir/MASTERDIR
	set clientdir $testdir/CLIENTDIR

	file mkdir $masterdir
	file mkdir $clientdir

	set hoststr [get_hoststr $ipversion]
	set ports [available_ports 2]
	set master_port [lindex $ports 0]
	set client_port [lindex $ports 1]

	#
	# Use heartbeats because the client usually requires a rerequest cycle
	# to finish catching up with the master after its initial client sync.
	# In repmgr, heartbeats are needed for client rerequests if there is
	# no further master activity.
	#
	puts "\tRepmgr$tnum.a: Set up the master (on TCP port $master_port)."
	set master [open "| $site_prog" "r+"]
	fconfigure $master -buffering line
	puts $master "home $masterdir"
	set masconfig [list \
	    [list repmgr_site $hoststr $master_port db_local_site on] \
	    "rep_set_timeout db_rep_heartbeat_send 250000"]
	if { $testopt == "prefmas" } {
		lappend masconfig \
		    "rep_set_config db_repmgr_conf_prefmas_master on" \
		    "rep_set_config db_repmgr_conf_2site_strict on"
	} else {
		lappend masconfig \
		    "rep_set_config db_repmgr_conf_2site_strict off"
	}
	make_dbconfig $masterdir $masconfig
	setup_repmgr_ssl $masterdir
	puts $master "output $testdir/m1output"
	puts $master "open_env"
	if { $testopt == "none" } {
		puts $master "start master"
	} else {
		# Preferred master requires both sites to start as client.
		puts $master "start client"
	}
	error_check_match start_master [gets $master] "*Successful*"
	puts $master "open_db test.db"
	puts $master "put myKey myValue"

	# sync.
	puts $master "echo setup"
	set sentinel [gets $master]
	error_check_good echo_setup $sentinel "setup"
	
	puts "\tRepmgr$tnum.b: Set up the client (on TCP port $client_port)."
	set client [open "| $site_prog" "r+"]
	fconfigure $client -buffering line
	puts $client "home $clientdir"
	puts $client "local $hoststr $client_port"
	set cliconfig [list \
	    [list repmgr_site $hoststr $client_port db_local_site on] \
	    [list repmgr_site $hoststr $master_port db_bootstrap_helper on] \
	    "rep_set_timeout db_rep_heartbeat_monitor 400000"]
	if { $testopt == "prefmas" } {
		lappend cliconfig \
		    "rep_set_config db_repmgr_conf_prefmas_client on" \
		    "rep_set_config db_repmgr_conf_2site_strict on"
	} else {
		lappend cliconfig \
		    "rep_set_config db_repmgr_conf_2site_strict off"
	}
	make_dbconfig $clientdir $cliconfig
	setup_repmgr_ssl $clientdir
	puts $client "output $testdir/coutput"
	puts $client "open_env"
	puts $client "start client"
	error_check_match start_client [gets $client] "*Successful*"

	puts "\tRepmgr$tnum.c: Wait for STARTUPDONE."
	set clientenv [berkdb_env -home $clientdir]
	await_startup_done $clientenv
	  
	puts "\tRepmgr$tnum.d: Start a second process at master."
	set m2 [open "| $site_prog" "r+"]
	fconfigure $m2 -buffering line
	puts $m2 "home $masterdir"
	puts $m2 "output $testdir/m2output"
	puts $m2 "open_env"
	puts $m2 "open_db test.db"
	puts $m2 "put sub1 abc"
	puts $m2 "echo firstputted"
	set sentinel [gets $m2]
	error_check_good m2_firstputted $sentinel "firstputted"
	puts $m2 "put sub2 xyz"
	puts $m2 "put sub3 ijk"
	puts $m2 "put sub4 pqr"
	puts $m2 "echo putted"
	set sentinel [gets $m2]
	error_check_good m2_putted $sentinel "putted"
	puts $master "put another record"
	puts $master "put and again"
	puts $master "echo m1putted"
	set sentinel [gets $master]
	error_check_good m1_putted $sentinel "m1putted"

	# Allow time for any rerequests needed for the client to finish
	# catching up.
	tclsleep 2

	puts "\tRepmgr$tnum.e: Check that replicated data is visible at client."
	puts $client "open_db test.db"
	set expected {{myKey myValue} {sub1 abc} {sub2 xyz} {another record}}
	verify_client_data $clientenv test.db $expected

	# make sure there weren't too many rerequests
	puts "\tRepmgr$tnum.f: Check rerequest stats"
	set pfs [stat_field $clientenv rep_stat "Log records requested"]
	error_check_good rerequest_count [expr $pfs <= 1] 1

	puts "\tRepmgr$tnum.g: Clean up."
	$clientenv close
	close $client
	close $master
	close $m2
}
