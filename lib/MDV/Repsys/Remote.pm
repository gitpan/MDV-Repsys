package MDV::Repsys::Remote;

use strict;
use warnings;
use Carp;
use MDV::Repsys qw(sync_source extract_srpm);
use Config::IniFiles;
use SVN::Client;
use Date::Parse;
use Date::Format;
use POSIX qw(getcwd);
use RPM4;
use File::Temp qw(tempdir tempfile);

our $VERSION = ('$Revision: 42290 $' =~ m/(\d+)/)[0];

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
        error => undef,
    };

    bless($repsys, $class);
    $repsys->set_verbosity(0);

    $repsys
}

=head2 last_error

Return the last error message after a failure.

=cut

sub last_error {
    return $_[0]->{error};
}

=head2 set_verbosity($level)

Set the verbosity verbosity of the module:

  0 silent
  1 progress message
  2 debug message

=cut

sub set_verbosity {
    my ($self, $level) = @_;
    $self->{verbosity} = $level || 0;
    # not 0 ? (INFO, DEBUG) : ERROR
    RPM4::setverbosity($level ? $level + 5 : 3);
} 

sub _print_msg {
    my ($self, $level, $fmt, @args);
    $fmt or croak "No message given";
    $level > 0 or croak "message cannot be < 1 ($level)";
    return if $level > $self->{verbosity};
    printf("$fmt\n", @args);
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

    my $revision;
    eval {
        $revision = $self->{svn}->checkout(
            $self->get_pkgurl($pkgname, %options),
            $destdir,
            $options{revision} || $self->{default}{revision},
            1,
        );
    };
    if ($@) {
        $self->{error} = "Can't checkout $pkgname: $@";
        return;
    }

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
        ); 
    };
    if ($@) {
        $self->{error} = "Can't get old changelog for $pkgname: $@";
        return;
    }
    return 1;
}

sub _old_log_pkg {
    my ($self, $pkgname, %options) = @_;

    my $templog = File::Temp->new(UNLINK => 1);

    $self->get_old_changelog($pkgname, $templog, %options) or return;

    my @cl;

    seek($templog, 0, 0);

    while(my $line = <$templog>) {
        chomp($line);
        $line or next;
        $line =~ /^%changelog/ and next;
        if ($line =~ /^\* (\w+\s+\w+\s+\d+\s+\d+)\s+(.*)/) {
            push(
                @cl,
                {
                    'time' => str2time($1, 'UTC'),
                    author => $2,
                    text => '',
                }
            );
        } else {
            $cl[-1]->{text} .= "$line\n";
        }
    }

    @cl;
}

sub _log_pkg {
    my ($self, $pkgname, %options) = @_;
    
    my @cl;

    my $callback = sub {
        my ($changed_paths, $revision, $author, $date, $message) = @_;
        push(
            @cl, 
            {
                revision => $revision,
                author => $self->{config}->val('users', $author, $author),
                'time' => str2time($date),
                text => "$message\n",
            }
        );
    };

    eval {
        $self->{svn}->log(
            $self->get_pkgurl($pkgname, %options),
            $options{revision} || $self->{default}{revision},
            0, 0, 0,
            $callback,
        );
    };
    if ($@) {
        $self->{error} = "Can't get svn log: $@";
        return;
    }

    @cl
}

sub _fmt_cl_entry {
    my ($cl) = @_;
    my @gti = gmtime($cl->{'time'});
    sprintf
        "* %s %s\n%s%s\n",
        #  date
        #     author
        #         svn date + rev
        #           message
        strftime("%a %b %d %Y", @gti), # date
        $cl->{author},                 # author
        ($cl->{revision} ? 
            sprintf(
                "+ %s (%s)\n",
                #  svn date
                #      revision
                strftime("%x %T", @gti),   # svn date
                $cl->{revision},           # revision
            ) : ''
        ),                             # svn date + rev
        $cl->{text};                   # message
}

=head2 log_pkg($pkgname, $handle, %options)

Build a log from svn and print it into $handle.
If not specified, $handle is set to STDOUT.

=cut

sub log_pkg {
    my ($self, $pkgname, $handle, %options) = @_;
    $handle ||= \*STDOUT;
    foreach my $cl ($self->_log_pkg($pkgname, %options)) {
            print $handle _fmt_cl_entry($cl);
    }
    1;
}

=head2 build_final_changelog($pkgname, $handle, %options)

Build a the complete changelog for a package and print it into $handle.
If not specified, $handle is set to STDOUT.

=cut

sub build_final_changelog {
    my ($self, $pkgname, $handle, %options) = @_;

    $handle ||= \*STDOUT;

    my @cls = $self->_log_pkg($pkgname, %options) or return 0;
    push(@cls, $self->_old_log_pkg($pkgname, %options));
 
    print $handle "\%changelog\n";

    foreach my $cl (sort { $b->{'time'} <=> $a->{'time'} } grep { $_ } @cls) {
        print $handle _fmt_cl_entry($cl);
    }
    1;
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
        my $spec = RPM4::specnew($specfile, undef, '/', undef, 1, 0) or do {
            $self->{error} = "Can't parse specfile $specfile";
            return;
        };
        my $h = $spec->srcheader or return; # can't happend
        $pkgname = $h->queryformat('%{NAME}');
    }

    my $dir = $options{destdir} || tempdir( CLEANUP => 1 );

    my ($basename) = $specfile =~ m!(?:.*/)?(.*)$!;

    if (open(my $sh, "<", $specfile)) {
        if (open(my $dh, ">", "$dir/$basename")) {
            while (<$sh>) {
                print $dh $_;
            }

            print $dh "\n";
            $self->build_final_changelog(
                $pkgname,
                $dh,
                %options,
            ) or return;
            close($dh);
        } else {
            $self->{error} = "Can't open temporary file for writing: $!";
            return;
        }
        close($sh);
    } else {
        $self->{error} = "Can't open $specfile for reading: $!";
        return;
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

    eval {
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
    };
    if ($@) {
        $self->{error} = "can't get status of $tempdir: $@";
        return;
    }

    MDV::Repsys::set_rpm_dirs($tempdir);
    RPM4::add_macro("_srcrpmdir " . ($options{destdir} || getcwd()));
    
    my $specfile = $self->get_final_spec(
        "$tempdir/SPECS/$pkgname.spec",
        %options,
        pkgname => $pkgname,
    );

    my $spec = RPM4::specnew($specfile, undef, '/', undef, 1, 0) or do {
        $self->{error} = "Can't parse specfile $specfile";
        return 0;
    };

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

    my $h = RPM4::rpm2header($rpmfile) or do {
        $self->{error} = "Can't read rpm file $rpmfile";
        return 0;
    };
    if($h->hastag('SOURCERPM')) {
        $self->{error} = "$rpmfile is not a source package";
        return;
    }
    my $pkgname = $h->queryformat('%{NAME}');

    my $tempdir = $options{destdir} ? $options{destdir} : tempdir(CLEANUP => 0);

    eval {
        $self->{svn}->checkout(
            $self->{config}->val('global', 'default_parent') || "",
            $tempdir,
            'HEAD', # What else ??
            0, # Don't be recursive !!
        );
    };
    if ($@) {
        $self->{error} = "Can't checkout " . $self->{config}->val('global', 'default_parent') . ": $@";
        return;
    }

    my $pkgdir = "$tempdir/$pkgname";

    $self->{svn}->update(
        $pkgdir,
        'HEAD',
        0,
    );
    if (-d $pkgdir) {
        $self->{error} = "$pkgname is already inside svn\n";
        return;
    } else {
        $self->{svn}->mkdir($pkgdir);
    }
    if (! -d "$pkgdir/current") {
        $self->{svn}->mkdir("$pkgdir/current");
    }

    MDV::Repsys::set_rpm_dirs("$pkgdir/current");
    my ($specfile, $cookie) =  MDV::Repsys::extract_srpm(
        $rpmfile,
        "$pkgdir/current",
    ) or do {
        $self->{error} = MDV::Repsys::repsys_error();
        return 0;
    };
    
    MDV::Repsys::set_rpm_dirs("$pkgdir/current");
    MDV::Repsys::sync_source("$pkgdir/current", $specfile) or do {
        $self->{error} = MDV::Repsys::repsys_error();
        return;
    };

    return if(!$self->splitchangelog(
        $specfile, 
        %options,
        pkgname => $pkgname,
    ));
   
    my $message = $options{message} || "Import $pkgname";
    $self->{svn}->log_msg(
        sub {
            $_[0] = \$message;
            return 0;
        }
    );
    print "Commiting $pkgname\n";
    my $revision = -1;
    if (!$self->{nocommit}) {
        my $info = $self->{svn}->commit($pkgdir, 0) unless($self->{nocommit});
        $revision = $info->revision();
    }
    $self->{svn}->log_msg(undef);

    $revision;
}

=head2 splitchangelog($specfile, %options)

Strip the changelog from a specfile and commit it into the svn.

=cut

sub splitchangelog {
    my ($self, $specfile, %options) = @_;

    my ($basename) = $specfile =~ m!(?:.*/)?(.*)$!;
    
    my $pkgname = $options{pkgname};

    if (!$pkgname) {
        my $spec = RPM4::specnew($specfile, undef, '/', undef, 1, 0) or do {
            $self->{error} = "Can't parse specfile $specfile";
            return;
        };
        my $h = $spec->srcheader or return; # can't happend
        $pkgname = $h->queryformat('%{NAME}');
    }

    my ($changelog, $newspec) = MDV::Repsys::_strip_changelog($specfile);

    if (!$changelog) {
        return -1;
    }
    my $revision = -1;

    my $tempdir = tempdir( CLEANUP => 1 );
    my $resyslog = $self->{config}->val('log', 'oldurl');
    if ($resyslog) {
        my $oldchangelogurl = "$resyslog/$pkgname";
        eval {
            $self->{svn}->checkout(
                $resyslog,
                $tempdir,
                'HEAD',
                0,
            );
        };
        if ($@) {
            $self->{error} = "Can't checkout $resyslog: $@";
            return;
        }
        $self->{svn}->update(
            "$tempdir/$pkgname",
            'HEAD',
            1
        );
        if (! -d "$tempdir/$pkgname") {
            $self->{svn}->mkdir("$tempdir/$pkgname");
        }
        if (-f "$tempdir/$pkgname/log") {
            return 0;
        }
        if (open(my $logh, ">", "$tempdir/$pkgname/log")) {
            print $logh $changelog;
            close($logh);
        } else {
            return 0;
        }
        $self->{svn}->add("$tempdir/$pkgname/log", 0);
        my $message = $options{message} || "import old changelog for $pkgname";
        $self->{svn}->log_msg(sub {
            $_[0] = \$message;
            return 0;
        });
        print "Commiting $pkgname/log\n";
        if (!$self->{nocommit}) {
            my $info = $self->{svn}->commit($tempdir, 0);
            $revision = $info->revision();
        }

        $self->{svn}->log_msg(undef);
    }

    seek($newspec, 0, 0);
    if (open(my $oldspec, ">", $specfile)) {
        while (<$newspec>) {
            print $oldspec $_;
        }
        close($oldspec);
    } else {
        $self->{error} = "Can't open $specfile for writing: $!";
        return;
    }
    $revision;
}

sub _check_url_exists {
    my ($self, $url, %options) = @_;
    my ($parent, $leaf) = $url =~ m!(.*)?/+([^/]*)/*$!;

    my $leafs;

    eval {
        $leafs = $self->{svn}->ls(
            $parent, 
            $options{revision} || $self->{default}{revision},
            0,
        );
    };
    if ($@) {
        $self->{error} = "Can't list $parent: $@";
        return;
    }
    exists($leafs->{$leaf})
}

=head2 tag_pkg($pkgname, %options)

TAG a package into the svn, aka copy the current tree into
VERSION/RELEASE/. The operation is done directly into the svn.

=cut

sub tag_pkg {
    my ($self, $pkgname, %options) = @_;

    my ($handle, $tempspecfile) = tempfile();

    eval {
        $self->{svn}->cat(
            $handle,
            $self->get_pkgurl($pkgname) . "/SPECS/$pkgname.spec",
            $options{revision} || $self->{default}{revision},
        );
    };
    if ($@) {
        $self->{error} = "Can't get specfile " . $self->get_pkgurl($pkgname) . "/SPECS/$pkgname.spec: $@";
        return;
    }

    close($handle);

    my $spec = RPM4::specnew($tempspecfile, undef, '/', undef, 1, 1) or do {
        $self->{error} = "Can't parse $tempspecfile";
        return 0;
    };
    my $header = $spec->srcheader or return 0;

    my $ev = $header->queryformat('%|EPOCH?{%{EPOCH}:}:{}|%{VERSION}');
    my $re = $header->queryformat('%{RELEASE}');

    my $tagurl = $self->get_pkgurl($pkgname, pkgversion => 'releases');
    my $pristineurl = $self->get_pkgurl($pkgname, pkgversion => 'pristine');

    if (!$self->_check_url_exists($tagurl)) {
        $self->{svn}->mkdir($tagurl);
    }

    if (!$self->_check_url_exists("$tagurl/$ev")) {
        $self->{svn}->mkdir("$tagurl/$ev");
    }

    if ($self->_check_url_exists("$tagurl/$ev/$re")) {
        $self->{error} = "$tagurl/$ev/$re already exists";
        return;
    }

    my $message = "Tag release $ev-$re";
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
    eval {
        $self->{svn}->delete($pristineurl, 1);
    };
    $self->{svn}->copy(
        $self->get_pkgurl($pkgname),
        $options{revision} || $self->{default}{revision},
        $pristineurl
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
