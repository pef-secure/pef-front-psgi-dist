package PEF::Front::Session;

use strict;
use warnings;
use PEF::Front::Config;
use MLDBM::Sync;
use MLDBM qw(GDBM_File Storable);
use Fcntl qw(:DEFAULT :flock);
use Digest::SHA qw(sha1_hex);

sub _secure_value {
	open my $urand, '<', '/dev/urandom' or die "can't open /dev/urandom: $!";
	read ($urand, my $buf, 32);
	close $urand;
	return sha1_hex($buf);
}

sub new {
	my ($class, $request) = @_;
	my $key = $request->param(cfg_session_request_field);
	$key ||= _secure_value;
	my $self = bless {
		key     => $key,
		session => [time + cfg_session_refresh_time, {}]
	  },
	  $class;
	$self->load;
	$self;
}

sub load {
	my $self = $_[0];
	my %session_db;
	my $sobj = tie (%session_db, 'MLDBM::Sync', cfg_session_db_file, O_CREAT | O_RDWR, 0660) or die "$!";
	$sobj->Lock;
	my $session = $session_db{$self->{key}};
	if ($session && $session->[0] > time) {
		$self->{session}          = $session;
		$session->[0]             = time + cfg_session_refresh_time;
		$session_db{$self->{key}} = $session;
	} else {
		delete $session_db{$self->{key}};
	}
	$sobj->UnLock;
}

sub store {
	my $self = $_[0];
	tie (my %session_db, 'MLDBM::Sync', cfg_session_db_file, O_CREAT | O_RDWR, 0660) or die "$!";
	$self->{session}->[0] = time + cfg_session_refresh_time;
	$session_db{$self->{key}} = $self->{session};
}

sub destroy {
	my $self = $_[0];
	$self->{session}->[0] = 0;
	tie (my %session_db, 'MLDBM::Sync', cfg_session_db_file, O_CREAT | O_RDWR, 0660) or die "$!";
	delete $session_db{$self->{key}};
}

sub data {
	my $self = $_[0];
	$self->{session}->[1];
}

sub key {
	my $self = $_[0];
	$self->{key};
}

sub DESTROY {
	my $self = $_[0];
	if ($self->{session}->[0] > time) {
		$self->store;
	} else {
		$self->destroy;
	}
}

1;
