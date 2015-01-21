package PEF::Front::Oauth;

use strict;
use warnings;
use URI;
use LWP::UserAgent;
use HTTP::Request::Common;
use JSON;
use PEF::Front::Config;
use PEF::Front::Session;

sub _authorization_server {
	die 'unimplemented base method';
}

sub _token_server {
	die 'unimplemented base method';
}

sub _get_user_info_request {
	die 'unimplemented base method';
}

sub _parse_user_info {
	die 'unimplemented base method';
}

sub user_info_scope {
	my ($self) = @_;
	cfg_oauth_scopes($self->{service})->{user_info};
}

sub authorization_server {
	my ($self, $scope) = @_;
	my $uri   = URI->new($self->_authorization_server);
	$self->{state}  = PEF::Front::Session::_secure_value;
	$self->{session}->data->{oauth_state}{$self->{state}} = $self->{service};
	my @scope = ();
	if (defined $scope) {
		@scope = (scope => $scope);
	}
	$uri->query_form(
		response_type => 'code',
		client_id     => cfg_oauth_client_id($self->{service}),
		state         => $self->{state},
		@scope
	);
	$uri->as_string;
}

sub exchange_code_to_token {
	my ($self, $request) = @_;
	if ($request->{code}) {
		my $token_answer;
		delete $self->{session}->data->{oauth_state};
		$self->{session}->store;
		eval {
			local $SIG{ALRM} = sub { die "timeout" };
			alarm cfg_oauth_connect_timeout();
			my $response = LWP::UserAgent->new->request->(
				POST $self->_token_server,
				[   grant_type    => 'authorization_code',
					code          => $request->{code},
					client_id     => cfg_oauth_client_id($self->{service}),
					client_secret => cfg_oauth_client_secret($self->{service})
				]
			);
			die if !$response or !$response->decoded_content;
			$token_answer = decode_json $response->decoded_content;
		};
		alarm 0;
		if ($@) {
			die {
				result => 'OAUTHERR',
				answer => 'Oauth timeout'
			} if $@ =~ /timeout/;
			print STDERR $@;
			die {
				result => 'OAUTHERR',
				answer => 'Oauth connect error'
			};
		}
		if ($token_answer->{error} || !$token_answer->{access_token}) {
			die {
				result      => 'OAUTHERR',
				answer      => 'Oauth error: $1',
				answer_args => [$token_answer->{error_description} || 'no access token']
			};
		}
		$self->{session}->load;
		$self->{session}->data->{oauth_access_token}{$self->{service}} = $token_answer->{access_token};
		$self->{session}->store;
	} else {
		my $message = $request->{error_description} || 'Internal Oauth error';
		die {
			result => 'OAUTHERR',
			answer => $message
		};
	}

}

sub get_user_info {
	my ($self) = @_;
	my $info;
	$self->{session}->store;
	eval {
		local $SIG{ALRM} = sub { die "timeout" };
		alarm cfg_oauth_connect_timeout();
		my $response = LWP::UserAgent->new->request->($self->_get_user_info_request);
		die if !$response or !$response->decoded_content;
		$info = decode_json $response->decoded_content;
	};
	alarm 0;
	if ($@) {
		die {
			result => 'OAUTHERR',
			answer => 'Oauth timeout'
		} if $@ =~ /timeout/;
		die {
			result => 'OAUTHERR',
			answer => 'Oauth connect error'
		};
	}
	if ($info->{error}) {
		die {
			result      => 'OAUTHERR',
			answer      => 'Oauth error: $1',
			answer_args => [$info->{error_description}]
		};
	}
	$self->{session}->load;
	$self->{session}->data->{oauth_info_raw}{$self->{service}} = $info;
	$self->{session}->data->{oauth_info} = [] if !$self->{session}->data->{oauth_info};
	my $oi = $self->{session}->data->{oauth_info};
	for (my $i = 0 ; $i < @$oi ; ++$i) {
		if ($oi->[$i]->{service} eq $self->{service}) {
			splice @$oi, $i, 1;
			last;
		}
	}
	my $parsed_info = $self->_parse_user_info;
	unshift @$oi, $parsed_info;
	$self->{session}->store;
	$parsed_info;
}

sub load_module {
	my ($auth_service) = @_;
	my $module = $auth_service;
	$module =~ s/[-_]([[:lower:]])/\u$1/g;
	$module = ucfirst ($module);
	my $module_file = "PEF/Front/Oauth/$module.pm";
	eval { require $module_file };
	if ($@) {
		die {
			result      => 'INTERR',
			answer      => 'Unknown oauth service $1',
			answer_args => [$auth_service]
		};
	}
	return "PEF::Front::Oauth::$module";
}

sub new {
	my ($class, $auth_service, $session) = @_;
	my $module = load_module($auth_service);
	$module->new(
		{
			session => $session,
			service => $auth_service,
		}
	);
}

1;
