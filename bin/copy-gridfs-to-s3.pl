#!/usr/bin/env perl

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin";

use GridFSToS3;

use YAML qw(LoadFile);


sub main
{
	unless ($ARGV[0])
	{
		die("Usage: $0 config.yml\n");
	}

	my $config = LoadFile($ARGV[0]) or die("Unable to read configuration from '$ARGV[0]': $!\n");

    GridFSToS3::copy_gridfs_to_s3($config);
}

main();
