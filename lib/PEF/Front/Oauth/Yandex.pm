package PEF::Front::Oauth::Yandex;

use strict;
use warnings;
use base 'PEF::Front::Oauth';
use HTTP::Request::Common;

sub _authorization_server {
	'https://oauth.yandex.ru/authorize';
}

sub _token_server {
	'https://oauth.yandex.ru/token';
}

sub _get_user_info_request {
	my ($self) = @_;
	my $req = GET 'https://login.yandex.ru/info';
	$req->query_form(
		format      => 'json',
		oauth_token => $self->{session}->data->{oauth_access_token}{$self->{service}}
	);
	$req;
}

sub new {
	my ($class, $self) = @_;
	bless $self, $class;
}

1;
