# $Id: Repsys.pm 42296 2006-07-27 13:42:32Z nanardon $

package MDV::Repsys;

use strict;
use warnings;
use SVN::Client;
use RPM4;
use POSIX qw(getcwd);

our $VERSION = '0.04';

my $error = undef;
my $verbosity = 0;

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

=head2 set_verbosity($level)

Set the verbosity verbosity of the module:

  0 silent
  1 progress message
  2 debug message

=cut

sub set_verbosity {
    my ($level) = @_;
    $verbosity = $level || 0;
}

sub _print_msg {
    my ($level, $fmt, @args) = @_;
    return if ($level > $verbosity);
    printf("$fmt\n", @args);
}

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
        my $dtc = RPM4::expand('%' . $m); # dir to create
        if (! -d RPM4::expand($dtc)) {
            if (!mkdir RPM4::expand($dtc)) {
                $error = "can't create $dtc: $!";
                return 0;
            }
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
    my $spec = RPM4::specnew($specfile, undef, '/', undef, 1, 0) or do {
        $error = "Can't read specfile";
        return;
    };

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
        _print_msg(1, "Adding %s", $toadd);
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
                grep { $entry eq $_ } (
                    RPM4::expand('%_specdir'),
                    RPM4::expand('%_sourcedir')
                    ) and return;

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
        _print_msg(1, "Adding %s", $toadd);
        $svn->add($toadd, 0);
    }
    foreach my $todel (sort @needdel) {
        _print_msg(1, "Removing %s", $todel);
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
    ) or do {
        $error = $!;
        return;
    };

    if (open(my $oldsfh, "<", $specfile)) {
        my $ischangelog = 0;
        while(my $line = <$oldsfh>) {
            if ($line =~ /^%changelog/) {
                $ischangelog = 1;
                next;
            }
            if ($line =~ /^%(files|build|check|prep|post|pre|package|description)/) {
                $ischangelog = 0;
            }
            if ($ischangelog) {
                $changelog .= $line;
            } else {
                print $newspec $line;
            }
        }
        close($oldsfh);
    } else {
        $error = "Can't open $specfile: $!";
        return;
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
        $error = "can't open $specfile: $!";
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
    if (!$specfile) {
        $error = "Can't find specfile";
        return;
    }

    RPM4::del_macro("_signature"); # don't bother
    my $spec = RPM4::specnew(
        $specfile, undef, 
        $options{root} || '/',
        undef, 0, 0) or do {
        $error = "Can't read specfile $specfile";
        return;
    };

    if (! $options{nodeps}) {
        my $db = RPM4::newdb();
        my $sh = $spec->srcheader();
        $db->transadd($sh, "", 0);
        $db->transcheck;
        my $pbs = $db->transpbs();
     
        if ($pbs) {
            $pbs->init;
            $error = "\nFailed dependancies:\n";
            while($pbs->hasnext) {
                $error .= "\t" . $pbs->problem() . "\n";
            }
            return;
        }
    }

    my @bflags = ();
    my %results = ();
    
    if ($what =~ /b/) {
        push(@bflags, qw(PREP BUILD INSTALL CHECK FILECHECK PACKAGEBINARY));
        if (!-d RPM4::expand('%_rpmdir')) {
            mkdir RPM4::expand('%_rpmdir') or do {
                $error = "Can't create " . RPM4::expand('%_rpmdir') . ": $!";
                return;
            };
        }
        foreach my $rpm ($spec->binrpm) {
            push(@{$results{bin}}, $rpm);
            my ($dirname) = $rpm =~ m:(.*)/:;
            if (! -d $dirname) {
                mkdir $dirname or do {
                    $error = "Can't create $dirname: $!";
                    return;
               }; 
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
                mkdir $dirname or do {
                    $error = "Can't create $dirname: $!";
                    return;
                };
            }
        }
    }

    $spec->build([ @bflags ]) and return;

    return %results;
}

sub repsys_error {
    $error
}

1;

__END__

=head1 AUTHORS

Olivier Thauvin <nanardon@mandriva.org>

=head1 SEE ALSO

L<Repsys::Remote>

=cut
