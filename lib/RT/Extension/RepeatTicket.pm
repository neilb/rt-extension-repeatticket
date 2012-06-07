use warnings;
use strict;

package RT::Extension::RepeatTicket;

our $VERSION = "0.01";

use RT::Interface::Web;
use DateTime;
use RT::Date;

my $old_create_ticket = \&HTML::Mason::Commands::CreateTicket;
{
    no warnings 'redefine';

    *HTML::Mason::Commands::CreateTicket = sub {
        my %args = @_;
        my ( $ticket, @actions ) = $old_create_ticket->(@_);
        if ( $ticket && $args{'repeat-enabled'} ) {
            my ( $attr ) = SetRepeatAttribute( $ticket, %args );
            MaybeRepeatMore( $attr );
        }
        return ( $ticket, @actions );
    };
}

sub SetRepeatAttribute {
    my $ticket = shift;
    return 0 unless $ticket;
    my %args = @_;
    my %repeat_args = map { $_ => $args{$_} } grep { /^repeat/ } keys %args;

    my ( $old_attr ) = $ticket->Attributes->Named('RepeatTicketSettings');
    my %old;
    %old = %{$old_attr->Content} if $old_attr;

    my $content = { %old, %repeat_args, tickets => [ $ticket->id ] };

    $ticket->SetAttribute(
        Name    => 'RepeatTicketSettings',
        Content => $content,
    );

    my ( $attr ) = $ticket->Attributes->Named('RepeatTicketSettings');

    return ( $attr, $ticket->loc('Recurrence updated') );    # loc
}

use RT::Ticket;

sub Run {
    my $attr = shift;
    my $content = $attr->Content;
    return unless $content->{'repeat-enabled'};

    my $checkday = shift
      || DateTime->today( time_zone => RT->Config->Get('Timezone') );
    RepeatTicket( $attr, $checkday );
    MaybeRepeatMore( $attr ); # create more to meet the coexistent number
}

sub RepeatTicket {
    my $attr = shift;
    my @checkdays = @_;
    my @ids;

    my $content = $attr->Content;
    return unless $content->{'repeat-enabled'};

    for my $checkday (@checkdays) {
        my $repeat_ticket = $attr->Object;

        if ( $content->{'repeat-start-date'} ) {
            my $date = RT::Date->new( RT->SystemUser );
            $date->Set(
                Format => 'unknown',
                Value  => $content->{'repeat-start-date'},
            );
            next unless $checkday->ymd ge $date->Date;
        }

        if ( $content->{'repeat-end'} && $content->{'repeat-end'} eq 'number' )
        {
            return
              unless $content->{'repeat-end-number'} >
                  $content->{'repeat-occurrences'};
        }

        if ( $content->{'repeat-end'} && $content->{'repeat-end'} eq 'date' ) {
            my $date = RT::Date->new( RT->SystemUser );
            $date->Set(
                Format => 'unknown',
                Value  => $content->{'repeat-end-date'},
            );
            next unless $checkday->ymd lt $date->Date;
        }

        my $last_ticket;
        if ( $content->{'last-ticket'} ) {
            $last_ticket = RT::Ticket->new( RT->SystemUser );
            $last_ticket->Load( $content->{'last-ticket'} );
        }

        $last_ticket ||= $repeat_ticket;

        my $due_date = $checkday->clone;

        if ( $content->{'repeat-type'} eq 'daily' ) {
            if ( $content->{'repeat-details-daily'} eq 'day' ) {
                my $span = $content->{'repeat-details-daily-day'} || 1;
                my $date = $checkday->clone;
                $date->subtract( days => $span );
                next unless CheckLastTicket( $date, $last_ticket );

                $due_date->add( days => $span );
            }
            elsif ( $content->{'repeat-details-daily'} eq 'weekday' ) {
                return
                  unless $checkday->day_of_week >= 1
                      && $checkday->day_of_week <= 5;
                if ( $checkday->day_of_week == 5 ) {
                    $due_date->add( days => 3 );
                }
                else {
                    $due_date->add( days => 1 );
                }
            }
            elsif ( $content->{'repeat-details-daily'} eq 'complete' ) {
                return
                  unless $last_ticket->QueueObj->Lifecycle->IsInactive(
                    $last_ticket->Status );
                my $resolved = $last_ticket->ResolvedObj;
                my $date     = $checkday->clone;
                $date->subtract(
                    days => $content->{'repeat-details-daily-complete'} || 1 );
                next if $resolved->Date gt $date->ymd;
            }

        }
        elsif ( $content->{'repeat-type'} eq 'weekly' ) {
            if ( $content->{'repeat-details-weekly'} eq 'week' ) {
                my $span = $content->{'repeat-details-weekly-week'} || 1;
                my $date = $checkday->clone;

                # go to the end of the week
                $date->subtract(
                    weeks => $span - 1,
                    days  => $checkday->day_of_week
                );
                next unless CheckLastTicket( $date, $last_ticket );

                my $weeks = $content->{'repeat-details-weekly-weeks'};
                next unless $weeks;

                $weeks = [$weeks] unless ref $weeks;
                next unless grep { $_ == $checkday->day_of_week } @$weeks;

                $due_date->add( weeks => $span );
                $due_date->subtract( days => $due_date->day_of_week );
                my ($first) = sort @$weeks;
                $due_date->add( days => $first ) if $first;
            }
            elsif ( $content->{'repeat-details-weekly'} eq 'complete' ) {
                return
                  unless $last_ticket->QueueObj->Lifecycle->IsInactive(
                    $last_ticket->Status );
                my $resolved = $last_ticket->ResolvedObj;
                my $date     = $checkday->clone;
                $date->subtract(
                    weeks => $content->{'repeat-details-weekly-complete'}
                      || 1 );
                next if $resolved->Date gt $date->ymd;
            }
        }
        elsif ( $content->{'repeat-type'} eq 'monthly' ) {
            if ( $content->{'repeat-details-monthly'} eq 'day' ) {
                my $day = $content->{'repeat-details-monthly-day-day'} || 1;
                next unless $day == $checkday->day_of_month;

                my $span = $content->{'repeat-details-monthly-day-month'} || 1;
                my $date = $checkday->clone;
                $date->subtract( months => $span );
                next unless CheckLastTicket( $date, $last_ticket );

                $due_date->add( months => $span );
            }
            elsif ( $content->{'repeat-details-monthly'} eq 'week' ) {
                my $day = $content->{'repeat-details-monthly-week-week'} || 0;
                next unless $day == $checkday->day_of_week;

                my $number = $content->{'repeat-details-monthly-week-number'}
                  || 1;
                return
                  unless $number ==
                      int( ( $checkday->day_of_month - 1 ) / 7 ) + 1;

                my $span = $content->{'repeat-details-monthly-week-month'} || 1;
                my $date = $checkday->clone;
                $date->subtract( months => $span );
                next unless CheckLastTicket( $date, $last_ticket );

                $due_date->add( months => $span );
                $due_date->subtract( days => $due_date->day_of_month - 1 );
                $due_date->add( weeks => $number - 1 );
                if ( $day > $due_date->day_of_week ) {
                    $due_date->add( days => $day - $due_date->day_of_week );
                }
                elsif ( $day < $due_date->day_of_week ) {
                    $due_date->add( days => 7 + $day - $due_date->day_of_week );
                }
            }
            elsif ( $content->{'repeat-details-monthly'} eq 'complete' ) {
                return
                  unless $last_ticket->QueueObj->Lifecycle->IsInactive(
                    $last_ticket->Status );
                my $resolved = $last_ticket->ResolvedObj;
                my $date     = $checkday->clone;
                $date->subtract(
                    months => $content->{'repeat-details-monthly-complete'}
                      || 1 );
                next if $resolved->Date gt $date->ymd;
            }
        }
        elsif ( $content->{'repeat-type'} eq 'yearly' ) {
            if ( $content->{'repeat-details-yearly'} eq 'day' ) {
                my $day = $content->{'repeat-details-yearly-day-day'} || 1;
                next unless $day == $checkday->day_of_month;

                my $month = $content->{'repeat-details-yearly-day-month'} || 1;
                next unless $month == $checkday->month;
                $due_date->add( years => 1 );
            }
            elsif ( $content->{'repeat-details-yearly'} eq 'week' ) {
                my $day = $content->{'repeat-details-yearly-week-week'} || 0;
                next unless $day == $checkday->day_of_week;

                my $month = $content->{'repeat-details-yearly-week-month'} || 1;
                next unless $month == $checkday->month;

                my $number = $content->{'repeat-details-yearly-week-number'}
                  || 1;
                return
                  unless $number ==
                      int( ( $checkday->day_of_month - 1 ) / 7 ) + 1;

                $due_date->add( year => 1 );
                $due_date->subtract( days => $due_date->day_of_month - 1 );
                $due_date->add( weeks => $number - 1 );
                if ( $day > $due_date->day_of_week ) {
                    $due_date->add( days => $day - $due_date->day_of_week );
                }
                elsif ( $day < $due_date->day_of_week ) {
                    $due_date->add( days => 7 + $day - $due_date->day_of_week );
                }
            }
            elsif ( $content->{'repeat-details-yearly'} eq 'complete' ) {
                return
                  unless $last_ticket->QueueObj->Lifecycle->IsInactive(
                    $last_ticket->Status );
                my $resolved = $last_ticket->ResolvedObj;
                my $date     = $checkday->clone;
                $date->subtract(
                    years => $content->{'repeat-details-yearly-complete'}
                      || 1 );
                return
                  if $resolved->Date gt $date->ymd;
            }
        }

        # use RT::Date to work around the timezone issue
        my $starts = RT::Date->new( RT->SystemUser );
        $starts->Set( Format => 'unknown', Value => $checkday->ymd );

        my $due = RT::Date->new( RT->SystemUser );
        $due->Set( Format => 'unknown', Value => $due_date->ymd );

        my ( $id, $txn, $msg ) = _RepeatTicket(
            $repeat_ticket,
            Starts => $starts->ISO,
            $due_date eq $checkday
            ? ()
            : ( Due => $due->ISO ),
        );

        if ($id) {
            $RT::Logger->info(
                "Repeated Ticket $id for " . $repeat_ticket->id );
            $content->{'repeat-occurrences'} += $id;
            $content->{'last-ticket'} = $id;
            push @{ $content->{'tickets'} }, $id;
        }
        else {
            $RT::Logger->error( "Failed to repeat ticket for "
                  . $repeat_ticket->id
                  . ": $msg" );
            next;
        }
    }

    $attr->SetContent($content);
    return @ids;
}

sub _RepeatTicket {
    my $repeat_ticket = shift;
    return unless $repeat_ticket;

    my %args  = @_;
    my $repeat = {
        Queue           => $repeat_ticket->Queue,
        Requestor       => join( ',', $repeat_ticket->RequestorAddresses ),
        Cc              => join( ',', $repeat_ticket->CcAddresses ),
        AdminCc         => join( ',', $repeat_ticket->AdminCcAddresses ),
        InitialPriority => $repeat_ticket->Priority,
    };

    $repeat->{$_} = $repeat_ticket->$_()
      for qw/Owner Subject FinalPriority TimeEstimated/;

    my $members = $repeat_ticket->Members;
    my ( @members, @members_of, @refers, @refers_by, @depends, @depends_by );
    my $refers         = $repeat_ticket->RefersTo;
    my $get_link_value = sub {
        my ( $link, $type ) = @_;
        my $uri_method   = $type . 'URI';
        my $local_method = 'Local' . $type;
        my $uri          = $link->$uri_method;
        return
          if $uri->IsLocal
              and $uri->Object
              and $uri->Object->isa('RT::Ticket')
              and $uri->Object->Type eq 'reminder';

        return $link->$local_method || $uri->URI;
    };
    while ( my $refer = $refers->Next ) {
        my $refer_value = $get_link_value->( $refer, 'Target' );
        push @refers, $refer_value if defined $refer_value;
    }
    $repeat->{'new-RefersTo'} = join ' ', @refers;

    my $refers_by = $repeat_ticket->ReferredToBy;
    while ( my $refer_by = $refers_by->Next ) {
        my $refer_by_value = $get_link_value->( $refer_by, 'Base' );
        push @refers_by, $refer_by_value if defined $refer_by_value;
    }
    $repeat->{'RefersTo-new'} = join ' ', @refers_by;

    my $cfs = $repeat_ticket->QueueObj->TicketCustomFields();
    while ( my $cf = $cfs->Next ) {
        my $cf_id     = $cf->id;
        my $cf_values = $repeat_ticket->CustomFieldValues( $cf->id );
        my @cf_values;
        while ( my $cf_value = $cf_values->Next ) {
            push @cf_values, $cf_value->Content;
        }
        $repeat->{"Object-RT::Ticket--CustomField-$cf_id-Value"} = join "\n",
          @cf_values;
    }

    $repeat->{Status} = 'new';

    for ( keys %$repeat ) {
        $args{$_} = $repeat->{$_} if not defined $args{$_};
    }

    my $txns = $repeat_ticket->Transactions;
    $txns->Limit( FIELD => 'Type', VALUE => 'Create' );
    $txns->OrderBy( FIELD => 'id', ORDER => 'ASC' );
    $txns->RowsPerPage(1);
    my $txn = $txns->First;
    my $atts = RT::Attachments->new(RT->SystemUser);
    $atts->OrderBy( FIELD => 'id', ORDER => 'ASC' );
    $atts->Limit( FIELD => 'TransactionId', VALUE => $txn->id );
    $atts->Limit( FIELD => 'Parent',        VALUE => 0 );
    my $top = $atts->First;

    # XXX no idea why this doesn't work:
    # $args{MIMEObj} = $top->ContentAsMIME( Children => 1 ) );

    my $parser = RT::EmailParser->new( RT->SystemUser );
    $args{MIMEObj} =
      $parser->ParseMIMEEntityFromScalar(
        $top->ContentAsMIME( Children => 1 )->as_string );

    my $ticket = RT::Ticket->new( $repeat_ticket->CurrentUser );
    return $ticket->Create(%args);
}

sub MaybeRepeatMore {
    my $attr     = shift;
    my $content = $attr->Content;

    my $co_number = RT->Config->Get('RepeatTicketCoexistentNumber') || 1;
    my $tickets = $content->{tickets} || [];
    my $last_ticket = RT::Ticket->new( RT->SystemUser );
    if ( $tickets->[-1] ) {
        $last_ticket->Load($tickets->[-1]);
    }

    my $date = $last_ticket && $last_ticket->DueObj->Unix
      ? DateTime->from_epoch(
        epoch     => $last_ticket->DueObj->Unix - 3600*24,
        time_zone => RT->Config->Get('Timezone')
      )
      : DateTime->today( time_zone => RT->Config->Get('Timezone') );

    @$tickets = grep {
        my $t = RT::Ticket->new( RT->SystemUser );
        $t->Load($_);
        !$t->QueueObj->Lifecycle->IsInactive( $t->Status );
    } @$tickets;

    $content->{tickets} = $tickets;
    $attr->SetContent( $content );

    my @ids;
    if ( $co_number > @$tickets ) {
        my $total = $co_number - @$tickets;
        my @dates;
        if ( $content->{'repeat-type'} eq 'daily' ) {
            if ( $content->{'repeat-details-daily'} eq 'day' ) {
                my $span = $content->{'repeat-details-daily-day'} || 1;
                for ( 1 .. $total ) {
                    $date->add( days => 1 );
                    push @dates, $date->clone;
                }
            }
            elsif ( $content->{'repeat-details-daily'} eq 'weekday' ) {
                while ( @dates < $total ) {
                    $date->add( days => 1 );
                    push @dates, $date->clone
                      if $date->day_of_week >= 1 && $date->day_of_week <= 5;
                }
            }
        }
        elsif ( $content->{'repeat-type'} eq 'weekly' ) {
            if ( $content->{'repeat-details-weekly'} eq 'week' ) {
                my $weeks = $content->{'repeat-details-weekly-weeks'};
                if ($weeks) {
                    while ( @dates < $total ) {
                        $date->add( days => 1 );
                        $weeks = [$weeks] unless ref $weeks;
                        if ( grep { $date->day_of_week == $_ } @$weeks ) {

                            push @dates, $date->clone;
                        }

                        if (   $date->day_of_week == 0
                            && $content->{'repeat-details-weekly-week'} )
                        {
                            $date->add( weeks =>
                                  $content->{'repeat-details-weekly-week'} -
                                  1 );
                        }
                    }
                }
            }
        }
        elsif ( $content->{'repeat-type'} eq 'monthly' ) {
            if ( $content->{'repeat-details-monthly'} eq 'day' ) {
                my $span = $content->{'repeat-details-monthly-day-month'} || 1;
                $date->set( day => $content->{'repeat-details-monthly-day-day'}
                      || 1 );

                for ( 1 .. $total ) {
                    $date->add( months => $span );
                    push @dates, $date->clone;
                }
            }
            elsif ( $content->{'repeat-details-monthly'} eq 'week' ) {
                my $span = $content->{'repeat-details-monthly-week-month'} || 1;
                my $number = $content->{'repeat-details-monthly-week-number'}
                  || 1;
                my $day = $content->{'repeat-details-monthly-week-day'} || 1;

                for ( 1 .. $total ) {
                    $date->add( months => $span );
                    $date->subtract( days => $date->day_of_month - 1 );
                    $date->add( weeks => $number - 1 );

                    if ( $day > $date->day_of_week ) {
                        $date->add( days => $day - $date->day_of_week );
                    }
                    elsif ( $day < $date->day_of_week ) {
                        $date->add( days => 7 + $day - $date->day_of_week );
                    }
                    push @dates, $date->clone;
                }
            }
        }
        elsif ( $content->{'repeat-type'} eq 'yearly' ) {
            if ( $content->{'repeat-details-yearly'} eq 'day' ) {
                $date->set( day => $content->{'repeat-details-yearly-day-day'}
                      || 1 );
                $date->set(
                    month => $content->{'repeat-details-yearly-day-month'}
                      || 1 );
                for ( 1 .. $total ) {
                    $date->add( years => 1 );
                    push @dates, $date->clone;
                }
            }
            elsif ( $content->{'repeat-details-yearly'} eq 'week' ) {
                $date->set(
                    month => $content->{'repeat-details-yearly-week-month'}
                      || 1 );

                my $number = $content->{'repeat-details-yearly-week-number'}
                  || 1;
                my $day = $content->{'repeat-details-yearly-week-day'} || 1;

                for ( 1 .. $total ) {
                    $date->add( years => 1 );
                    $date->subtract( days => $date->day_of_month - 1 );
                    $date->add( weeks => $number - 1 );
                    if ( $day > $date->day_of_week ) {
                        $date->add( days => $day - $date->day_of_week );
                    }
                    elsif ( $day < $date->day_of_week ) {
                        $date->add( days => 7 + $day - $date->day_of_week );
                    }
                    push @dates, $date->clone;
                }
            }
        }

        for my $date (@dates) {
            RepeatTicket( $attr, @dates );
        }
    }
}

sub CheckLastTicket {
    my $date = shift;
    my $last_ticket = shift;
    if ( $last_ticket->DueObj->Unix ) {
        my $due = $last_ticket->DueObj;
        $due->AddDays(-1);
        if ( $date->ymd ge $due->Date( Timezone => 'user' ) ) {
            return 1;
        }
        else {
            return 0;
        }
    }

    if ( $date->ymd ge $last_ticket->CreatedObj->Date( Timezone => 'user' ) ) {
        return 1;
    }
    else {
        return 0;
    }
}

1;
__END__

=head1 NAME

RT::Extension::RepeatTicket - The great new RT::Extension::RepeatTicket!

=head1 VERSION

Version 0.01

=head1 INSTALLATION

To install this module, run the following commands:

    perl Makefile.PL
    make
    make install

add RT::Extension::RepeatTicket to @Plugins in RT's etc/RT_SiteConfig.pm:

    Set( $RepeatTicketCoexistentNumber, 1 );
    Set( @Plugins, qw(... RT::Extension::RepeatTicket) );

C<$RepeatTicketCoexistentNumber> only works for repeats that don't reply on
the completion of previous tickets, in which case the config will be simply
ignored.

=head1 AUTHOR

sunnavy, <sunnavy at bestpractical.com>


=head1 LICENSE AND COPYRIGHT

Copyright 2012 Best Practical Solutions, LLC.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.

