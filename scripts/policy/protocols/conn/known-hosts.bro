##! This script logs hosts that Bro determines have performed complete TCP 
##! handshakes and logs the address once per day (by default).  The log that 
##! is output provides an easy way to determine a count of the IP addresses in
##! use on a network per day.

@load base/utils/directions-and-hosts
@load base/frameworks/cluster

module Known;

export {
	## The known-hosts logging stream identifier.
	redef enum Log::ID += { HOSTS_LOG };

	## The record type which contains the column fields of the known-hosts log.
	type HostsInfo: record {
		## The timestamp at which the host was detected.
		ts:      time &log;
		## The address that was detected originating or responding to a
		## TCP connection.
		host:    addr &log;
	};

	## Toggles between different implementations of this script.
	## When true, use a Broker data store, else use a regular Bro set
	## with keys uniformly distributed over proxy nodes in cluster
	## operation.
	const use_host_store = T &redef;
	
	## The hosts whose existence should be logged and tracked.
	## See :bro:type:`Host` for possible choices.
	const host_tracking = LOCAL_HOSTS &redef;
	
@if ( Known::use_host_store )
	## Holds the set of all known hosts.  Keys in the store are addresses
	## and their associated value will always be the "true" boolean.
	global host_store: Cluster::StoreInfo;

	## The Broker topic name to use for :bro:see:`Known::host_store`.
	const host_store_name = "bro/known/hosts" &redef;

	## The expiry interval of new entries in :bro:see:`Known::host_store`.
	## This also changes the interval at which hosts get logged.
	const host_store_expiry = 1day &redef;

	## The timeout interval to use for operations against
	## :bro:see:`Known::host_store`.
	const host_store_timeout = 15sec &redef;

	## The retry interval to use for failed operations against
	## :bro:see:`Known::host_store`.
	const host_store_retry = 30sec &redef;

	## The maximum number of times to retry timed-out operations against
	## :bro:see:`Known::host_store`.
	const host_store_max_retries = 10 &redef;
@else
	## The set of all known addresses to store for preventing duplicate 
	## logging of addresses.  It can also be used from other scripts to 
	## inspect if an address has been seen in use.
	## Maintain the list of known hosts for 24 hours so that the existence
	## of each individual address is logged each day.
	##
	## In cluster operation, this set is distributed uniformly across
	## proxy nodes.
	global hosts: set[addr] &create_expire=1day &redef;
@endif

	## An event that can be handled to access the :bro:type:`Known::HostsInfo`
	## record as it is sent on to the logging framework.
	global log_known_hosts: event(rec: HostsInfo);
}

@if ( Known::use_host_store )
event bro_init()
	{
	Known::host_store = Cluster::create_store(Known::host_store_name);
	}

event Known::host_found(info: HostsInfo, attempt_number: count &default = 0)
	{
	when ( local r = Broker::put_unique(Known::host_store$store, info$host,
	                                    T, Known::host_store_expiry) )
		{
		if ( r$status == Broker::SUCCESS )
			{
			if ( r$result as bool )
				Log::write(Known::HOSTS_LOG, info);
			}
		else
			Reporter::error(fmt("%s: data store put_unique failure",
			                    Known::host_store_name));
		}
	timeout Known::host_store_timeout
		{
		if ( attempt_number < host_store_max_retries )
			schedule Known::host_store_retry { Known::host_found(info, ++attempt_number) };
		}
	}
@else
event known_host_add(info: HostsInfo)
	{
	if ( info$host in Known::hosts )
		return;

	add Known::hosts[info$host];

	@if ( ! Cluster::is_enabled() ||
	      Cluster::local_node_type() == Cluster::PROXY )
		Log::write(Known::HOSTS_LOG, info);
	@endif
	}

event Cluster::node_up(name: string, id: string)
	{
	if ( Cluster::local_node_type() != Cluster::WORKER )
		return;

	# Drop local suppression cache on workers to force HRW key repartitioning.
	Known::hosts = set();
	}

event Cluster::node_down(name: string, id: string)
	{
	if ( Cluster::local_node_type() != Cluster::WORKER )
		return;

	# Drop local suppression cache on workers to force HRW key repartitioning.
	Known::hosts = set();
	}

event Known::host_found(info: HostsInfo, attempt_number: count &default = 0)
	{
	Cluster::publish_hrw(Cluster::proxy_pool, info$host, known_host_add, info);
	event known_host_add(info);
	}
@endif

event bro_init()
	{
	Log::create_stream(Known::HOSTS_LOG, [$columns=HostsInfo, $ev=log_known_hosts, $path="known_hosts"]);
	}

event connection_established(c: connection) &priority=5
	{
	if ( c$orig$state != TCP_ESTABLISHED )
		return;

	if ( c$resp$state != TCP_ESTABLISHED )
		return;

	local id = c$id;

	for ( host in set(id$orig_h, id$resp_h) )
		if ( addr_matches_host(host, host_tracking) )
			event Known::host_found([$ts = network_time(), $host = host]);
	}
