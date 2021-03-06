package AFS::Command::Base;

require 5.010;

use Moose;
use English;
use Carp;

use Data::Dumper;

use File::Basename qw(basename);
use File::Temp;
use File::Slurp;
use Date::Format;
use IO::File;
use IO::Pipe;

our $AUTOLOAD = q{};

has q{localtime}  => ( is => q{rw}, isa => q{Int}, default => 0 );
has q{noauth}     => ( is => q{rw}, isa => q{Int}, default => 0 );
has q{localauth}  => ( is => q{rw}, isa => q{Int}, default => 0 );
has q{encrypt}    => ( is => q{rw}, isa => q{Int}, default => 0 );
has q{quiet}      => ( is => q{rw}, isa => q{Int}, default => 0 );

has q{command}    => ( is => q{rw}, isa => q{Str}, lazy_build => 1 );
has q{operation}  => ( is => q{rw}, isa => q{Str}, default => q{} );

has q{_errors}     => ( is => q{rw}, isa => q{Str}, default => q{} );

has q{_commands}  => ( is => q{rw}, isa => q{ArrayRef}, default => sub { return []; } );
has q{_pids}      => ( is => q{rw}, isa => q{HashRef},  default => sub { return {}; } );

has q{_operations} => ( is => q{rw}, isa => q{HashRef}, lazy_build => 1 );
has q{_arguments}  => ( is => q{rw}, isa => q{HashRef}, default => sub { return {}; } );

has q{_handle}  => ( is => q{rw}, isa => q{IO::Pipe::End} );
has q{_stderr}  => ( is => q{rw}, isa => q{IO::File} );
has q{_tmpfile} => ( is => q{rw}, isa => q{Str} );

sub debug {
    my $self = shift;
    return if not $ENV{AFS_COMMAND_DEBUG};
    carp @_;
}

sub _build_command {
    my $self  = shift;
    my $class = ref $self;
    my ($command) = reverse split m{::}ms, $class;
    return lc($command);
}

sub _build__operations {

    my $self = shift;
    my $operation = shift;

    my $operations = {};

    # This hack is necessary to support the offline/online "hidden"
    # vos commands.  These won't show up in the normal help output, so
    # we have to check for them individually.  Since offline and
    # online are implemented as a pair, we can just check one of them,
    # and assume the other is there, too.

    foreach my $type ( qw(default hidden) ) {

        if ( $type eq q{hidden} ) {
            next if not $self->isa( q{AFS::Command::VOS} );
        }

        my $pipe = IO::Pipe->new || croak qq{Unable to create pipe: $ERRNO\n};

        my $pid = fork;

        defined $pid || croak qq{Unable to fork: $ERRNO\n};

        if ( $pid == 0 ) {

            STDERR->fdopen( STDOUT->fileno, q{w} ) ||
                croak qq{Unable to redirect stderr: $ERRNO\n};
            STDOUT->fdopen( $pipe->writer->fileno, q{w} ) ||
                croak qq{Unable to redirect stdout: $ERRNO\n};

            my $command = $self->command;

            if ( $type eq q{default} ) {
                $command .= q{ help};
            } else {
                $command .= q{ offline -help};
            }

            exec $command ||
                croak qq{Unable to exec $command: $ERRNO\n};

        } else {

            $pipe->reader;

            while ( defined($_ = $pipe->getline) ) {
                if ( $type eq q{default} ) {
                    next if m{Commands \s+ are:}msx;
                    my ($command) = split;
                    next if $command =~ m{^(apropos|help)$}msx;
                    $operations->{$command}++;
                } elsif ( m{^Usage:}msx ) {
                    $operations->{offline}++;
                    $operations->{online}++;
                }
            }

        }

        if ( not waitpid($pid,0) ) {
            croak qq{Unable to get status of child process ($pid)\n};
        }

        if ( $CHILD_ERROR ) {
            my $class = ref $self;
            croak qq{Error running command help. Unable to configure $class\n};
        }

    }

    return $operations;

}

sub supportsOperation {
    return shift->_operations->{ shift(@_) };
}

sub supportsArgument {
    my $self = shift;
    my $operation = shift;
    my $argument = shift;
    return if not $self->supportsOperation( $operation );
    return exists $self->_operation_arguments( $operation )->{ $argument };
}

sub supportsArgumentRequired {
    my $self = shift;
    my $operation = shift;
    my $argument = shift;
    return if not $self->supportsArgument( $operation, $argument );
    my $arguments = $self->_operation_arguments( $operation )->{ $argument };
    return if exists $arguments->{required};
}

sub supportsArgumentOptional {
    my $self = shift;
    my $operation = shift;
    my $argument = shift;
    return if not $self->supportsArgument( $operation, $argument );
    my $arguments = $self->_operation_arguments( $operation )->{ $argument };
    return if exists $arguments->{optional};
}

sub _operation_arguments {

    my $self      = shift;
    my $operation = shift;

    my $arguments = {
        optional => {},
        required => {},
        aliases  => {},
    };

    my $command = $self->command;

    return if not $self->supportsOperation($operation);

    return $self->_arguments->{$operation} if $self->_arguments->{$operation};

    my $pipe = IO::Pipe->new || croak qq{Unable to create pipe: $ERRNO};

    my $pid = fork;

    defined $pid || croak qq{Unable to fork: $ERRNO};

    if ( $pid == 0 ) {

        STDERR->fdopen( STDOUT->fileno, q{w} ) ||
            croak qq{Unable to redirect stderr: $ERRNO};
        STDOUT->fdopen( $pipe->writer->fileno, q{w} ) ||
            croak qq{Unable to redirect stdout: $ERRNO\n};
        exec( $command, $operation, '-help' ) ||
            croak qq{Unable to exec $command help $operation: $ERRNO};

    } else {

        $pipe->reader;

        while ( defined($_ = $pipe->getline) ) {

            if ( m{Unrecognized \s+ operation \s+ '$operation'}msx ) {
                croak qq{Unsupported $command operation '$operation'};
            }

            next if not s{^Usage:.*\s+$operation\s+}{}ms;

            while ( $_ ) {
                if ( s{^\[\s*-(\w+?)\s*\]\s*}{}ms  ) {
                    $arguments->{optional}->{$1} = 0
                        if $1 ne q{help}; # Yeah, skip it...
                } elsif ( s{^\[\s*-(\w+?)\s+<[^>]*?>\+\s*]\s*}{}ms ) {
                    $arguments->{optional}->{$1} = [];
                } elsif ( s{^\[\s*-(\w+?)\s+<[^>]*?>\s*]\s*}{}ms ) {
                    $arguments->{optional}->{$1} = 1;
                } elsif ( s{^\s*-(\w+?)\s+<[^>]*?>\+\s*}{}ms ) {
                    $arguments->{required}->{$1} = [];
                } elsif ( s{^\s*-(\w+?)\s+<[^>]*?>\s*}{}ms ) {
                    $arguments->{required}->{$1} = 1;
                } elsif ( s{^\s*-(\w+?)(:?\s+|$)}{}ms ) {
                    $arguments->{required}->{$1} = 0;
                } else {
                    croak(
                        qq{Unable to parse $command help for $operation\n},
                        qq{Unrecognized string: '$_'},
                    );
                }
            }

            last;

        }

    }

    #
    # We need to force certain API calls to use a single argument,
    # instead of a list, for robustness of error handling.
    #
    if ( $operation eq q{listowned} ) {
        $arguments->{required}->{nameorid} = 1;
    }

    if ( $operation ~~ [qw( createuser creategroup )] ) {
        $arguments->{required}->{name} = 1;
        $arguments->{optional}->{id}   = 1;
    }

    # Niether of these options is supported by the parsing logic for
    # pts membership yet, so both options will appear to be
    # unsupported until that code is written.
    if ( $operation eq q{membership} ) {
        delete $arguments->{optional}->{supergroups};
        delete $arguments->{optional}->{expandgroups};
    }

    #
    # XXX -- Hack Alert!!!
    #
    # Because the force option to vos release changed from -f to
    # -force, you can't use the API transparently with 2 different vos
    # binaries that support the 2 different options.  If we need more
    # of these, we can add them, as this let's us alias one argument
    # to another.
    #
    if ( $self->isa( q{AFS::Command::VOS} ) and $operation eq q{release} ) {
        if ( exists $arguments->{optional}->{f} ) {
            $arguments->{aliases}->{force} = q{f};
        } elsif ( exists $arguments->{optional}->{force} ) {
            $arguments->{aliases}->{f} = q{force};
        }
    }

    if ( not waitpid($pid,0) ) {
        croak qq{Unable to get status of child process ($pid)};
    }

    if ( $CHILD_ERROR ) {
        croak qq{Error running $command $operation -help.  Unable to configure $command $operation};
    }

    return $self->_arguments->{$operation} = $arguments;

}

sub _save_stderr {

    my $self = shift;

    my $olderr = IO::File->new( qq{>&STDERR} ) or
        croak qq{Unable to dup stderr: $ERRNO};

    $self->_stderr( $olderr );

    my $tmpfile = File::Temp->new(
        TEMPLATE => q{/tmp/afscmd.stderr.XXXXXXXX},
        UNLINK   => 0,
    ) or croak qq{Unable to create File::Temp object\n};

    STDERR->fdopen( $tmpfile->fileno, q{w} ) or
        croak qq{Unable to reopen stderr: $ERRNO};

    $self->_tmpfile( $tmpfile->filename );

    return 1;

}

sub _restore_stderr {

    my $self = shift;

    STDERR->fdopen( $self->_stderr->fileno, q{w} ) or
        croak qq{Unable to restore stderr: $ERRNO};

    $self->_stderr->close or
        croak qq{Unable to close saved stderr: $ERRNO};

    my $tmpfile = $self->_tmpfile;

    $self->_errors( read_file( $tmpfile ) );

    unlink $tmpfile or
        croak qq{Unable to unlink $tmpfile: $ERRNO};

    return 1;

}

sub _parse_arguments {

    my $self = shift;
    my %args = @_;

    my $class = ref $self;

    my $operation = $self->operation;
    my $arguments = $self->_operation_arguments( $operation ) ||
        croak qq{Unable to obtain arguments for $class->$operation};

    if ( $args{inputfile} ) {
        $self->_commands( [ [ q{cat}, $args{inputfile} ] ] );
        return 1;
    }

    my $command = [ $self->command, $self->operation ];

    foreach my $key ( keys %args ) {
        next if not $arguments->{aliases}->{$key};
        $args{$arguments->{aliases}->{$key}} = delete $args{$key};
    }

    foreach my $key ( qw( noauth localauth encrypt ) ) {
        next if not $self->$key;
        $args{$key}++ if exists $arguments->{required}->{$key};
        $args{$key}++ if exists $arguments->{optional}->{$key};
    }

    if ( not $self->quiet ) {
        $args{verbose}++ if exists $arguments->{optional}->{verbose};
    }

    foreach my $type ( qw( required optional ) ) {

        foreach my $key ( keys %{ $arguments->{$type} } ) {

            my $hasvalue = $arguments->{$type}->{$key};

            if ( not exists $args{$key} ) {
                next if $type ne q{required};
                croak qq{Required argument '$key' not provided};
            }

            if ( $hasvalue ) {
                if ( ref $args{$key} eq q{HASH} || ref $args{$key} eq q{ARRAY} ) {
                    if ( ref $hasvalue ne q{ARRAY} ) {
                        croak qq{Invalid argument '$key': can't provide a list of values};
                    }
                    push @{ $command }, qq{-$key};
                    foreach my $value ( ref $args{$key} eq q{HASH} ? %{$args{$key}} : @{$args{$key}} ) {
                        push @{ $command }, $value;
                    }
                } else {
                    push @{ $command }, qq{-$key}, $args{$key};
                }
            } else {
                push @{ $command }, qq{-$key} if $args{$key};
            }

            delete $args{$key};

        }

    }

    if ( %args ) {
        croak( qq{Unsupported arguments: } . join( q{ }, sort keys %args ) );
    }

    $self->_commands( [ $command ] );

    return 1;

}

sub _exec_commands {

    my $self = shift;
    my %args = @_;

    my @commands = @{ $self->_commands };

    $self->_errors( q{} );
    $self->_pids( {} );

    for ( my $index = 0 ; $index <= $#commands ; $index++ ) {

        my $command = $commands[$index];

        my $pipe = IO::Pipe->new || croak qq{Unable to create pipe: $ERRNO};

        my $pid = fork;

        defined $pid || croak qq{Unable to fork: $ERRNO};

        if ( $pid == 0 ) {

            if ( $index == $#commands and exists $args{stdout} and $args{stdout} ne q{stdout} ) {
                my $stdout = IO::File->new( qq{>$args{stdout}} ) ||
                    croak qq{Unable to open $args{stdout}: $ERRNO};
                STDOUT->fdopen( $stdout->fileno, q{w} ) ||
                    croak qq{Unable to redirect stdout: $ERRNO};
            } else {
                STDOUT->fdopen( $pipe->writer->fileno, q{w} ) ||
                    croak qq{Unable to redirect stdout: $ERRNO};
            }

            if ( exists $args{stderr} and $args{stderr} eq q{stdout} ) {
                STDERR->fdopen( STDOUT->fileno, q{w} ) ||
                    croak qq{Unable to redirect stderr: $ERRNO};
            }

            if ( $index == 0 ) {
                if ( exists $args{stdin} and $args{stdin} ne q{stdin} ) {
                    my $stdin = IO::File->new( qq{<$args{stdin}} ) ||
                        croak qq{Unable to open $args{stdin}: $ERRNO};
                    STDIN->fdopen( $stdin->fileno, q{r} ) ||
                        croak qq{Unable to redirect stdin: $ERRNO};
                }
            } else {
                STDIN->fdopen( $self->_handle->fileno, q{r} ) ||
                    croak qq{Unable to redirect stdin: $ERRNO};
            }

            $ENV{TZ} = q{GMT} if not $self->localtime;

            exec { $command->[0] } @{ $command } or
                croak qq{Unable to exec $command->[0]: $ERRNO};

        }

        $self->_handle( $pipe->reader );
        $self->_pids->{$pid} = $command;

    }

    return 1;

}

sub _parse_output {

    my $self = shift;

    my $errors = q{};

    while ( defined($_ = $self->_handle->getline) ) {
        $errors .= $_;
    }

    $self->_errors( $errors );

    return 1;

}

sub _reap_commands {

    my $self = shift;
    my %args = @_;

    $self->_handle->close || croak qq{Unable to close pipe handle: $ERRNO};

    my %allowstatus = ();

    if ( $args{allowstatus} ) {
        map { $allowstatus{$_}++ } (
            ref $args{allowstatus} eq q{ARRAY} ? @{ $args{allowstatus} } : $args{allowstatus}
        );
    }

    my $errors = q{};

    foreach my $pid ( keys %{ $self->_pids } ) {

        if ( not waitpid($pid,0) ) {
            $errors .= qq{Unable to read child process ($pid)\n};
        }

        if ( $CHILD_ERROR ) {
            if ( not %allowstatus or not $allowstatus{ $CHILD_ERROR >> 8 } ) {
                my $command = join q{ }, @{ $self->_pids->{$pid} };
                $errors .= qq{Error running '$command'\n};
            }
        }

    }

    if ( $errors ) {
        croak( $self->_errors, $errors );
    }

    return 1;

}

sub AUTOLOAD {

    my $self = shift;

    my $operation = $AUTOLOAD;
    $operation =~ s{.*::}{}ms;

    $self->operation( $operation );

    $self->_parse_arguments(@_);
    $self->_exec_commands( stderr => q{stdout} );
    $self->_parse_output;
    $self->_reap_commands;

    return 1;

}

1;
