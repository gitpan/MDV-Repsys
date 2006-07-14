# $Id: Makefile.PL 38877 2006-07-12 12:16:51Z nanardon $

use 5.008;
use strict;
use ExtUtils::MakeMaker;

# where to find the rpm utility
my $rpm_path = $ENV{RPM_PATH}; # this overrides
unless (defined $rpm_path) {
    for (qw(/bin/rpm /usr/bin/rpm)) {
	if (-x) {
	    $rpm_path = $_;
	    last;
	}
    }
}

sub MY::postamble {
    <<MAKE;
.PHONY: ChangeLog rpmdist srpm rpm

ChangeLog:
	svn2cl -o ChangeLog --accum
	rm -f *.bak

rpmdist: dist
	bzme -F MDV-Repsys-*.tar.gz

srpm: rpmdist
	rpmbuild -bs --clean --rmsource perl-MDV-Repsys.spec --define "_sourcedir `pwd`"

rpm: rpmdist
	rpmbuild --define "_sourcedir `pwd`" -ba --clean --rmsource perl-MDV-Repsys.spec
MAKE
}

WriteMakefile(
    NAME	 => 'MDV::Repsys',
    VERSION_FROM => 'lib/MDV/Repsys.pm',
    EXE_FILES => [ qw(bin/mdvsys) ],
);
