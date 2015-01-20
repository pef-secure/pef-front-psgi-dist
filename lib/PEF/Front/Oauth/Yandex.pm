package PEF::Front::Oauth::Yandex;

use strict;
use warnings;
use base 'PEF::Front::Oauth';
use HTTP::Request::Common;
use feature 'state';

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

sub _parse_user_info {
	my ($self) = @_;
	state $sizes = [
		qw{
		  islands-small
		  islands-34
		  islands-middle
		  islands-50
		  islands-retina-small
		  islands-68
		  islands-75
		  islands-retina-middle
		  islands-retina-50
		  islands-200
		  }
	];
	my $info = $self->{session}->data->{oauth_info_raw}{$self->{service}};
	my @avatar;
	if ($info->{default_avatar_id}) {
		for my $size (@$sizes) {
			push @avatar,
			  { url  => "https://avatars.yandex.net/get-yapic/$info->{default_avatar_id}/$size",
				size => $size
			  };
		}
	}
	my $name = $info->{display_name} || $info->{real_name};
	return {
		name   => $name,
		email  => $info->{default_email},
		login  => $info->{login},
		avatar => \@avatar,
	};
}

sub new {
	my ($class, $self) = @_;
	bless $self, $class;
}

1;
