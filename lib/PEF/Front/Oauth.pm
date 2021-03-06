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

sub _token_request {
	die 'unimplemented base method';
}

sub _get_user_info_request {
	die 'unimplemented base method';
}

sub _parse_user_info {
	die 'unimplemented base method';
}

sub _required_redirect_uri { 0 }
sub _required_state        { 1 }
sub _returns_state         { 1 }

sub _decode_token {
	decode_json($_[1]);
}

sub user_info_scope {
	my ($self) = @_;
	cfg_oauth_scopes($self->{service})->{user_info};
}

sub authorization_server {
	my ($self, $scope, $redirect_uri) = @_;
	my $uri = URI->new($self->_authorization_server);
	$self->{state} = PEF::Front::Session::_secure_value;
	$self->{session}->data->{oauth_state}{$self->{state}} = $self->{service};
	my @extra = ();
	if (defined $scope) {
		@extra = (scope => $scope);
	}
	if (defined $redirect_uri) {
		my $uri = URI->new($redirect_uri);
		$uri->query_form($uri->query_form, state => $self->{state}) unless $self->_returns_state;
		push @extra, (redirect_uri => $uri->as_string);
		$self->{session}->data->{oauth_redirect_uri}{$self->{service}} = $uri->as_string;
	} elsif ($self->_required_redirect_uri) {
		die {
			result      => 'OAUTHERR',
			answer      => 'Oauth $1 requires redirect_uri',
			answer_args => [$self->{service}]
		};
	}
	push @extra, (state => $self->{state}) if $self->_required_state;
	$uri->query_form(
		response_type => 'code',
		client_id     => cfg_oauth_client_id($self->{service}),
		@extra
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
			my $request  = $self->_token_request($request->{code});
			my $response = LWP::UserAgent->new->request($request);
			die if !$response or !$response->decoded_content;
			$token_answer = $self->_decode_token($response->decoded_content);
		};
		my $exception = $@;
		delete $self->{session}->data->{oauth_redirect_uri}{$self->{service}};
		alarm 0;
		if ($exception) {
			$self->{session}->data->{oauth_error} = $exception;
			die {
				result => 'OAUTHERR',
				answer => 'Oauth timeout'
			} if $exception =~ /timeout/;
			die {
				result => 'OAUTHERR',
				answer => 'Oauth connect error'
			};
		}
		if ($token_answer->{error} || !$token_answer->{access_token}) {
			$self->{session}->data->{oauth_error} =
			  $token_answer->{error_description} || $token_answer->{error} || 'no access token';
			die {
				result      => 'OAUTHERR',
				answer      => 'Oauth error: $1',
				answer_args => [$self->{session}->data->{oauth_error}]
			};
		}
		$self->{session}->load;
		delete $self->{session}->data->{oauth_error};
		$self->{session}->data->{oauth_access_token}{$self->{service}} = $token_answer->{access_token};
		$self->{session}->store;
	} else {
		my $message = $request->{error_description} || $request->{error} || 'Internal Oauth error';
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
		my $response = LWP::UserAgent->new->request($self->_get_user_info_request);
		die if !$response or !$response->decoded_content;
		$info = decode_json $response->decoded_content;
	};
	alarm 0;
	if ($@) {
		$self->{session}->data->{oauth_error} = $@;
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
		$self->{session}->data->{oauth_error} = $info->{error_description} || $info->{error};
		die {
			result      => 'OAUTHERR',
			answer      => 'Oauth error: $1',
			answer_args => [$self->{session}->data->{oauth_error}]
		};
	}
	$self->{session}->load;
	delete $self->{session}->data->{oauth_error};
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
	$parsed_info->{service} = $self->{service};
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
	$auth_service =~ tr/-/_/;
	$module->new(
		{   session => $session,
			service => $auth_service,
		}
	);
}

1;
