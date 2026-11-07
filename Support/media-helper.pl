#!/usr/bin/perl
# EdgePal: starts the media helper inside /usr/bin/perl.
# macOS only lets Apple's own programs read Now Playing info, and perl is one of them.
# Usage: /usr/bin/perl media-helper.pl /path/to/libEdgePalMedia.dylib
use strict;
use warnings;
use DynaLoader;

my $library = shift @ARGV or die "usage: media-helper.pl <library>\n";
my $handle = DynaLoader::dl_load_file($library, 0)
    or die "could not load $library: " . DynaLoader::dl_error() . "\n";
my $symbol = DynaLoader::dl_find_symbol($handle, "edgepal_media_run")
    or die "edgepal_media_run not found in $library\n";
my $run = DynaLoader::dl_install_xsub("main::edgepal_media_run", $symbol);
&$run();
