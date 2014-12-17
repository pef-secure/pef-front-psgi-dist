#!/usr/bin/perl
use DBIx::Connector;
use Locale::PO;
use JSON;
use Encode;

my $dbuser = ((getpwuid $>)[0]);
my $dbname = $dbuser;
my $dbpass = "";
my $conn;
my $fname;
my $language;

for (my $i = 0 ; $i < @ARGV ; ++$i) {
	if ($ARGV[$i] =~ /^-/) {
		$ARGV[$i] =~ /^-dbname/ && do {
			$dbname = $ARGV[$i + 1];
			++$i;
		};
		$ARGV[$i] =~ /^-dbuser/ && do {
			$dbuser = $ARGV[$i + 1];
			++$i;
		};
		$ARGV[$i] =~ /^-dbpass/ && do {
			$dbpass = $ARGV[$i + 1];
			++$i;
		};
	} else {
		$fname = $ARGV[$i];
	}
}

die <<USAGE if not $fname;
import-po.pl [options] filename
  -dbname  full dsn or PostreSQL db name
  -dbuser  db user
  -dbpass  db password
USAGE

sub db_connect {
	$dbname = "dbi:Pg:dbname=$dbname" if $dbname !~ /^dbi:/;
	$conn = DBIx::Connector->new(
		$dbname, $dbuser, $dbpass,
		{   AutoCommit          => 1,
			PrintError          => 0,
			AutoInactiveDestroy => 1,
			RaiseError          => 1,
			pg_enable_utf8      => 1
		}
	) or die "SQL_connect: " . DBI->errstr();
	$conn->mode('fixup');
	$conn;
}

my $aref = Locale::PO->load_file_asarray($fname, "UTF-8");

if (Locale::PO->dequote($aref->[0]->msgid) ne '') {
	die "unknown PO-file format $fname";
}

my $header       = Locale::PO->dequote($aref->[0]->msgstr);
my %header_lines = map {
	my ($h, $v) = split /:/, $_, 2;
	$v =~ s/^\s+//;
	($h => $v)
} split /\\n/, $header;

$language = $header_lines{Language}
  or die "no Language header in PO-file $fname";

db_connect;
my $nls_lang = $conn->run(
	sub {
		$_->selectrow_hashref('select * from nls_lang where name = ?', undef,
			$language);
	}
) or die "unknown nls_lang";

my $inserted = 0;
my $updated  = 0;

for my $msg (@$aref) {
	next if Locale::PO->dequote($msg->msgid) eq '';
	my $nls_msgid = $conn->run(
		sub {
			$_->selectrow_hashref('select * from nls_msgid where msgid = ?',
				undef, Locale::PO->dequote($msg->msgid));
		}
	);
	my $msgctxt = $msg->msgctxt;
	$msgctxt = Locale::PO->dequote($msgctxt) if defined $msgctxt;
	if (!$nls_msgid) {
		$nls_msgid = $conn->run(
			sub {
				$_->do('insert into nls_msgid (msgid, context) values(?, ?)',
					undef, Locale::PO->dequote($msg->msgid), $msgctxt);
				$_->selectrow_hashref('select * from nls_msgid where msgid = ?',
					undef, Locale::PO->dequote($msg->msgid));
			}
		);
	}
	my $nls_message = $conn->run(
		sub {
			$_->selectrow_hashref(
				'select * from nls_message where id_nls_msgid = ? and short = ?',
				undef, $nls_msgid->{id_nls_msgid},
				$nls_lang->{short}
			);
		}
	);

	my $msgstr;
	if ($msg->msgstr) {
		$msgstr = [Locale::PO->dequote($msg->msgstr)];
	} elsif ($msg->msgstr_n && %{$msg->msgstr_n}) {
		my $hrf = $msg->msgstr_n;
		$msgstr = [];
		my %msgh = %{$msg->msgstr_n};
		for my $km (keys %msgh) {
			$msgstr->[$km] = Locale::PO->dequote($msgh{$km});
		}
	}
	if (@$msgstr > 1 || $msgstr->[0] ne '') {
		if ($nls_message) {
			if (encode_json($msgstr) ne $nls_message->{message_json}) {
				$conn->run(
					sub {
						$_->do(
							'update nls_message set message_json = ? where id_nls_msgid = ? and short = ?',
							undef, decode_utf8(encode_json($msgstr)), $nls_msgid->{id_nls_msgid}, $nls_lang->{short}
						);
					}
				);
				++$updated;
			}
		} else {
			$conn->run(
				sub {
					$_->do(
						'insert into nls_message (id_nls_msgid, short, message_json) values(?, ?, ?)',
						undef, $nls_msgid->{id_nls_msgid},
						$nls_lang->{short}, encode_json($msgstr)
					);
				}
			);
			++$inserted;
		}
	}
}

print
  "Updated $language; updated $updated records; inserted $inserted new records\n";
