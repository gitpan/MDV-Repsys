#!/usr/bin/perl
# $Id$

use strict;
use warnings;
use Test::More tests => 10;
use File::Temp qw(tempdir);

use_ok('MDV::Repsys');
use_ok('MDV::Repsys::Remote');

{
    my $extractdir = tempdir(CLEANUP => 1);

    ok(
        MDV::Repsys::extract_srpm(
            't/cowsay-3.03-11mdv2007.0.src.rpm',
            $extractdir
        ),
        "extract_srpm return ok"
    );
    ok(-f "$extractdir/SPECS/cowsay.spec", "rpm was really extracted");
}

{
    my $tempdata = tempdir(CLEANUP => 1);
    my $svnrepos = "$tempdata/svn";
    my $repsys = "$tempdata/repsys.conf";
    my $svnurl = "file://$svnrepos";
    { # creating data for test
        system('svnadmin', 'create', $svnrepos);
        -f "$svnrepos/format" or die "cannot create a svn repository for testing";

        my $svnc = SVN::Client->new();
        my $logurl = "$svnurl/misc";
        my $pkgurl = "$svnurl/cooker";
        $svnc->mkdir($logurl);
        $svnc->mkdir($pkgurl);
        open(my $hrep, "> $repsys");
        print $hrep <<EOF;
[global]
verbose = no
default_parent = $pkgurl

[log]
oldurl = $logurl

EOF
        close($hrep);
    }
    # Env is done, now we can test:
    my $MRR = MDV::Repsys::Remote->new(
        configfile => $repsys
    );
    isa_ok($MRR, 'MDV::Repsys::Remote');
    ok(
        $MRR->import_pkg('t/cowsay-3.03-11mdv2007.0.src.rpm'),
        'import_pkg return ok'
    );
    mkdir("$tempdata/cowsay");
    ok(
        $MRR->checkout_pkg('cowsay', "$tempdata/cowsay"),
        "checkout_pkg return ok"
    );
    ok(-f "$tempdata/cowsay/SPECS/cowsay.spec", "pkg was really checkout");
    ok(
        $MRR->get_srpm('cowsay', destdir => $tempdata),
        'get_srpm return ok'
    );
    ok(-f (glob("$tempdata/cowsay*.rpm"))[0], "rpm was really built");



}



