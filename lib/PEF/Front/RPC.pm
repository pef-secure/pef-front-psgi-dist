package PEF::Front::RPC;

use strict;
use warnings;
use utf8;
use IO::Socket;
use Socket;
use JSON;
use Carp;
use Errno;
use Scalar::Util;

sub create_connected_socket {
	my $self = $_[0];
	my $sock;
	for (1 .. 5) {
		$sock = IO::Socket::INET->new(
			PeerAddr => $self->{'Addr'},
			PeerPort => $self->{'Port'},
			Proto    => 'tcp',
			Timeout  => 10
		);
		last if $sock;
	}
	croak {
		result => 'INTERR',
		answer => "fatal_RPC_connect: $!"
	  }
	  if not $sock;
	$self->{sock} = $sock;
}

sub new {
	my $class = shift;
	my $self = {readBuffer => ''};
	bless($self, $class);
	my %args = @_;
	if (exists $args{Socket}) {
		$self->{sock} = $args{Socket};
	} else {
		if (!exists($args{Port}) || !exists($args{Addr})) {
			croak {
				result => 'INTERR',
				answer => "fatal_RPC_connect: Port or Addr is not defined"
			};
		}
		$self->{Addr} = $args{Addr};
		$self->{Port} = $args{Port};
		$self->create_connected_socket();
	}
	return $self;
}

sub has_more {
	my ($self) = @_;
	return $self->{readBuffer} ne '';
}

sub close {
	my ($self) = @_;
	$self->{sock}->close();
	$self->{sock} = undef;
}

sub sock {
	my ($self) = @_;
	return $self->{sock};
}

sub send_message {
	my ($self, $message) = @_;
	my @objs = grep {Scalar::Util::blessed($message->{$_})} keys %$message;
	delete $message->{$_} for @objs;
	my $enc = encode_json($message) . "\r\n";
	$self->{to_send} = $enc;
	my $octets   = length($enc);
	my $attempts = 0;
	while (1) {
		my $len = length($enc);
		my $rc  = $self->{sock}->syswrite($enc);
		if (!defined $rc) {
			if ($!{EINTR} || $!{EAGAIN}) {
				next;
			}
			if (++$attempts > 5) {
				croak {
					result => 'INTERR',
					answer => "fatal_RPC_send ($len): $!"
				};
			}
			$self->{sock}->close();
			if (exists($self->{Addr}) && exists($self->{Port})) {
				$self->create_connected_socket();
				$enc = $self->{to_send};
			} else {
				croak {
					result => 'INTERR',
					answer => "fatal_RPC_send ($len): $!"
				};
			}
		} else {
			if ($octets != $rc) {
				substr($enc, 0, $rc) = '';
				$octets -= $rc;
			} else {
				last;
			}
		}
	}
	$self;
}

sub dump {
	my $self = $_[0];
	return $self->{'dump'};
}

sub recv_message {
	my ($self) = @_;
	my $enc;
	my $head = '';
	while (1) {
		my $msg_end = index($self->{readBuffer}, "\r\n");
		if ($msg_end == -1) {
			my $rc = $self->{sock}->sysread($enc, 8192);
			if (!defined($rc) || $rc == 0) {
				if (not defined $rc) {
					croak {
						result => 'INTERR',
						answer => "fatal_RPC_receive: $!"
					  }
					  if !$!{EINTR}
					  && !$!{EAGAIN};
				} else {
					croak {
						result => 'CLOSED',
						answer => "fatal_RPC_receive: unexpectedly closed channel"
					};
				}
			} else {
				$self->{readBuffer} .= $enc;
			}
		} else {
			$enc = substr($self->{readBuffer}, 0, $msg_end);
			substr($self->{readBuffer}, 0, $msg_end + 2) = '';
			last;
		}
	}
	my $msg = eval {decode_json($enc)};
	if ($@) {
		$self->{'dump'} = $enc;
		croak {
			result => 'INTERR',
			answer => "fatal_RPC_receive::bad message: $@"
		};
	}
	return $msg;
}

1;

