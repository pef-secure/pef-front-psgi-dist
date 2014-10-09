package PEF::Front::UploadProgress;
use strict;
use warnings;
use PEF::Front::Cache;

sub get_progress {
	my ($message, $defaults) = @_;
	my $id  = $defaults->{ip} . "/" . $defaults->{scheme} . "/" . $defaults->{hostname} . "/" . $message->{id};
	my $rep = get_cache("upload:$id");
	if ($rep) {
		my ($done, $size) = split ':', $rep;
		return {result => 'OK', done => $done, size => $size};
	} else {
		return {result => 'NOTFOUND', answer => 'File with this id not found'};
	}
}

1;
