package PEF::Front::_connector;

use strict;
use warnings;
use base 'DBIx::Connector';
use PEF::Front::Config;

sub _connect {
	my ($self, @args) = @_;
	for (1 .. cfg_db_reconnect_trys) {
		my $dbh = eval {$self->SUPER::_connect(@args)};
		return $dbh if $dbh;
		sleep 1;
	}
	die $@ if $@;
	die "no connect";
}

package PEF::Front::Connector;
use base 'Exporter';
use PEF::Front::Config;
use strict;
use warnings;

our @EXPORT = qw{db_connect};

our $conn;

sub db_connect {
	return $conn if defined $conn;
	my $dbname = cfg_db_name;
	my $dbuser = cfg_db_user;
	my $dbpass = cfg_db_password;
	$conn =
	  PEF::Front::_connector->new("dbi:Pg:dbname=$dbname", $dbuser, $dbpass,
		{AutoCommit => 1, PrintError => 0, AutoInactiveDestroy => 1, RaiseError => 1, pg_enable_utf8 => 1})
	  or croak {
		answer => "SQL_connect: " . DBI->errstr(),
		result => 'INTERR',
	  };
	$conn->mode('fixup');
	$conn;
}

1;
