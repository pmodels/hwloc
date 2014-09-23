#!/usr/bin/env perl

#
# Copyright © 2013-2014 Inria.  All rights reserved.
#
# See COPYING in top-level directory.
#
# $HEADER$
#

use strict;

use Getopt::Long;

my $hwlocdir = undef;
my $outdir = undef;
my @forcesubnets;
my $needsudo = 0;
my $ibnetdiscover = "/usr/sbin/ibnetdiscover";
my $ibroute = "/usr/sbin/ibroute";
my $verbose = 0;
my $force = 0;
my $dryrun = 0;
my $ignoreerrors = 0;

&Getopt::Long::Configure("bundling");
my $ok = Getopt::Long::GetOptions(
	"out-dir|f=s" => \$outdir,
	"hwloc-dir|f=s" => \$hwlocdir,
	"force-subnet|f=s" => \@forcesubnets,
	"sudo" => \$needsudo,
	"ibnetdiscover|f=s" => \$ibnetdiscover,
	"ibroute|f=s" => \$ibroute,
        "ignore-errors" => \$ignoreerrors,
	"verbose" => \$verbose,
	"force" => \$force,
	"dry-run" => \$dryrun
    );

if (!$ok or !defined $outdir) {
    print "Output directory for raw IB data must be specified with\n";
    print " --out-dir <dir>\n";
    print "Input must be one of these\n";
    print " --hwloc-dir <dir>\n";
    print "    Specifies that <dir> contains the hwloc XML exports of the some nodes,\n";
    print "    The list of IB subnets should be guessed from there.\n";
    print " --force-subnet [<subnet>:]<board>:<port> to force the discovery\n";
    print "    Force discovery on local board <board> port <port>, and optionally force the\n";
    print "    subnet id <subnet> instead of reading it from the first GID.\n";
    print "    Examples: --force-subnet mlx4_0:1\n";
    print "              --force-subnet fe80:0000:0000:0000:mlx4_0:1\n";
    print "Other options\n";
    print " --sudo\n";
    print "    Pass sudo to internal ibnetdiscover and ibroute invocations.\n";
    print "    Useful when the entire script cannot run as root.\n";
    print " --ibnetdiscover --ibroute\n";
    print "    Specify exact location of programs. Default is /usr/bin/<program>\n";
    print " --ignore-errors\n";
    print "    Ignore errors from ibnetdiscover and ibroute, assume their outputs are ok\n";
    print " --verbose\n";
    print "    Add verbose messages\n";
    print " --dry-run\n";
    print "    Do not actually run programs\n";
    exit(1);
}
mkdir $outdir;
if (!-d $outdir) {
    print "$outdir isn't a directory\n";
    exit (1);
}
if ($hwlocdir and @forcesubnets) {
    print "Don't specify both --hwloc-dir and --force-subnet.\n";
    exit (1);
}

my $sudo = $needsudo ? "sudo" : "";

if (`id -u` ne 0 and !$sudo and !$dryrun) {
    print "WARNING: Not running as root.\n";
}

# subnets that will be discovered locally
my %subnets_todiscover;

#########################################
# Read forced subnets
if (@forcesubnets) {
  print "Enforcing list of subnets to discover:\n";
  foreach my $subnetstring (@forcesubnets) {
    if ($subnetstring =~ /^([0-9a-fA-F:]{19}):([0-9a-z_-]+):([0-9]+)$/) {
      my $subnet = $1;
      my $boardname = $2;
      my $portnum = $3;
      print " Subnet $subnet from local board $boardname port $portnum.\n";
      $subnets_todiscover{$subnet}->{localboardname} = $boardname;
      $subnets_todiscover{$subnet}->{localportnum} = $portnum;

    } elsif ($subnetstring =~ /^([0-9a-z_-]+):([0-9]+)$/) {
      my $boardname = $1;
      my $portnum = $2;
      my $subnet;
      print " Unknown subnet from local board $boardname port $portnum.\n";
      my $filename = "/sys/class/infiniband/$boardname/ports/$portnum/gids/0";
      if (open FILE, $filename) {
        my $line = <FILE>;
        if ($line =~ /^([0-9a-fA-F:]{19}):([0-9a-fA-F:]{19})$/) {
	  $subnet = $1
        }
        close FILE;
      }
      if (defined $subnet) {
	print "  Found subnet $subnet from first GID.\n";
	$subnets_todiscover{$subnet}->{localboardname} = $boardname;
	$subnets_todiscover{$subnet}->{localportnum} = $portnum;
      } else {
	print "  Couldn't read subnet from GID $filename, ignoring.\n";
      }

    } else {
      print " Cannot parse --force-subnet $subnetstring, ignoring.\n";
    }
  }
  print "\n";
}

#########################################
# Guess subnets from hwloc
if ($hwlocdir) {

  # $servers{$hostname}->{gids}->{$boardname}->{$portnum}->{$gidnum}->{subnet} and ->{guid} = xxxx:xxxx:xxxx:xxxx
  # $servers{$hostname}->{gids}->{$boardname}->{$portnum}->{invalid} = 1
  # $servers{$hostname}->{subnets}->{$subnet} = 1
  my %servers;

  # $subnets{$subnet}->{$hostname} = 1;
  my %subnets;

  opendir DIR, $hwlocdir
    or die "Failed to open hwloc directory ($!).\n";
  # list subnets by ports
  while (my $hwlocfile = readdir DIR) {
    my $hostname;
    if ($hwlocfile =~ /(.+).xml$/) {
      $hostname = $1;
    } else {
      next;
    }

    open FILE, "$hwlocdir/$hwlocfile" or next;
    my $boardname = undef;
    my $portnum = undef;
    while (my $line = <FILE>) {
      if ($line =~ /<object type=\"OSDev\" name=\"(.+)\" osdev_type=\"3\">/) {
        $boardname = $1;
      } elsif ($line =~ /<\/object>/) {
        $boardname = undef;
      } elsif ($line =~ /<info name=\"Port([0-9]+)GID([0-9]+)\" value=\"([0-9a-fA-F:]{19}):([0-9a-fA-F:]{19})\"\/>/) {
        $servers{$hostname}->{gids}->{$boardname}->{$1}->{$2}->{subnet} = $3;
        $servers{$hostname}->{gids}->{$boardname}->{$1}->{$2}->{guid} = $4;
      } elsif ($line =~ /<info name=\"Port([0-9]+)LID\" value=\"(0x[0-9a-fA-F]+)\"\/>/) {
        # lid must be between 0x1 and 0xbfff
        if ((hex $2) < 1 or (hex $2) > 49151) {
          $servers{$hostname}->{gids}->{$boardname}->{$1}->{invalid} = 1;
        }
      } elsif ($line =~ /<info name=\"Port([0-9]+)State\" value=\"([0-9])\"\/>/) {
        # state must be active = 4
        if ($2 != 4) {
          $servers{$hostname}->{gids}->{$boardname}->{$1}->{invalid} = 1;
        }
      }
    }
    close FILE;
  }
  closedir DIR;

  # remove down/inactive ports/servers/...
  foreach my $hostname (keys %servers) {
    foreach my $boardname (keys %{$servers{$hostname}->{gids}}) {
      foreach my $portnum (keys %{$servers{$hostname}->{gids}->{$boardname}}) {
        delete $servers{$hostname}->{gids}->{$boardname}->{$portnum}
	  if exists $servers{$hostname}->{gids}->{$boardname}->{$portnum}->{invalid};
      }
      delete $servers{$hostname}->{gids}->{$boardname}
        unless keys %{$servers{$hostname}->{gids}->{$boardname}};
    }
    delete $servers{$hostname}
      unless keys %{$servers{$hostname}->{gids}};
  }

  # fill list of hostnames per subnets and subnets per hostnames
  foreach my $hostname (keys %servers) {
    foreach my $boardname (keys %{$servers{$hostname}->{gids}}) {
      foreach my $portnum (keys %{$servers{$hostname}->{gids}->{$boardname}}) {
	foreach my $gidid (keys %{$servers{$hostname}->{gids}->{$boardname}->{$portnum}}) {
	  my $subnet  = $servers{$hostname}->{gids}->{$boardname}->{$portnum}->{$gidid}->{subnet};
	  $servers{$hostname}->{subnets}->{$subnet} = 1;
	  $subnets{$subnet}->{$hostname} = 1;
	}
      }
    }
  }

  my $nrsubnets = scalar (keys %subnets);
  print "Found $nrsubnets subnets in hwloc directory:\n";
  # find local subnets
  my $localhostname = `hostname`; chomp $localhostname;
  {
    my $hostname = $localhostname;
    foreach my $boardname (keys %{$servers{$hostname}->{gids}}) {
      foreach my $portnum (keys %{$servers{$hostname}->{gids}->{$boardname}}) {
        foreach my $gidid (keys %{$servers{$hostname}->{gids}->{$boardname}->{$portnum}}) {
          my $subnet = $servers{$hostname}->{gids}->{$boardname}->{$portnum}->{$gidid}->{subnet};
	  if (!exists $subnets_todiscover{$subnet}) {
	    print " Subnet $subnet is locally accessible from board $boardname port $portnum.\n";
	    $subnets_todiscover{$subnet}->{localboardname} = $boardname;
	    $subnets_todiscover{$subnet}->{localportnum} = $portnum;
	  } elsif ($verbose) {
	    print " Subnet $subnet is also locally accessible from board $boardname port $portnum.\n";
	  }
        }
      }
    }
  }
  # find non-locally accessible subnets
  foreach my $subnet (keys %subnets) {
    next if exists $subnets{$subnet}->{$localhostname};
    print " Subnet $subnet is NOT locally accessible.\n";
    my @hostnames = (keys %{$subnets{$subnet}});
    if ($verbose) {
      print "  Subnet $subnet is accessible from nodes:\n";
      foreach my $hostname (@hostnames) {
	print "   $hostname\n";
      }
    } else {
      print "  Subnet $subnet is accessible from node ".$hostnames[0];
      print " (and ".(@hostnames-1)." others)" if (@hostnames > 1);
      print "\n";
    }
  }
  print "\n";

  # list nodes that are connected to all subnets, if the local isn't
  if (scalar keys %{$servers{$localhostname}->{subnets}} != $nrsubnets) {
    my @fullyconnectedhostnames;
    foreach my $hostname (keys %servers) {
      if (scalar keys %{$servers{$hostname}->{subnets}} == $nrsubnets) {
	push @fullyconnectedhostnames, $hostname;
      }
    }
    if (@fullyconnectedhostnames) {
      if ($verbose) {
	print "All subnets are accessible from nodes:\n";
	foreach my $hostname (@fullyconnectedhostnames) {
	  print " $hostname\n";
	}
      } else {
	print "All subnets are accessible from node ".$fullyconnectedhostnames[0];
	print " (and ".(@fullyconnectedhostnames-1)." others)" if (@fullyconnectedhostnames > 1);
	print "\n";
      }
    } else {
      print "No node is connected to all subnets.\n";
    }
    print "\n";
  }
}

###########################
# Discovery routines

# ibnetdiscover has GUIDs in the form of 0xXXXXXXXXXXXXXXXX, but hwloc
# has GUIDs in the form of XXXX:XXXX:XXXX:XXXX.  So just arbitrarily
# choose hwloc's form and convert everything to that format.
sub normalize_guid {
    my ($guid) = @_;

    return ""
        if ($guid eq "");

    $guid =~ m/0x(.{4})(.{4})(.{4})(.{4})/;
    return "$1:$2:$3:$4";
}

sub getroutes {
    my $subnet = shift;
    my $boardname = shift;
    my $portnum = shift;
    my $ibnetdiscoveroutput = shift;
    my $ibrouteoutdir = shift;
    my $lids;

    if (!open(FILE, $ibnetdiscoveroutput)) {
      print "  Couldn't open $ibnetdiscoveroutput\n";
      return;
    }

    while (<FILE>) {
        # We only need lines that begin with SW
        next
            if (! /^SW /);

        # Split out the columns.  Yay regexps.  One form of line has
        # both source and destination information.  The other form
        # only has source information (because it's not hooked up to
        # anything -- usually a switch port that doesn't have anything
        # plugged in to it).
        chomp;
        my $line = $_;

        my ($have_peer, $src_name, $src_type, $src_lid, $src_port_id,
            $src_guid, $width, $speed, $dest_type, $dest_lid, $dest_port_id,
            $dest_guid, $dest_name);

        # First, assume that the line has both a port and a peer.
        if ($line !~ m/^SW\s+(\d+)\s+(\d+)\s+(0x[0-9a-f]{16})\s+(\d+x)\s(.{3})\s+-\s+(CA|SW)\s+(\d+)\s+(\d+)\s+(0x[0-9a-f]{16})\s+\(\s+'(.+?)'\s+-\s+'(.+?)'\s\)/) {
            # If we get here, there was no peer -- just a port.
            $have_peer = 0;

            $line =~ m/^SW\s+(\d+)\s+(\d+)\s+(0x[0-9a-f]{16})\s+(\d+x)\s(.{3})\s+'(.+?)'/;
            $src_lid = $1; # This is a decimal number
            $src_port_id = $2; # This is a decimal number
            $src_guid = $3;
            $width = $4;
            $speed = $5;
            $src_name = $6;
        } else {
            $have_peer = 1;

            $src_lid = $1; # This is a decimal number
            $src_port_id = $2; # This is a decimal number
            $src_guid = $3;
            $width = $4;
            $speed = $5;
            $dest_type = $6;
            $dest_lid = $7; # This is a decimal number
            $dest_port_id = $8; # This is a decimal number
            $dest_guid = $9;
            $src_name = $10;
            $dest_name = $11;
        }

        # Convert GUIDs to the form xxxx:xxxx:xxxx:xxxx
        $src_guid = normalize_guid($src_guid);
        $dest_guid = normalize_guid($dest_guid)
            if ($have_peer);

        # If the source switch LID already exists, then just keep
        # going.
        next
            if (exists($lids->{$src_lid}));

        # Run ibroute on this switch LID
	my $ibrouteoutput = "$ibrouteoutdir/ibroute-$subnet-$src_lid.txt";
        print "  Running ibroute for switch LID $src_lid...\n";
	my $cmd = "$sudo $ibroute -C $boardname -P $portnum $src_lid";
	if ($dryrun) {
	  print "   NOT running $cmd\n" if $verbose;
	} else {
	  my $ret = system "$cmd > ${ibrouteoutput}.new" ;
	  if (!$ret or $ignoreerrors) {
	    unlink ${ibrouteoutput};
	    rename "${ibrouteoutput}.new", "${ibrouteoutput}";
	  } else {
	    unlink "${ibrouteoutput}.new";
	    print "   Failed (exit code $ret).\n";
	    next;
	  }
	}

        $lids->{$src_lid} = 1;
    }

    close FILE;
}

##############################"
# Discover subnets for real

foreach my $subnet (keys %subnets_todiscover) {
  my $boardname = $subnets_todiscover{$subnet}->{localboardname};
  my $portnum = $subnets_todiscover{$subnet}->{localportnum};

  print "Looking at $subnet (through local board $boardname port $portnum)...\n";

  my $ibnetdiscoveroutput = "$outdir/ib-subnet-$subnet.txt";
  my $ibrouteoutdir = "$outdir/ibroutes-$subnet";

  if (-f $ibnetdiscoveroutput and !$force) {
    print " $outdir/ib-subnet-$subnet.txt already exists, discover again? (y/n) ";
    my $answer = <>;
    next if $answer !~ /^y/;
  }

  print " Running ibnetdiscover...\n";
  my $cmd = "$sudo $ibnetdiscover -s -l -g -H -S -R -p -C $boardname -P $portnum";
  if ($dryrun) {
    print "  NOT running $cmd\n" if $verbose;
  } else {
    my $ret = system "$cmd > ${ibnetdiscoveroutput}.new" ;
    if (!$ret or $ignoreerrors) {
      unlink ${ibnetdiscoveroutput};
      rename "${ibnetdiscoveroutput}.new", "${ibnetdiscoveroutput}";
    } else {
      unlink "${ibnetdiscoveroutput}.new";
      print "  Failed (exit code $ret).\n";
      next;
    }
  }

  print " Getting routes...\n";
  if (!$dryrun) {
    system("rm -rf $ibrouteoutdir");
    mkdir $ibrouteoutdir;
  }
  getroutes $subnet, $boardname, $portnum, $ibnetdiscoveroutput, $ibrouteoutdir;
}
