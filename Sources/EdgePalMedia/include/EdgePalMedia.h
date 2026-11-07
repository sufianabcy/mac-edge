// EdgePal media helper. Called by Support/media-helper.pl inside /usr/bin/perl.
#ifndef EDGEPAL_MEDIA_H
#define EDGEPAL_MEDIA_H

/// Runs forever: prints Now Playing info as JSON lines, takes commands on stdin.
/// The two arguments are perl's (interpreter, CV) and are ignored.
void edgepal_media_run(void *unused1, void *unused2);

#endif
