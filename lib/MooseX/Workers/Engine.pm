package MooseX::Workers::Engine;
use Moose;
use POE qw(Wheel::Run);
use MooseX::AttributeHelpers;

has visitor => (
    is       => 'ro',
    required => 1,
    does     => 'MooseX::Workers',
);

has max_workers => (
    isa     => 'Int',
    is      => 'rw',
    default => sub { 5 },
);

# Processes currently running
has process_list => (
    metaclass  => 'Collection::Hash',
    isa        => 'HashRef',
    is         => 'ro',
    auto_deref => 1,
    default    => sub { {} },
    provides   => {
        set    => 'set_process',
        get    => 'get_process',
        delete => 'remove_process',
    }
);

# Processes waiting to run
has process_queue => (
    metaclass  => 'Collection::Array',
    isa        => 'ArrayRef',
    is         => 'rw',
    auto_deref => 1,
    default    => sub { [] },
    provides   => {
        'push' => 'enqueue_process',
        'pop'  => 'dequeue_process',
    }
);

has workers => (
    isa       => 'HashRef',
    is        => 'rw',
    lazy      => 1,
    required  => 1,
    default   => sub { {} },
    metaclass => 'Collection::Hash',
    provides  => {
        'set'    => 'set_worker',
        'get'    => 'get_worker',
        'delete' => 'remove_worker',
        'empty'  => 'has_workers',
        'count'  => 'num_workers',
    },
);

has jobs => (
    isa       => 'HashRef',
    is        => 'rw',
    lazy      => 1,
    required  => 1,
    default   => sub { {} },
    metaclass => 'Collection::Hash',
    provides  => {
        'set'    => 'set_job',
        'get'    => 'get_job',
        'delete' => 'remove_job',
        'empty'  => 'has_jobs',
        'count'  => 'num_jobs',
    },
);

has session => (
    isa      => 'POE::Session',
    is       => 'ro',
    required => 1,
    lazy     => 1,
    default  => sub {
        POE::Session->create(
            object_states => [
                $_[0] => [
                    qw(
                      _start
                      _stop
                      _worker_stdout
                      _worker_stderr
                      _worker_error
                      _worker_done
                      _worker_started
                      _sig_child
                      add_worker
                      )
                ],
            ],
        );
    },
    clearer   => 'remove_manager',
    predicate => 'has_manager',
);

sub yield {
    my $self = shift;
    $poe_kernel->post( $self->session => @_ );
}

sub call {
    my $self = shift;
    return $poe_kernel->call( $self->session => @_ );
}

sub put_worker {
    my ( $self, $wheel_id ) = splice @_, 0, 2;
    $self->get_worker($wheel_id)->put(@_);
}

sub kill_worker {
    my ( $self, $wheel_id ) = splice @_, 0, 2;
    $self->get_wheel($wheel_id)->kill(@_);
}

#
# EVENTS
#

sub add_worker {
    my ( $self, $job, $args ) = @_[ OBJECT, ARG0, ARG1 ];

    # if we've reached the worker threashold, set off a warning
    if ( $self->num_workers >= $self->max_workers ) {
        if ( $args->{enqueue} ) {
            $self->enqueue_process([$job, $args]);
            return;
        } else {
            $self->visitor->max_workers_reached($job);
            return;
        }
    }

    my $command;
    if ( blessed($job) && $job->isa('MooseX::Workers::Job') ) {
        $command = $job->command;
        $args ||= $job->args;
    }
    else {
        $command = $job;
    }

    $args = [$args] unless ref $args eq 'ARRAY';
    my $wheel = POE::Wheel::Run->new(
        Program     => $command,
        ProgramArgs => $args,
        StdoutEvent => '_worker_stdout',
        StderrEvent => '_worker_stderr',
        ErrorEvent  => '_worker_error',
        CloseEvent  => '_worker_done',
    );
    $self->set_worker( $wheel->ID => $wheel );
    $self->set_process( $wheel->PID => $wheel->ID );
    if ( blessed($job) && $job->isa('MooseX::Workers::Job') ) {
       $job->ID($wheel->ID);
       $job->PID($wheel->PID);
       $self->set_job( $wheel->ID => $job );
    } 
    $self->yield( '_worker_started' => $wheel->ID => $job );
    return ( $wheel->ID => $wheel->PID );
}

sub _start {
    my ($self) = $_[OBJECT];
    $self->visitor->worker_manager_start()
      if $self->visitor->can('worker_manager_start');
    $_[KERNEL]->sig( CHLD => '_sig_child' );
}

sub _stop {
    my ($self) = $_[OBJECT];
    $self->visitor->worker_manager_stop()
      if $self->visitor->can('worker_manager_stop');
    $self->remove_manager;
}

sub _sig_child {
    my ($self) = $_[OBJECT];
    $self->visitor->sig_child( $self->get_process($_[ARG1]), $_[ARG2] )
      if $self->visitor->can('sig_child');
    $self->remove_process( $_[ARG1] );
    $_[KERNEL]->sig_handled();
}

sub _worker_stdout {
    my ($self) = $_[OBJECT];
    $self->visitor->worker_stdout( @_[ ARG0, ARG1 ] )    # $input, $wheel_id
      if $self->visitor->can('worker_stdout');
}

sub _worker_stderr {
    my ($self) = $_[OBJECT];
    $_[ARG1] =~ tr[ -~][]cd;
    $self->visitor->worker_stderr( @_[ ARG0, ARG1 ] )    # $input, $wheel_id
      if $self->visitor->can('worker_stderr');
}

sub _worker_error {
    my ($self) = $_[OBJECT];
    return if $_[ARG0] eq "read" && $_[ARG1] == 0;

    # $operation, $errnum, $errstr, $wheel_id
    $self->visitor->worker_error( @_[ ARG0 .. ARG3 ] )
      if $self->visitor->can('worker_error');
}

sub _worker_done {
    my ($self, $wheel_id) = @_[ OBJECT, ARG0 ];
    my $job = $self->get_job($wheel_id);
    if ($self->visitor->can('worker_done')) {
        if ($job) {
            $self->visitor->worker_done( $job );
        } else {
            $self->visitor->worker_done( $wheel_id );
        }
    }
    $self->delete_worker( $wheel_id );

    # If we have free workers and processes in queue, then dequeue one of them.
    while ( $self->num_workers < $self->max_workers && 
            (my $jobref = $self->dequeue_process)
    ) {
        my ($cmd, $args) = @$jobref;
        # This has to be call(), not yield() so num_workers increments before
        # next loop above.
        $self->call(add_worker => $cmd, $args);
    }
}

sub delete_worker {
    my ( $self, $wheelID ) = @_;
    my $wheel = $self->get_worker($wheelID);
    $self->remove_worker( $wheel->ID );
}

sub _worker_started {
    my ( $self, $wheel_id, $command ) = @_[ OBJECT, ARG0, ARG1 ];
    $DB::single = 1;
    my $job = $self->get_job($wheel_id);
    if ($self->visitor->can('worker_started')) {
        if ($job) {
            $self->visitor->worker_started( $job )
        } else {
            $self->visitor->worker_started( $wheel_id, $command )
        }
    }
}

no Moose;
1;
__END__

=head1 NAME

MooseX::Workers::Engine - Provide the workhorse to MooseX::Workers

=head1 SYNOPSIS

    package MooseX::Workers;

    has Engine => (
        isa      => 'MooseX::Workers::Engine',
        is       => 'ro',
        lazy     => 1,
        required => 1,
        default  => sub { MooseX::Workers::Engine->new( visitor => $_[0] ) },
        handles  => [
            qw(
              max_workers
              has_workers
              num_workers
              put_worker
              kill_worker
              )
        ],
    );

=head1 DESCRIPTION

MooseX::Workers::Engine provides the main functionality 
to MooseX::Workers. It wraps a POE::Session and as many POE::Wheel::Run
objects as it needs.

=head1 ATTRIBUTES

=over 

=item visitor

Hold a reference to our main object so we can use the callbacks on it.

=item max_workers

An Integer specifying the maxium number of workers we have.

=item workers

An ArrayRef of POE::Wheel::Run objects that are our workers.

=item session

Contains the POE::Session that controls the workers.

=back

=head1 METHODS

=over

=item yield

Helper method to post events to our internal manager session.

=item call

Helper method to call events to our internal manager session. 
This is synchronous and will block incoming data from the children 
if it takes too long to return.

=item set_worker($key)

Set the worker at $key

=item get_worker($key)

Retrieve the worker at $key

=item delete_worker($key)

Remove the worker atx $key

=item has_workers

Check to see if we have *any* workers currently. This is delegated to the MooseX::Workers::Engine object.

=item num_workers

Return the current number of workers. This is delegated to the MooseX::Workers::Engine object.

=item has_manager

Check to see if we have a manager session.

=item remove_manager

Remove the manager session.

=item meta

The Metaclass for MooseX::Workers::Engine see Moose's documentation.

=back

=head1 EVENTS

=over 

=item add_worker ($command)

Create a POE::Wheel::Run object to handle $command. If $command holds a scalar, it will be executed as exec($scalar). 
Shell metacharacters will be expanded in this form. If $command holds an array reference, 
it will executed as exec(@$array). This form of exec() doesn't expand shell metacharacters. 
If $command holds a code reference, it will be called in the forked child process, and then 
the child will exit. 

See POE::Wheel::Run for more details.

=back

=head1 INTERFACE 

MooseX::Worker::Engine fires the following callbacks:

=over

=item worker_manager_start

Called when the managing session is started

=item worker_manager_stop

Called when the managing session stops

=item max_workers_reached

Called when we reach the maximum number of workers

=item worker_stdout

Called when a child prints to STDOUT

=item worker_stderr

Called when a child prints to STDERR

=item worker_error

Called when there is an error condition detected with the child.

=item worker_done

Called when a worker completes $command

=item worker_started

Called when a worker starts $command

=item sig_child($PID, $ret)

Called when the mangaging session recieves a SIG CHDL event

=back

=head1 AUTHORS

Chris Prather  C<< <perigrin@cpan.org> >>

Jay Hannah  C<< <jay@jays.net> >>


=head1 LICENCE AND COPYRIGHT

Copyright (c) 2007-2009, Chris Prather C<< <perigrin@cpan.org> >>. All rights reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlartistic>.


=head1 DISCLAIMER OF WARRANTY

BECAUSE THIS SOFTWARE IS LICENSED FREE OF CHARGE, THERE IS NO WARRANTY
FOR THE SOFTWARE, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN
OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES
PROVIDE THE SOFTWARE "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER
EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE
ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE SOFTWARE IS WITH
YOU. SHOULD THE SOFTWARE PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL
NECESSARY SERVICING, REPAIR, OR CORRECTION.

IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING
WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MAY MODIFY AND/OR
REDISTRIBUTE THE SOFTWARE AS PERMITTED BY THE ABOVE LICENCE, BE
LIABLE TO YOU FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL,
OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE
THE SOFTWARE (INCLUDING BUT NOT LIMITED TO LOSS OF DATA OR DATA BEING
RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD PARTIES OR A
FAILURE OF THE SOFTWARE TO OPERATE WITH ANY OTHER SOFTWARE), EVEN IF
SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF
SUCH DAMAGES.

