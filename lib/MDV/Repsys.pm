# $Id: Repsys.pm 41332 2006-07-15 20:45:19Z nanardon $

package MDV::Repsys;

use strict;
use warnings;
use SVN::Client;
use RPM4;
use POSIX qw(getcwd);

our $VERSION = '0.02';

=head1 NAME

MDV::Repsys

=head1 SYNOPSYS

Module to build rpm from a svn

=head1 FUNCTIONS

=cut

my %b_macros = (
    '_sourcedir' => 'SOURCES',
    '_patchdir' => 'SOURCES',
    '_specdir' => 'SPECS',
);

=head2 set_rpm_dirs($dir)

Set internals rpm macros that are used by rpm building functions:

  _sourcedir to $dir/SOURCES
  _patchdir  to $dir/SOURCES
  _specdir   to $dir/SPECS

=cut

sub set_rpm_dirs {
    my ($dir, %relative_dir) = @_;
    if ($dir !~ m:^/:) {
        $dir = getcwd() . "/$dir";
    }
    foreach my $m (keys %b_macros, keys %relative_dir) {
        RPM4::add_macro(
            sprintf(
                '%s %s/%s', 
                $m, $dir, 
                (defined($relative_dir{$m}) ? $relative_dir{$m} : $b_macros{$m}) || '',
            ),
        );
    }
}

=head2 create_rpm_dirs

Create directories used by rpm building functions:

  _sourcedir
  _patchdir
  _specdir

Return 1 on sucess, 0 on failure.

=cut

sub create_rpm_dirs {
    foreach my $m (keys %b_macros) {
        if (! -d RPM4::expand('%' . $m)) {
            mkdir RPM4::expand('%' . $m) or return 0;
        }
    }
    1;
}

=head2 extract_srpm($rpmfile, $directory)

Extract (install) a source package into $directory.

=cut

sub extract_srpm {
    my ($rpmfile, $working_dir, %releative_dir) = @_;

    set_rpm_dirs($working_dir, %releative_dir);
    create_rpm_dirs() or return 0;
    RPM4::installsrpm($rpmfile);
}

=head2 sync_source($workingdir, $specfile)

Synchronize svn content by performing add/remove on file need to build
the package. $workingdir should a svn directory. No changes are applied
to the repository, you have to commit yourself after.

Return 1 on success, 0 on error.

=cut

sub sync_source {
    my ($working_dir, $specfile, %relative_dir) = @_;

    if ($working_dir !~ m:^/:) {
        $working_dir = getcwd() . "/$working_dir";
    }

    set_rpm_dirs($working_dir, %relative_dir);
    my $spec = RPM4::specnew($specfile, undef, '/', undef, 1, 0) or return 0;

    my $svn = SVN::Client->new();

    my %sources;
    my $abs_spec = $spec->specfile;
    if ($abs_spec !~ m:^/:) {
        $abs_spec = getcwd() . "/$abs_spec";
    }
    $sources{$abs_spec} = 1;
    $sources{$_} = 1 foreach (map { RPM4::expand("\%_sourcedir/$_") } $spec->sources);
    eval {
        $sources{$_} = 1 foreach (map { RPM4::expand("\%_sourcedir/$_") } $spec->icon);
    };

    my @needadd;
    $svn->status(
        $working_dir,
        'HEAD',
        sub {
            my ($entry, $status) = @_;
            if ($status->text_status eq '2') {
                if (grep { $entry eq $_ } (RPM4::expand('%_specdir'), RPM4::expand('%_sourcedir'))) {
                    push(@needadd, $entry);
                }
            }
        },
        0,
        1,
        0,
        0,
    );

    foreach my $toadd (@needadd) {
        print "Adding $toadd\n";
        $svn->add($toadd, 0);
    }
    @needadd = ();
    my @needdel;

    foreach my $dir (RPM4::expand('%_specdir'), RPM4::expand('%_sourcedir')) {
            $svn->status(
            $dir,
            'HEAD',
            sub {
                my ($entry, $status) = @_;
                grep { $entry eq $_ } (RPM4::expand('%_specdir'), RPM4::expand('%_sourcedir')) and return;
                if ($status->text_status eq '2') {
                    if ($sources{$entry}) {
                        push(@needadd, $entry);
                    }
                }
                if ($status->text_status eq '4' || $status->text_status eq '3') {
                    if(!$sources{$entry}) {
                        push(@needdel, $entry);
                    }
                }
            },
            0,
            1,
            0,
            1,
        );

    }

    foreach my $toadd (sort @needadd) {
        print "Adding $toadd\n";
        $svn->add($toadd, 0);
    }
    foreach my $todel (sort @needdel) {
        print "Delete $todel\n";
        $svn->delete($todel, 1);
    }
    1;
}

sub _strip_changelog {
    my ($specfile) = @_;

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

    return($changelog, $newspec);
}

=head2 strip_changelog($specfile)

Remove the %changelog section from the specfile.

=cut

sub strip_changelog {
    my ($specfile) = @_;
    
    my ($changelog, $newspec) = _strip_changelog($specfile);

    $changelog or return 1;

    seek($newspec, 0, 0);
    if (open(my $oldspec, ">", $specfile)) {
        while (<$newspec>) {
            print $oldspec $_;
        }
        close($oldspec);
    } else {
        return;
    }

    1;
}

=head2 build($dir, $what, %options)

Build package locate in $dir. The type of packages to build is
set in the string $what: b for binaries, s for source.

If $options{specfile} is set, the build is done from this specfile
and not the one contains in SPECS/ directory.

=cut

sub build {
    my ($working_dir, $what, %options) = @_;

    set_rpm_dirs(
        $working_dir,
        $options{destdir} ?
            (
                _rpmdir => 'RPMS',
                _srcrpmdir => 'SRPMS',
            ) : ()
    );

    my $specfile = $options{specfile} || (glob(RPM4::expand('%_specdir/*.spec')))[0];
    $specfile or return;

    RPM4::del_macro("_signature");
    my $spec = RPM4::specnew($specfile, undef, '/', undef, 0, 0) or return;

    if (! $options{nodeps}) {
        my $db = RPM4::newdb();
        my $sh = $spec->srcheader();
        $db->transadd($sh, "", 0);
        $db->transcheck;
        my $pbs = $db->transpbs();
     
        if ($pbs) {
            $pbs->init;
            print "\nMissing dependancies:\n";
            while($pbs->hasnext) {
                print "\t" . $pbs->problem() . "\n";
            }
            return;
        }
    }

    my @bflags = ();
    my %results = ();
    
    if ($what =~ /b/) {
        push(@bflags, qw(PREP BUILD INSTALL CHECK FILECHECK PACKAGEBINARY));
        if (!-d RPM4::expand('%_rpmdir')) {
            mkdir RPM4::expand('%_rpmdir') or return;
        }
        foreach my $rpm ($spec->binrpm) {
            push(@{$results{bin}}, $rpm);
            my ($dirname) = $rpm =~ m:(.*)/:;
            if (! -d $dirname) {
                mkdir $dirname or return; 
            }
        }
    }
    if ($what =~ /s/) {
        push(@bflags, qw(PACKAGESOURCE));
        if (!-d RPM4::expand('%_srcrpmdir')) {
            mkdir RPM4::expand('%_srcrpmdir') or return;
        }
        foreach my $rpm ($spec->srcrpm) {
            push(@{$results{src}}, $rpm);
            my ($dirname) = $rpm =~ m:(.*)/:;
            if (! -d $dirname) {
                mkdir $dirname or return;
            }
        }
    }

    $spec->build([ @bflags ]) and return;

    return %results;
}

1;

__END__

=head1 AUTHORS

Olivier Thauvin <nanardon@mandriva.org>

=head1 SEE ALSO

L<Repsys::Remote>

=cut
