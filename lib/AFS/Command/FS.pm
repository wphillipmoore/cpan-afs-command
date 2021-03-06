package AFS::Command::FS;

require 5.010;

use Moose;
use MooseX::Singleton;
use English;
use Carp;

use feature q{switch};

extends qw(AFS::Command::Base);

use AFS::Object;
use AFS::Object::CacheManager;
use AFS::Object::Path;
use AFS::Object::Cell;
use AFS::Object::Server;
use AFS::Object::ACL;

sub getPathInfo {

    my $self = shift;
    my %args = @_;

    my $method = delete $args{method} ||
        croak qq{Missing required argument: method\n};

    my $pathkey = $method eq q{storebehind} ? q{files} : q{path};

    if ( ref $args{$pathkey} ) {
        croak qq{Invalid argument: $pathkey is a reference\n};
    }

    my ($result) = $self->_paths_method( $method, %args )->getPaths;

    if ( $result->error ) {
        croak $result->error;
    }

    return $result;

}

sub diskfree {
    return shift->_paths_method( q{diskfree}, @_ );
}

sub examine {
    return shift->_paths_method( q{examine} ,@_ );
}

sub getcalleraccess {
    return shift->_paths_method( q{getcalleraccess} ,@_ );
}

sub listacl {
    return shift->_paths_method( q{listacl}, @_ );
}

sub listquota {
    return shift->_paths_method( q{listquota}, @_ );
}

sub quota {
    return shift->_paths_method( q{quota}, @_ );
}

sub storebehind {
    return shift->_paths_method( q{storebehind}, @_ );
}

sub whereis {
    return shift->_paths_method( q{whereis}, @_ );
}

sub whichcell {
    return shift->_paths_method( q{whichcell}, @_ );
}

sub _paths_method {

    my $self = shift;
    my $operation = shift;
    my %args = @_;

    my $result = AFS::Object::CacheManager->new;

    $self->operation( $operation );

    my $default_asynchrony = undef;

    my $pathkey = $operation eq q{storebehind} ? q{files} : q{path};

    $self->_parse_arguments(%args);
    $self->_exec_commands( stderr => q{stdout} );

    my @paths = ref $args{$pathkey} eq q{ARRAY} ? @{$args{$pathkey}} : ($args{$pathkey});
    my %paths = map { $_ => 1 } @paths;

    while ( defined($_ = $self->_handle->getline) ) {

        chomp;

        next if m{^Volume Name}ms;

        if ( m{Default store asynchrony is (\d+) kbytes}ms ) {
            $default_asynchrony = $1;
            next;
        }

        my $path = AFS::Object::Path->new;

        if ( m{fs: Invalid argument; it is possible that (.*) is not in AFS.}ms ||
             m{fs: no such cell as \'(.*)\'}ms ||
             m{fs: File \'(.*)\' doesn\'t exist}ms ||
             m{fs: You don\'t have the required access rights on \'(.*)\'}ms ) {
            $path->_setAttribute( path  => $1, error => $_ );
            delete $paths{$1};
            @paths = grep { $_ ne $1 } @paths;
            $result->_addPath($path);
            next;
        }

        if ( $operation eq q{diskfree} ) {
            my ($volname,$total,$used,$avail,$percent) = split;
            $percent =~ s{\D}{}gms;
            $path->_setAttribute(
                path    => $paths[0],
                volname => $volname,
                total   => $total,
                used    => $used,
                avail   => $avail,
                percent => $percent,
            );
            delete $paths{$paths[0]};
            shift @paths;
        }

        if ( $operation eq q{examine} ) {

            if ( m{File (.*) \(\d+.(.*)\) contained in volume \d+}ms ) {
                $path->_setAttribute( path => $1, fid  => $2 );
                $_ = $self->_handle->getline;
                chomp;
            }

            if ( m{Volume status for vid = (\d+) named (\S+)}ms ) {

                if ( not $path->path ) {
                    $path->_setAttribute( path => $paths[0] );
                }

                $path->_setAttribute( id => $1, volname => $2 );

                # Note that we ignore the "Message of the day" and
                # "Offline reason" output for now.  Read until we hit
                # a blank line.
                while ( defined($_ = $self->_handle->getline) ) {

                    chomp;
                    last if not $_;

                    given ( $_ ) {
                        when ( m{Current disk quota is (\d+|unlimited)}ms ) {
                            $path->_setAttribute( quota => $1 eq q{unlimited} ? 0 : $1 );
                        }
                        when ( m{Current blocks used are (\d+)}ms ) {
                            $path->_setAttribute( used => $1 );
                        }
                        when ( m{The partition has (\d+) blocks available out of (\d+)}ms ) {
                            $path->_setAttribute( avail => $1, total => $2 );
                        }
                    }

                }

                delete $paths{$paths[0]};
                shift @paths;

            }

        }

        if ( $operation eq q{getcalleraccess} ) {
            if ( m{Callers access to (.*) is (\S+)}ms ) {
                $path->_setAttribute( path => $1, rights => $2 );
                delete $paths{$1};
            }
        }

        if ( $operation eq q{listacl} ) {

            if ( m{^Access list for (.*) is}ms ) {

                $path->_setAttribute( path => $1 );
                delete $paths{$1};

                my %acls = (
                    normal   => AFS::Object::ACL->new,
                    negative => AFS::Object::ACL->new,
                );

                my $type = q{};

                while ( defined($_ = $self->_handle->getline) ) {

                    chomp;
                    s{^\s+}{}gms;
                    s{\s+$}{}gms;
                    last if not $_;

                    if ( m{^(Normal|Negative) rights:}ms ) {
                        $type = lc($1);
                    } else {
                        my ($principal,$rights) = split;
                        $acls{$type}->_addEntry( $principal => $rights );
                    }

                }

                $path->_setACLNormal( $acls{normal} );
                $path->_setACLNegative( $acls{negative} );

            }

        }

        if ( $operation eq q{listquota} ) {
            s{no limit}{0}gms;
            my ($volname,$quota,$used,$percent,$partition) = split;
            $percent   =~ s{\D}{}gms;
            $partition =~ s{\D}{}gms;
            $path->_setAttribute(
                path      => $paths[0],
                volname   => $volname,
                quota     => $quota,
                used      => $used,
                percent   => $percent,
                partition => $partition,
            );
            delete $paths{$paths[0]};
            shift @paths;
        }

        if ( $operation eq q{quota} ) {
            if ( m{^\s*(\d{1,2})%}ms ) {
                $path->_setAttribute(
                    path    => $paths[0],
                    percent => $1,
                );
                delete $paths{$paths[0]};
                shift @paths;
            }
        }

        if ( $operation eq q{storebehind} ) {
            if ( m{Will store (.*?) according to default.}ms ) {
                $path->_setAttribute(
                    path       => $1,
                    asynchrony => q{default},
                );
                delete $paths{$1};
            } elsif ( m{Will store up to (\d+) kbytes of (.*?) asynchronously}ms ) {
                $path->_setAttribute(
                    path       => $2,
                    asynchrony => $1,
                );
                delete $paths{$2};
            }
        }

        if ( $operation eq q{whereis} ) {
            if ( m{^File (.*) is on hosts? (.*)$}ms ) {
                $path->_setAttribute(
                    path  => $1,
                    hosts => [split(/\s+/,$2)],
                );
                delete $paths{$1};
            }
        }

        if ( $operation eq q{whichcell} ) {
            if ( m{^File (\S+) lives in cell \'([^\']+)\'}ms ) {
                $path->_setAttribute(
                    path => $1,
                    cell => $2,
                );
                delete $paths{$1};
            }
        }

        if ( not $path->path ) {
            croak qq{Failed to set path during operation $operation};
        }

        $result->_addPath($path);

    }

    foreach my $pathname ( keys %paths ) {
        my $path = AFS::Object::Path->new(
            path  => $pathname,
            error => q{Unable to determine results},
        );
        $result->_addPath($path);
    }

    $self->_reap_commands( allowstatus => 1 );

    if ( $operation eq q{storebehind} ) {

        # This is ugly, but we get the default last, and it would be
        # nice to put this value into the Path objects as well, rather
        # than the string 'default'.

        if ( not defined $default_asynchrony ) {
            # It appears that fs storebehind, in older AFS versions,
            # would always print the default line, but in more recent
            # versions, the default is only printed if you provide by
            # arguments.
            $default_asynchrony = $self->_default_asynchrony;
        }

        $result->_setAttribute( asynchrony => $default_asynchrony );
        foreach my $path ( $result->getPaths ) {
            if ( $path->asynchrony and $path->asynchrony eq q{default} ) {
                $path->_setAttribute( asynchrony => $default_asynchrony );
            }
        }

    }

    return $result;

}

sub _default_asynchrony {

    my $self = shift;

    $self->operation( q{storebehind} );

    $self->_parse_arguments;
    $self->_save_stderr;
    $self->_exec_commands;

    my $default_asynchrony = undef;

    while ( defined($_ = $self->_handle->getline) ) {
        if ( m{Default store asynchrony is (\d+) kbytes}ms ) {
            $default_asynchrony = $1;
        }
    }

    $self->_restore_stderr;
    $self->_reap_commands;

    if ( not defined $default_asynchrony ) {
        croak qq{Unable to determine default value of asynchrony};
    }

    return $default_asynchrony;

}

# NOTE: This *should* be a _paths_method command, however, getfid has
# some serious issues.

sub getfid {

    my $self = shift;
    my %args = @_;

    my $result = AFS::Object::CacheManager->new;

    $self->operation( q{getfid} );

    $self->_parse_arguments(%args);
    $self->_exec_commands( stderr => q{stdout} );
    
    my @paths = ref $args{path} eq q{ARRAY} ? @{$args{path}} : ($args{path});
    my %paths = map { $_ => 1 } @paths;

    while ( defined($_ = $self->_handle->getline) ) {

        chomp;

        my $path = AFS::Object::Path->new;

        #
        # NOTE: As of OpenAFS 1.5.77, getfid does NOT return this
        # information.  This will be patched, but most fs binaries
        # will NOT generate this.
        #
        if ( m{fs: Invalid argument; it is possible that (.*) is not in AFS.}ms ||
             m{fs: no such cell as \'(.*)\'}ms ||
             m{fs: File \'(.*)\' doesn\'t exist}ms ||
             m{fs: You don\'t have the required access rights on \'(.*)\'}ms ) {
            $path->_setAttribute( path  => $1, error => $_ );
        } elsif ( m{File (.*) \((\d+)\.(\d+)\.(\d+)\) contained in volume \d+}ms ) {
            $path->_setAttribute(
                path   => $1,
                volume => $2,
                vnode  => $3,
                unique => $4,
            );
        } elsif ( m{File (.*) \((\d+)\.(\d+)\.(\d+)\) located in cell (\S+)}ms ) {
            $path->_setAttribute(
                path   => $1,
                volume => $2,
                vnode  => $3,
                unique => $4,
                cell   => $5,
            );
        }

        if ( $path->path ) {
            delete $paths{ $path->path };
            $result->_addPath($path);
        }
        
    }

    foreach my $pathname ( keys %paths ) {
        my $path = AFS::Object::Path->new(
            path  => $pathname,
            error => q{Unable to determine results},
        );
        $result->_addPath($path);
    }

    # NOTE: Also as of OpenAFS 1.5.77, getfid always exits 0, but this
    # is also being patched.
    $self->_reap_commands( allowstatus => 1 );

    return $result;

}

sub bypassthreshold {

    my $self = shift;
    my %args = @_;

    my $result = AFS::Object::CacheManager->new;

    $self->operation( q{bypassthreshold} );

    $self->_parse_arguments(%args);
    $self->_save_stderr;
    $self->_exec_commands;

    while ( defined($_ = $self->_handle->getline) ) {
        chomp;
        if ( m{Cache bypass threshold (\S+)}ms ) {
            $result->_setAttribute( bypassthreshold => $1 );
        }
    }

    $self->_restore_stderr;
    $self->_reap_commands;

    return $result;

}

sub checkservers {

    my $self = shift;
    my %args = @_;

    my $result = AFS::Object::CacheManager->new;

    $self->operation( q{checkservers} );

    $self->_parse_arguments(%args);
    $self->_save_stderr;
    $self->_exec_commands;

    my @servers = ();

    while ( defined($_ = $self->_handle->getline) ) {

        chomp;

        if ( m{The current down server probe interval is (\d+) secs}ms ) {
            $result->_setAttribute( interval => $1 );
        }

        if ( m{These servers are still down:}ms ) {
            while ( defined($_ = $self->_handle->getline) ) {
                chomp;
                s{^\s+}{}gms;
                s{\s+$}{}gms;
                push @servers, $_;
            }
        }
    }

    $result->_setAttribute( servers => \@servers );

    $self->_restore_stderr;
    $self->_reap_commands;

    return $result;

}

sub exportafs {

    my $self = shift;
    my %args = @_;

    my $result = AFS::Object::CacheManager->new;

    $self->operation( q{exportafs} );

    $self->_parse_arguments(%args);
    $self->_save_stderr;
    $self->_exec_commands;

    while ( defined($_ = $self->_handle->getline) ) {
        given ( $_ ) {
            when ( m{translator is (currently )?enabled}ms ) {
                $result->_setAttribute( enabled => 1 );
            }
            when ( m{translator is disabled}ms ) {
                $result->_setAttribute( enabled => 0 );
            }
            when ( m{convert owner mode bits}ms ) {
                $result->_setAttribute( convert => 1 );
            }
            when ( m{strict unix}ms ) {
                $result->_setAttribute( convert => 0 );
            }
            when ( m{strict \'?passwd sync\'?}ms ) {
                $result->_setAttribute( uidcheck => 1 );
            }
            when ( m{no \'?passwd sync\'?}ms ) {
                $result->_setAttribute( uidcheck => 0 );
            }
            when ( m{allow mounts}msi ) {
                $result->_setAttribute( submounts => 1 );
            }
            when ( m{Only mounts}msi ) {
                $result->_setAttribute( submounts => 0 );
            }
        }
    }

    $self->_restore_stderr;
    $self->_reap_commands;

    return $result;

}

sub getcacheparms {

    my $self = shift;
    my %args = @_;

    my $result = AFS::Object::CacheManager->new;

    $self->operation( q{getcacheparms} );

    $self->_parse_arguments(%args);
    $self->_save_stderr;
    $self->_exec_commands;

    while ( defined($_ = $self->_handle->getline) ) {
        if ( m{using (\d+) of the cache.s available (\d+) 1K}ms ) {
            $result->_setAttribute( used  => $1, avail => $2 );
        }
    }

    $self->_restore_stderr;
    $self->_reap_commands;

    return $result;

}

sub getcellstatus {

    my $self = shift;
    my %args = @_;

    my $result = AFS::Object::CacheManager->new;

    $self->operation( q{getcellstatus} );

    $self->_parse_arguments(%args);
    $self->_save_stderr;
    $self->_exec_commands;

    while ( defined($_ = $self->_handle->getline) ) {
        if ( m{Cell (\S+) status: (no )?setuid allowed}ms ) {
            my $cell = AFS::Object::Cell->new(
                cell   => $1,
                status => $2 ? 0 : 1,
            );
            $result->_addCell($cell);
        }
    }

    $self->_restore_stderr;
    $self->_reap_commands;

    return $result;

}

sub getclientaddrs {

    my $self = shift;
    my %args = @_;

    my $result = AFS::Object::CacheManager->new;

    $self->operation( q{getclientaddrs} );

    $self->_parse_arguments(%args);
    $self->_save_stderr;
    $self->_exec_commands;

    my @addresses = ();

    while ( defined($_ = $self->_handle->getline) ) {
        chomp;
        s{^\s+}{}ms;
        s{\s+$}{}ms;
        push @addresses, $_;
    }

    $result->_setAttribute( addresses => \@addresses );

    $self->_restore_stderr;
    $self->_reap_commands;

    return $result;

}

sub getcrypt {

    my $self = shift;
    my %args = @_;

    my $result = AFS::Object::CacheManager->new;

    $self->operation( q{getcrypt} );

    $self->_parse_arguments(%args);
    $self->_save_stderr;
    $self->_exec_commands;

    while ( defined($_ = $self->_handle->getline) ) {
        if ( m{Security level is currently (crypt|clear)}ms ) {
            $result->_setAttribute( crypt => $1 eq q{crypt} ? 1 : 0 );
        }
    }

    $self->_restore_stderr;
    $self->_reap_commands;

    return $result;

}

sub getserverprefs {

    my $self = shift;
    my %args = @_;

    my $result = AFS::Object::CacheManager->new;

    $self->operation( q{getserverprefs} );

    $self->_parse_arguments(%args);
    $self->_save_stderr;
    $self->_exec_commands;

    while ( defined($_ = $self->_handle->getline) ) {

        chomp;
        s{^\s+}{}gms;
        s{\s+$}{}gms;

        my ($name,$preference) = split;

        my $server = AFS::Object::Server->new(
            server     => $name,
            preference => $preference,
        );

        $result->_addServer($server);

    }

    $self->_restore_stderr;
    $self->_reap_commands;

    return $result;

}

sub listaliases {

    my $self = shift;
    my %args = @_;

    my $result = AFS::Object::CacheManager->new;

    $self->operation( q{listaliases} );

    $self->_parse_arguments(%args);
    $self->_save_stderr;
    $self->_exec_commands;

    while ( defined($_ = $self->_handle->getline) ) {
        chomp;
        if ( m{Alias (.*) for cell (.*)}ms ) {
            my $cell = AFS::Object::Cell->new(
                cell  => $2,
                alias => $1,
            );
            $result->_addCell($cell);
        }
    }

    $self->_restore_stderr;
    $self->_reap_commands;

    return $result;

}

sub listcells {

    my $self = shift;
    my %args = @_;

    my $result = AFS::Object::CacheManager->new;

    $self->operation( q{listcells} );

    $self->_parse_arguments(%args);
    $self->_save_stderr;
    $self->_exec_commands;

    while ( defined($_ = $self->_handle->getline) ) {
        chomp;
        if ( m{^Cell (\S+) on hosts (.*)\.$}ms ) {
            my $cell = AFS::Object::Cell->new(
                cell    => $1,
                servers => [split(/\s+/,$2)],
            );
            $result->_addCell($cell);
        }
    }

    $self->_restore_stderr;
    $self->_reap_commands;

    return $result;

}

sub lsmount {

    my $self = shift;
    my %args = @_;

    my $result = AFS::Object::CacheManager->new;

    $self->operation( q{lsmount} );

    $self->_parse_arguments(%args);
    $self->_exec_commands( stderr => q{stdout} );

    my @dirs = ref $args{dir} eq q{ARRAY} ? @{$args{dir}} : ($args{dir});
    my %dirs = map { $_ => 1 } @dirs;

    while ( defined($_ = $self->_handle->getline) ) {

        chomp;
        my $current = shift @dirs;
        delete $dirs{$current};

        my $path = AFS::Object::Path->new( path => $current );

        given ( $_ ) {

            when ( m{fs: Can.t read target name}ms ) {
                $path->_setAttribute( error => $_ );
            }
            when ( m{fs: File '.*' doesn't exist}ms ) {
                $path->_setAttribute( error => $_ );
            }
            when ( m{fs: you may not use \'.\'}ms ) {
                $_ .= $self->_handle->getline;
                $path->_setAttribute( error => $_ );
            }
            when ( m{\'(.*?)\' is not a mount point}ms ) {
                $path->_setAttribute( error => $_ );
            }

            when ( m{^\'(.*?)\'.*?\'(.*?)\'$}ms ) {

                my ($dir,$mount) = ($1,$2);

                $path->_setAttribute( symlink => 1 ) if m{symbolic link}ms;
                $path->_setAttribute( readwrite => 1 ) if $mount =~ m{^%}ms;
                $mount =~ s{^(%|\#)}{}ms;

                my ($volname,$cell) = reverse split( m{:}msx, $mount );

                $path->_setAttribute( volname => $volname );
                $path->_setAttribute( cell => $cell) if $cell;

            }

            default {
                croak qq{fs lsmount: Unrecognized output: '$_'};
            }

        }

        $result->_addPath($path);

    }

    foreach my $dir ( keys %dirs ) {
        my $path = AFS::Object::Path->new(
            path  => $dir,
            error => q{Unable to determine results},
        );
        $result->_addPath($path);
    }

    $self->_reap_commands( allowstatus => 1 );

    return $result;

}

#
# This is deprecated in newer versions of OpenAFS
#
sub monitor {
    croak qq{fs monitor: This operation is deprecated and no longer supported};
}

sub sysname {

    my $self = shift;
    my %args = @_;

    my $result = AFS::Object::CacheManager->new;

    $self->operation( q{sysname} );

    $self->_parse_arguments(%args);
    $self->_save_stderr;
    $self->_exec_commands;

    my @sysname = ();

    while ( defined($_ = $self->_handle->getline) ) {

        chomp;

        if ( m{Current sysname is \'?([^\']+)\'?}ms ) {
            $result->_setAttribute( sysname => $1 );
        } elsif ( s{Current sysname list is }{}ms ) {
            while ( s{\'([^\']+)\'\s*}{}ms ) {
                push @sysname, $1;
            }
            $result->_setAttribute( sysnames => \@sysname );
            $result->_setAttribute( sysname => $sysname[0] );
        }

    }

    $self->_restore_stderr;
    $self->_reap_commands;

    return $result;

}

sub uuid {

    my $self = shift;
    my %args = @_;

    if ( $self->supportsArgumentRequired( qw( uuid generate ) ) ) {
        return $self->_uuid_simple(%args);
    } else {
        return $self->_uuid_complex(%args);
    }

}

sub _uuid_simple {
    my $self = shift;
    $self->operation( q{uuid} );
    $self->_parse_arguments(@_);
    $self->_exec_commands( stderr => q{stdout} );
    $self->_parse_output;
    $self->_reap_commands;
    return 1;
}

sub _uuid_complex {

    my $self = shift;
    my %args = @_;

    my $result = AFS::Object::CacheManager->new;

    $self->operation( q{uuid} );

    $self->_parse_arguments(%args);
    $self->_save_stderr;
    $self->_exec_commands;


    while ( defined($_ = $self->_handle->getline) ) {
        chomp;
        if ( m{UUID: (\S+)}ms ) {
            $result->_setAttribute( uuid => $1 );
        }
    }

    $self->_restore_stderr;
    $self->_reap_commands;

    return $result;

}

sub wscell {

    my $self = shift;
    my %args = @_;

    my $result = AFS::Object::CacheManager->new;

    $self->operation( q{wscell} );

    $self->_parse_arguments(%args);
    $self->_save_stderr;
    $self->_exec_commands;

    while ( defined($_ = $self->_handle->getline) ) {
        next if not m{belongs to cell\s+\'(.*)\'}ms;
        $result->_setAttribute( cell => $1 );
    }

    $self->_restore_stderr;
    $self->_reap_commands;

    return $result;

}

1;

