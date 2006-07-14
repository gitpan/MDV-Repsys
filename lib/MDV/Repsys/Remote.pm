package MDV::Repsys::Remote;

use strict;
use warnings;
use MDV::Repsys qw(sync_source extract_srpm);
use Config::IniFiles;
use SVN::Client;
use Date::Parse;
use POSIX qw(getcwd strftime);
use RPM4;
use File::Temp qw(tempdir tempfile);

our $VERSION = ('$Revision: 41107 $' =~ m/(\d+)/)[0];

=head1 NAME

MDV::Repsys::Remote

=head1 SYNOPSYS

Module to access and build rpm from a svn

=head1 FUNCTIONS

=head2 new(%options)

Create a new MDV::Repsys::Remote object

options:

=over 4

=item configfile

Use this repsys configuration file instead /etc/repsys.conf

=item nocommit

Disable commit action, usefull for testing purpose

=back

=cut

sub new {
    my ($class, %options) = @_;

    my $cfg = new Config::IniFiles(
        -file => $options{configfile} || "/etc/repsys.conf",
    );

    my $repsys = {
        config => $cfg,
        svn => SVN::Client->new(),
        nocommit => $options{nocommit},
        default => {
            pkgversion => 'current',
            revision => 'HEAD',
        },
    };

    bless($repsys, $class);
}

=head2 get_pkgurl($pkgname, %options)

Return the svn url location for package named $pkgname

=cut

sub get_pkgurl {
    my ($self, $pkgname, %options) = @_;
    sprintf(
        "%s/%s/%s",
        $self->{config}->val('global', 'default_parent') || "",
        $pkgname,
        $options{pkgversion} || $self->{default}{pkgversion},
    );
}

=head2 checkout_pkg($pkgname, $destdir, %options)

Checkout a package from svn into $destdir directory

=cut

sub checkout_pkg {
    my ($self, $pkgname, $destdir, %options) = @_;

    $destdir ||= $pkgname;

    my $revision = $self->{svn}->checkout(
        $self->get_pkgurl($pkgname, %options),
        $destdir,
        $options{revision} || $self->{default}{revision},
        1,
    );

    return $revision;
}

=head2 get_old_changelog($pkgname, $handle, %options)

Read old changelog entry from svn and write it into $handle.
If not specified, $handle is set to STDOUT.

=cut

sub get_old_changelog {
    my ($self, $pkgname, $handle, %options) = @_;
    
    $handle ||= \*STDOUT;

    eval {
    $self->{svn}->cat(
        $handle,
        sprintf(
            "%s/%s/log",
            $self->{config}->val('log', 'oldurl'),
            $pkgname,
        ),
        $options{revision} || $self->{default}{revision},
    ); };
}


sub _log_pkg {
    my ($self, $pkgname, $callback, %options) = @_;
    
    $self->{svn}->log(
        $self->get_pkgurl($pkgname, %options),
        $options{revision} || $self->{default}{revision},
        0, 0, 0,
        $callback,
    );
}

=head2 log_pkg($pkgname, $handle, %options)

Build a log from svn and print it into $handle.
If not specified, $handle is set to STDOUT.

=cut

sub log_pkg {
    my ($self, $pkgname, $handle, %options) = @_;
    $handle ||= \*STDOUT;
    $self->_log_pkg(
        $pkgname,
        sub {
            my ($changed_paths, $revision, $author, $date, $message) = @_;
            my $time = str2time($date);
            printf $handle 
                "* %s %s\n+%s (%s)\n%s\n\n",
                strftime("%a %b %d %Y", gmtime($time)),
                $self->{config}->val('users', $author, $author),
                strftime("%F %T", gmtime($time)), $revision,
                $message;
        },
        %options,
    );
}

=head2 build_final_changelog($pkgname, $handle, %options)

Build a the complete changelog for a package and print it into $handle.
If not specified, $handle is set to STDOUT.

=cut

sub build_final_changelog {
    my ($self, $pkgname, $handle, %options) = @_;

    $handle ||= \*STDOUT;

    print $handle "\n\%changelog\n";
    $self->log_pkg(
        $pkgname,
        $handle,
        %options,
    );
    $self->get_old_changelog($pkgname, $handle, %options);
}

=head2 get_final_spec($specfile, %options)

Build the final changelog for upload from $specfile.

$options{pkgname} is the package name, if not specified, it is evaluate
from the specfile.

=cut

sub get_final_spec {
    my ($self, $specfile, %options) = @_;

    my $pkgname = $options{pkgname};

    if (!$pkgname) {
        my $spec = RPM4::specnew($specfile, undef, '/', undef, 1, 0) or return;
        my $h = $spec->srcheader or return;
        $pkgname = $h->queryformat('%{NAME}');
    }

    my $dir = $options{destdir} || tempdir( CLEANUP => 1 );

    my ($basename) = $specfile =~ m!(?:.*/)?(.*)$!;

    if (open(my $sh, "<", $specfile)) {
        if (open(my $dh, ">", "$dir/$basename")) {
            while (<$sh>) {
                print $dh $_;
            }

            $self->build_final_changelog(
                $pkgname,
                $dh,
                %options,
            );
            close($dh);
        }
        close($sh);
    }
    
    return "$dir/$basename";
}

=head2 get_srpm($pkgname, %options)

Build the final src.rpm from the svn. Return the svn revision and
the src.rpm location.

=cut

sub get_srpm {
    my ($self, $pkgname, %options) = @_;

    my $tempdir = tempdir(CLEANUP => 1);

    my $revision = 0;

    $self->checkout_pkg($pkgname, $tempdir, %options) or return 0;

    $self->{svn}->status(
        $tempdir,
        $options{revision} || $self->{default}{revision},
        sub {
            my ($path, $status) = @_;
            my $entry = $status->entry() or return;
            $revision = $entry->cmt_rev if($revision < $entry->cmt_rev);
        },
        1, # recursive
        1, # get_all
        0, # update
        0, # no_ignore
    );

    MDV::Repsys::set_rpm_dirs($tempdir);
    RPM4::add_macro("_srcrpmdir " . ($options{destdir} || getcwd()));
    
    my $specfile = $self->get_final_spec(
        "$tempdir/SPECS/$pkgname.spec",
        %options,
        pkgname => $pkgname,
    );

    my $spec = RPM4::specnew($specfile, undef, '/', undef, 1, 0) or return 0;

    RPM4::setverbosity(0);
    RPM4::del_macro("_signature");
    $spec->build([ qw(PACKAGESOURCE) ]);
    return ($revision, $spec->srcrpm());

    1;
}

=head2 import_pkg($rpmfile, %options)

Import a source package into the svn.

=cut

sub import_pkg {
    my ($self, $rpmfile, %options) = @_;

    my $h = RPM4::rpm2header($rpmfile) or return 0;
    return 0 if($h->hastag('SOURCERPM'));
    my $pkgname = $h->queryformat('%{NAME}');

    my $tempdir = $options{destdir} ? $options{destdir} : tempdir(CLEANUP => 0);

    $self->{svn}->checkout(
        $self->{config}->val('global', 'default_parent') || "",
        $tempdir,
        'HEAD', # What else ??
        0, # Don't be recursive !!
    );

    my $pkgdir = "$tempdir/$pkgname";

    $self->{svn}->update(
        $pkgdir,
        'HEAD',
        0,
    );
    if (-d $pkgdir) {
        warn "$pkgname is already into svn\n";
        return 0;
        $self->{svn}->update(
            "$pkgdir/current",
            'HEAD',
            1,
        );
    } else {
        $self->{svn}->mkdir($pkgdir);
    }
    if (! -d "$pkgdir/current") {
        $self->{svn}->mkdir("$pkgdir/current");
    }

    MDV::Repsys::set_rpm_dirs("$pkgdir/current");
    MDV::Repsys::extract_srpm(
        $rpmfile,
        "$pkgdir/current",
    ) or return 0;
    
    my $specfile = "$pkgdir/current/SPECS/$pkgname.spec";
    MDV::Repsys::set_rpm_dirs("$pkgdir/current");
    MDV::Repsys::sync_source("$pkgdir/current", $specfile);

    $self->splitchangelog(
        $specfile, 
        %options,
        pkgname => $pkgname,
    );
   
    my $message = $options{message} || "Import $pkgname";
    $self->{svn}->log_msg(
        sub {
            $_[0] = \$message;
            return 0;
        }
    );
    print "Commiting $pkgname\n";
    $self->{svn}->commit($tempdir, 0) unless($self->{nocommit});
    $self->{svn}->log_msg(undef);

    1;
}

=head2 splitchangelog($specfile, %options)

Strip the changelog from a specfile and commit it into the svn.

=cut

sub splitchangelog {
    my ($self, $specfile, %options) = @_;

    my ($basename) = $specfile =~ m!(?:.*/)?(.*)$!;
    
    my $pkgname = $options{pkgname};

    if (!$pkgname) {
        my $spec = RPM4::specnew($specfile, undef, '/', undef, 1, 0) or return 0;
        my $h = $spec->srcheader or return 0;
        $pkgname = $h->queryformat('%{NAME}');
    }

    my $changelog = '';
    my $newspec = new File::Temp(
        TEMPLATE => "$ENV{TMPDIR}/basename.XXXXXX",
        UNLINK => 1
    );

    if (open(my $oldsfh, "<", $specfile)) {
        my $ischangelog = 0;
        while(my $line = <$oldsfh>) {
            $line =~ /^%changelog/ and $ischangelog = 1;
            $line =~ /^%(files|build|check|prep|post|pre|package)/ and $ischangelog = 0;
            if ($ischangelog) {
                $changelog .= $line;
            } else {
                print $newspec $line;
            }
        }
        close($oldsfh);
    }

    if (!$changelog) {
        return 1;
    }

    my $tempdir = tempdir( CLEANUP => 1 );
    my $resyslog = $self->{config}->val('log', 'oldurl');
    if ($resyslog) {
        my $oldchangelogurl = "$resyslog/$pkgname";
        $self->{svn}->checkout(
            $resyslog,
            $tempdir,
            'HEAD',
            0,
        );
        $self->{svn}->update(
            "$tempdir/$pkgname",
            'HEAD',
            1
        );
        if (! -d "$tempdir/$pkgname") {
            $self->{svn}->mkdir("$tempdir/$pkgname");
        }
        if (-f "$tempdir/$pkgname/log") {
            die "File log exists";
        }
        if (open(my $logh, ">", "$tempdir/$pkgname/log")) {
            print $logh $changelog;
            close($logh);
        }
        $self->{svn}->add("$tempdir/$pkgname/log", 0);
        my $message = $options{message} || "import old changelog for $pkgname";
        $self->{svn}->log_msg(sub {
            $_[0] = \$message;
            return 0;
        });
        print "Commiting $pkgname/log\n";
        $self->{svn}->commit($tempdir, 0) unless($self->{nocommit});
        $self->{svn}->log_msg(undef);
    }

    seek($newspec, 0, 0);
    if (open(my $oldspec, ">", $specfile)) {
        while (<$newspec>) {
            print $oldspec $_;
        }
        close($oldspec);
    }
}

sub _check_url_exists {
    my ($self, $url, %options) = @_;
    my ($parent, $leaf) = $url =~ m!(.*)?/+([^/]*)/*$!;
    print "$parent $leaf\n";

    my $leafs = $self->{svn}->ls(
        $parent, 
        $options{revision} || $self->{default}{revision},
        0,
    );
    exists($leafs->{$leaf})
}

=head2 tag_pkg($pkgname, %options)

TAG a package into the svn, aka copy the current tree into
VERSION/RELEASE/. The operation is done directly into the svn.

=cut

sub tag_pkg {
    my ($self, $pkgname, %options) = @_;

    my ($handle, $tempspecfile) = tempfile();

    $self->{svn}->cat(
        $handle,
        $self->get_pkgurl($pkgname) . "/SPECS/$pkgname.spec",
        $options{revision} || $self->{default}{revision},
    );

    close($handle);

    my $spec = RPM4::specnew($tempspecfile, undef, '/', undef, 1, 1) or return 0;
    my $header = $spec->srcheader or return 0;

    my $ev = $header->queryformat('%|EPOCH?{%{EPOCH}:}:{}|%{VERSION}');
    my $re = $header->queryformat('%{RELEASE}');

    my $tagurl = $self->get_pkgurl($pkgname, pkgversion => 'releases');

    if (!$self->_check_url_exists($tagurl)) {
        $self->{svn}->mkdir($tagurl);
    }

    if (!$self->_check_url_exists("$tagurl/$ev")) {
        $self->{svn}->mkdir("$tagurl/$ev");
    }

    if ($self->_check_url_exists("$tagurl/$ev/$re")) {
        warn "$tagurl/$ev/$re already exists\n";
        return 0;
    }

    my $message = "$ev-$re";
    $self->{svn}->log_msg(
        sub {
            $_[0] = \$message;
            return 0;
        }
    );
    $self->{svn}->copy(
        $self->get_pkgurl($pkgname),
        $options{revision} || $self->{default}{revision},
        "$tagurl/$ev/$re",
    );
    $self->{svn}->log_msg(undef);
 
    1;    
}

1;

__END__

=head1 FUNCTIONS OPTIONS

=over 4

=item revision

Work on this revision into the svn

=item destdir

Extract files into this directories instead a temporary directory.

=back

=head1 AUTHORS

Olivier Thauvin <nanardon@mandriva.org>

=head1 SEE ALSO

L<Repsys>

=cut
