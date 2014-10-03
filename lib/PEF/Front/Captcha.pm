package PEF::Front::Captcha;

use strict;
use warnings;
use PEF::Front::Config;
use PEF::Front::SecureCaptcha;

sub make_captcha {
	my $req     = $_[0];
	my $captcha = PEF::Front::SecureCaptcha->new(
		width  => $req->{width},
		height => $req->{height},
	);
	my $md5sum = $captcha->generate_code($req->{size});
	return $md5sum;
}

sub check_captcha {
	my ($input, $md5sum) = @_;
	my $captcha = PEF::SecureCaptcha->new();
	return $captcha->check_code($input, $md5sum) == 1;
}

1;
