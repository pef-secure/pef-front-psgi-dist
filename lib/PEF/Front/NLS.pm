package PEF::Front::NLS;
use strict;
use warnings;
use PEF::Front::Config;
use PEF::Front::Connector;
use Geo::IPfree;
use base 'Exporter';

our @EXPORT = qw{
  guess_lang
  msg_get
};

sub msg_peek {
	my ($lang, $msgid) = @_;
	my $conn  = db_connect;
	my $found = 1;
	my $id_nls_msgid;
	my $message;
	if (cfg_no_nls) {
		$message      = $msgid;
	} else {
		$conn->run(
			sub {
				($message, $id_nls_msgid) = $_->selectrow_array(
					q{
						select message, id_nls_msgid
						from nls_message join nls_msgid using (id_nls_msgid)
						where msgid = ? and short_lang = ?
					},
					undef, $msgid, $lang
				);
				if (not defined $message) {
					$found = 0;
					($id_nls_msgid) = $_->selectrow_array(
						q{
							select id_nls_msgid
						   	from nls_msgid
						   	where msgid = ?
						},
						undef, $msgid
					);
				}
				return $message;
			}
		);
	}
	return {
		message      => $message,
		found        => $found,
		msgid        => $msgid,
		id_nls_msgid => $id_nls_msgid
	};
}

sub msg_get {
	my ($lang, $msgid, @params) = @_;
	my $ret = msg_peek($lang, $msgid);
	if (not $ret->{found}) {
		if (not cfg_no_multilang_support and defined $ret->{id_nls_msgid}) {
			my ($alt_lang) = db_connect->run(
				sub {
					$_->selectrow_array(q{select alt_lang from language where short_lang = ?}, undef, $lang);
				}
			);
			$alt_lang ||= cfg_default_lang;
			$ret = msg_peek($lang, $msgid);
		}
		$ret->{message} = $msgid if not $ret->{found};
	}
	$ret->{message} =~ s/\$(\d+)/$params[$1-1]/g if @params;
	delete $ret->{id_nls_msgid};
	return $ret;
}

my $gi = Geo::IPfree->new;

sub guess_lang {
	my $request    = $_[0];
	my $cookie_ref = $request->cookies;
	my $lang       = (exists($cookie_ref->{'lang'}) ? $cookie_ref->{'lang'} : undef);
	if (cfg_no_multilang_support and not defined $lang) {
		$lang = cfg_default_lang;
	} elsif (not defined $lang) {
		my $country = lc(($gi->LookUp($ENV{'REMOTE_ADDR'}))[0]);
		if (defined $country) {
			($lang) = db_connect->run(
				sub {
					$_->selectrow_array(q{select short_lang from geo_language where country = ?}, undef, $country);
				}
			);
		}
		$lang = cfg_default_lang if not defined $lang;
	}
	return $lang;
}

1;
