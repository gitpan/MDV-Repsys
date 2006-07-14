# $Id: Repsys.pm 41107 2006-07-14 13:34:55Z nanardon $

package MDV::Repsys;

use strict;
use warnings;
use SVN::Client;
use RPM4;

our $VERSION = '0.01';

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

    set_rpm_dirs($working_dir, %relative_dir);
    my $spec = RPM4::specnew($specfile, undef, '/', undef, 1, 0) or return 0;

    my $svn = SVN::Client->new();

    my %sources;
    $sources{$spec->specfile} = 1;
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


1;

__END__

=head1 AUTHORS

Olivier Thauvin <nanardon@mandriva.org>

=head1 SEE ALSO

L<Repsys::Remote>

=cut
