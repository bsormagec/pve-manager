package PVE::API2::HAConfig;

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools;
use PVE::Cluster qw(cfs_lock_file cfs_read_file cfs_write_file);
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::JSONSchema qw(get_standard_option);
use PVE::Exception qw(raise_param_exc);

use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    name => 'index', 
    path => '', 
    method => 'GET',
    description => "Directory index.",
    permissions => {
	check => ['perm', '/', [ 'Sys.Audit' ]],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => {
		id => { type => 'string' },
	    },
	},
	links => [ { rel => 'child', href => "{id}" } ],
    },
    code => sub {
	my ($param) = @_;

	my $res = [ 
	    { id => 'config' },
	    { id => 'changes' },
	    { id => 'groups' },
	];

	return $res;
    }});

my $load_cluster_conf = sub {
    my $oldconf;
    my $newconf;

    my $code = sub {
	$oldconf = PVE::Cluster::cfs_read_file('cluster.conf');
	$newconf = PVE::Cluster::cfs_read_file('cluster.conf.new');
    };

    cfs_lock_file('cluster.conf', undef, $code);
    die $@ if $@;

    if (!$newconf->{children}) {
	return wantarray ? ($oldconf, undef) : $oldconf;
    }

    return $newconf if !wantarray;
 
    # test if there is different content

    my $oldstr = PVE::Cluster::write_cluster_conf("fake.cfg", $oldconf);
    my $newstr = PVE::Cluster::write_cluster_conf("fake.cfg", $newconf);

    return ($oldconf, undef) if $oldstr eq $newstr; # same content

    # comput diff to display on GUI

    my $oldfn = '/etc/pve/cluster.conf';
    my $newfn = '/etc/pve/cluster.conf.new';

    my $diff = PVE::INotify::ccache_compute_diff($oldfn, $newfn);

    return ($newconf, $diff);
};

__PACKAGE__->register_method({
    name => 'get_config', 
    path => 'config', 
    method => 'GET',
    description => "Read cluster configuartion (cluster.conf). If you have any uncommitted changes in cluster.conf.new that content is returned instead.",
    protected => 1,
    permissions => {
	check => ['perm', '/', [ 'Sys.Audit' ]],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {},
    },
    returns => {
	type => "object",
	properties => {},
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();

	my ($conf, $diff) = &$load_cluster_conf();

	$rpcenv->set_result_attrib('changes', $diff);

	return $conf;
    }});

__PACKAGE__->register_method({
    name => 'get_changes', 
    path => 'changes', 
    method => 'GET',
    description => "Get pending changes (unified diff between cluster.conf and cluster.conf.new",
    protected => 1,
    permissions => {
	check => ['perm', '/', [ 'Sys.Audit' ]],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {},
    },
    returns => { type => "string", optional => 1 },
    code => sub {
	my ($param) = @_;

	my ($conf, $diff) = &$load_cluster_conf();

	return $diff;
    }});

__PACKAGE__->register_method({
    name => 'revert_changes', 
    path => 'changes', 
    method => 'DELETE',
    description => "Revert pending changes (remove cluster.conf.new)",
    protected => 1,
    permissions => {
	check => ['perm', '/', [ 'Sys.Modify' ]],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {},
    },
    returns => { type => "null" },
    code => sub {
	my ($param) = @_;

	if (!unlink("/etc/pve/cluster.conf.new")) {
	    die "unlink failed - $!\n";
	}

	return;
    }});

__PACKAGE__->register_method({
    name => 'commit_config', 
    path => 'changes', 
    method => 'POST',
    description => "Commit cluster configuartion. Pending changes from cluster.conf.new are written to cluster.conf. This triggers a CMan reload on all nodes.",
    protected => 1,
    permissions => {
	check => ['perm', '/', [ 'Sys.Modify' ]],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {},
    },
    returns => { type => "null" },
    code => sub {
	my ($param) = @_;

	my $cmd = ['ccs_config_validate', '-l', '/etc/pve/cluster.conf.new'];
	my $out = '';
	eval {
	    # first line on stderr contains error message
	    PVE::Tools::run_command($cmd, errfunc => sub { $out .= shift if !$out; });
	};
	if (my $err = $@) {
	    chomp $out;
	    $out = "unknown error" if !$out;
	    die "config validation failed: $out\n";
	}

	PVE::Cluster::check_cfs_quorum();

	my $code = sub {
	    if (!rename('/etc/pve/cluster.conf.new', '/etc/pve/cluster.conf')) {
		die "commit failed - $!\n";
	    }
	};

	cfs_lock_file('cluster.conf', undef, $code);
	die $@ if $@;

	return;
    }});

my $read_cluster_conf_new = sub {

    my $conf = PVE::Cluster::cfs_read_file('cluster.conf.new');
    if (!$conf->{children}) {
	$conf = PVE::Cluster::cfs_read_file('cluster.conf');
    }
    return $conf;
};

my $update_cluster_conf_new = sub {
    my ($conf) = @_;
    $conf->{children}->[0]->{config_version}++;
    cfs_write_file('cluster.conf.new', $conf);
};

__PACKAGE__->register_method({
    name => 'list_groups', 
    path => 'groups', 
    method => 'GET',
    description => "List resource groups.",
    protected => 1,
    permissions => {
	check => ['perm', '/', [ 'Sys.Audit' ]],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => {},
	},
	links => [ { rel => 'child', href => "{id}" } ],
    },
    code => sub {
	my ($param) = @_;

	my $conf = &$read_cluster_conf_new();

	my $res = [];

	my $rmsec = PVE::Cluster::cluster_conf_lookup_rm_section($conf, 0, 1);
	return $res if !$rmsec;

	foreach my $child (@{$rmsec->{children}}) {
	    if ($child->{text} eq 'pvevm') {
		push @$res, { id => "$child->{text}:$child->{vmid}" }; 
	    } elsif ($child->{text} eq 'service') {
		push @$res, { id => "$child->{text}:$child->{name}" }; 
	    }
	}

	return $res;
    }});

__PACKAGE__->register_method({
    name => 'create_group', 
    path => 'groups', 
    method => 'POST',
    description => "Create a new resource groups.",
    protected => 1,
    permissions => {
	check => ['perm', '/', [ 'Sys.Modify' ]],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    vmid => get_standard_option('pve-vmid'),
	    autostart => {
		optional => 1, 
		type => 'boolean',
		description => "Service is started when a quorum forms.",
	    }
	},
    },
    returns => { type => "null" },
    code => sub {
	my ($param) = @_;

	my $vmlist = PVE::Cluster::get_vmlist();
	raise_param_exc({ id => "no such vmid '$param->{vmid}'"})
	    if !($vmlist && $vmlist->{ids} && $vmlist->{ids}->{$param->{vmid}});

	PVE::Cluster::check_cfs_quorum();
 
	my $code = sub {

	    my $conf = &$read_cluster_conf_new();

	    my $pvevm = PVE::Cluster::cluster_conf_lookup_pvevm($conf, 1, $param->{vmid});

	    $pvevm->{autostart} = $param->{autostart} ? 1 : 0;

	    &$update_cluster_conf_new($conf);
	};

	cfs_lock_file('cluster.conf', undef, $code);
	die $@ if $@;

	return;
    }});

__PACKAGE__->register_method({
    name => 'update_group', 
    path => 'groups/{id}', 
    method => 'PUT',
    description => "Update resource groups settings.",
    protected => 1,
    permissions => {
	check => ['perm', '/', [ 'Sys.Modify' ]],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    id => {
		type => 'string',
		description => "The resource group ID (for example 'pvevm:200').",
	    },
	    autostart => {
		optional => 1, 
		type => 'boolean',
		description => "Service is started when a quorum forms.",
	    }
	},
    },
    returns => { type => "null" },
    code => sub {
	my ($param) = @_;

	my $vmid;

	if ($param->{id} =~ m/^pvevm:(\d+)$/) {
	    $vmid = int($1);
	} else {
	    raise_param_exc({ id => "unsupported group type '$param->{id}'"});
	}

	PVE::Cluster::check_cfs_quorum();

	my $code = sub {

	    my $conf = &$read_cluster_conf_new();

	    my $pvevm = PVE::Cluster::cluster_conf_lookup_pvevm($conf, 0, $vmid);

	    $pvevm->{autostart} = $param->{autostart} ? 1 : 0;

	    &$update_cluster_conf_new($conf);
	};

	cfs_lock_file('cluster.conf', undef, $code);
	die $@ if $@;

	return;
    }});

__PACKAGE__->register_method({
    name => 'read_group', 
    path => 'groups/{id}', 
    method => 'GET',
    description => "List resource groups.",
    protected => 1,
    permissions => {
	check => ['perm', '/', [ 'Sys.Audit' ]],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    id => {
		type => 'string',
		description => "The resource group ID (for example 'pvevm:200').",
	    }
	},
    },
    returns => {
	type => "object",
	properties => {},
    },
    code => sub {
	my ($param) = @_;

	my $conf = &$read_cluster_conf_new();

	if (my $rmsec = PVE::Cluster::cluster_conf_lookup_rm_section($conf, 0, 1)) {
	    foreach my $child (@{$rmsec->{children}}) {
		if ($child->{text} eq 'pvevm') {
		    my $id = "$child->{text}:$child->{vmid}";
		    if ($id eq $param->{id}) {
			$child->{id} = $id;
			return $child;
		    } 
		} elsif ($child->{text} eq 'service') {
		    my $id = "$child->{text}:$child->{name}";
		    if ($id eq $param->{id}) {
			$child->{id} = $id;
			return $child;
		    } 
		}
	    }
	}

	raise_param_exc({ id => "no such group"});
    }});

__PACKAGE__->register_method({
    name => 'delete_group', 
    path => 'groups/{id}', 
    method => 'DELETE',
    description => "Delete resource group.",
    protected => 1,
    permissions => {
	check => ['perm', '/', [ 'Sys.Modify' ]],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    id => {
		type => 'string',
		description => "The resource group ID (for example 'pvevm:200').",
	    }
	},
    },
    returns => { type => "null" },
    code => sub {
	my ($param) = @_;

	PVE::Cluster::check_cfs_quorum();

	my $code = sub {
	    my $conf = &$read_cluster_conf_new();

	    my $found;
	    if (my $rmsec = PVE::Cluster::cluster_conf_lookup_rm_section($conf, 0, 1)) {
		my $oldlist = $rmsec->{children};
		$rmsec->{children} = [];
		foreach my $child (@$oldlist) {
		    if ($child->{text} eq 'pvevm') {
			if ("$child->{text}:$child->{vmid}" eq $param->{id}) {
			    $found = 1;
			    next;
			}
		    } elsif ($child->{text} eq 'service') {
			if ("$child->{text}:$child->{name}" eq $param->{id}) {
			    $found = 1;
			    next;
			}			    
		    }
		    push @{$rmsec->{children}}, $child;
		}
	    }

	    raise_param_exc({ id => "no such group"}) if !$found;

	    &$update_cluster_conf_new($conf);
	};

	cfs_lock_file('cluster.conf', undef, $code);
	die $@ if $@;	
	
	return;
    }});

1;
