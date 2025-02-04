package FS::cust_location;
use base qw( FS::geocode_Mixin FS::Record );

use strict;
use vars qw( $import $DEBUG $conf $label_prefix $allow_location_edit );
use Data::Dumper;
use Date::Format qw( time2str );
use FS::UID qw( dbh driver_name );
use FS::Record qw( qsearch qsearchs );
use FS::Conf;
use FS::prospect_main;
use FS::cust_main;
use FS::cust_main_county;
use FS::part_export;
use FS::GeocodeCache;

# Essential fields. Can't be modified in place, will be considered in
# deciding if a location is "new", and (because of that) can't have
# leading/trailing whitespace.
my @essential = (qw(custnum address1 address2 city county state zip country
  location_number location_type location_kind disabled));

$import = 0;

$DEBUG = 0;

FS::UID->install_callback( sub {
  $conf = FS::Conf->new;
  $label_prefix = $conf->config('cust_location-label_prefix') || '';
});

=head1 NAME

FS::cust_location - Object methods for cust_location records

=head1 SYNOPSIS

  use FS::cust_location;

  $record = new FS::cust_location \%hash;
  $record = new FS::cust_location { 'column' => 'value' };

  $error = $record->insert;

  $error = $new_record->replace($old_record);

  $error = $record->delete;

  $error = $record->check;

=head1 DESCRIPTION

An FS::cust_location object represents a customer (or prospect) location.
FS::cust_location inherits from FS::Record.  The following fields are currently
supported:

=over 4

=item locationnum

primary key

=item custnum

Customer (see L<FS::cust_main>).

=item prospectnum

Prospect (see L<FS::prospect_main>).

=item locationname

Optional location name.

=item address1

Address line one (required)

=item address2

Address line two (optional)

=item city

City (if cust_main-no_city_in_address config is set when inserting, this will be forced blank)

=item county

County (optional, see L<FS::cust_main_county>)

=item state

State (see L<FS::cust_main_county>)

=item zip

Zip

=item country

Country (see L<FS::cust_main_county>)

=item geocode

Geocode

=item latitude

=item longitude

=item coord_auto

Flag indicating whether coordinates were obtained automatically or manually
entered

=item addr_clean

Flag indicating whether address has been normalized

=item censustract

=item censusyear

=item district

Tax district code (optional)

=item incorporated

Incorporated city flag: set to 'Y' if the address is in the legal borders 
of an incorporated city.

=item disabled

Disabled flag; set to 'Y' to disable the location.

=back

=head1 METHODS

=over 4

=item new HASHREF

Creates a new location.  To add the location to the database, see L<"insert">.

Note that this stores the hash reference, not a distinct copy of the hash it
points to.  You can ask the object for a copy with the I<hash> method.

=cut

sub table { 'cust_location'; }

=item find_or_insert

Finds an existing location matching the customer and address values in this
location, if one exists, and sets the contents of this location equal to that
one (including its locationnum).

If an existing location is not found, this one I<will> be inserted.  (This is a
change from the "new_or_existing" method that this replaces.)

The following fields are considered "essential" and I<must> match: custnum,
address1, address2, city, county, state, zip, country, location_number,
location_type, location_kind.  Disabled locations will be found only if this
location is set to disabled.

All other fields are considered "non-essential" and will be ignored in 
finding a matching location.  If the existing location doesn't match 
in these fields, it will be updated in-place to match.

Returns an error string if inserting or updating a location failed.

It is unfortunately hard to determine if this created a new location or not.

=cut

sub find_or_insert {
  my $self = shift;

  warn "find_or_insert:\n".Dumper($self) if $DEBUG;

  if ($conf->exists('cust_main-no_city_in_address')) {
    warn "Warning: passed city to find_or_insert when cust_main-no_city_in_address is configured, ignoring it"
      if $self->get('city');
    $self->set('city','');
  }

  # I don't think this is necessary
  #if ( !$self->coord_auto and $self->latitude and $self->longitude ) {
  #  push @essential, qw(latitude longitude);
  #  # but NOT coord_auto; if the latitude and longitude match the geocoded
  #  # values then that's good enough
  #}

  # put nonempty, nonessential fields/values into this hash
  my %nonempty = map { $_ => $self->get($_) }
                 grep {$self->get($_)} $self->fields;
  delete @nonempty{@essential};
  delete $nonempty{'locationnum'};

  my %hash = map { $_ => $self->get($_) } @essential;
  foreach (values %hash) {
    s/^\s+//;
    s/\s+$//;
  }
  my @matches = qsearch('cust_location', \%hash);

  # we no longer reject matches for having different values in nonessential
  # fields; we just alter the record to match
  if ( @matches ) {
    my $old = $matches[0];
    warn "found existing location #".$old->locationnum."\n" if $DEBUG;
    foreach my $field (keys %nonempty) {
      if ($old->get($field) ne $nonempty{$field}) {
        warn "altering $field to match requested location" if $DEBUG;
        $old->set($field, $nonempty{$field});
      }
    } # foreach $field

    if ( $old->modified ) {
      warn "updating non-essential fields\n" if $DEBUG;
      my $error = $old->replace;
      return $error if $error;
    }
    # set $self equal to $old
    foreach ($self->fields) {
      $self->set($_, $old->get($_));
    }
    return "";
  }

  # didn't find a match
  warn "not found; inserting new location\n" if $DEBUG;
  return $self->insert;
}

=item insert

Adds this record to the database.  If there is an error, returns the error,
otherwise returns false.

=cut

sub insert {
  my $self = shift;

  if ($conf->exists('cust_main-no_city_in_address')) {
    warn "Warning: passed city to insert when cust_main-no_city_in_address is configured, ignoring it"
      if $self->get('city');
    $self->set('city','');
  }

  if ( $self->censustract ) {
    $self->set('censusyear' => $conf->config('census_legacy') || 2020);
  }

  my $oldAutoCommit = $FS::UID::AutoCommit;
  local $FS::UID::AutoCommit = 0;
  my $dbh = dbh;

  my $error = $self->SUPER::insert(@_);
  if ( $error ) {
    $dbh->rollback if $oldAutoCommit;
    return $error;
  }

  # If using tax_district_method, for rows in state of Washington,
  # without a tax district already specified, queue a job to find
  # the tax district
  if (
       !$import
    && !$self->district
    && lc $self->state eq 'wa'
    && $conf->config('tax_district_method')
  ) {

    my $queue = new FS::queue {
      'job' => 'FS::geocode_Mixin::process_district_update'
    };
    $error = $queue->insert( ref($self), $self->locationnum );
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      return $error;
    }

  }

  # cust_location exports
  #my $export_args = $options{'export_args'} || [];

  # don't export custnum_pending cases, let follow-up replace handle that
  if ($self->custnum || $self->prospectnum) {
    my @part_export =
      map qsearch( 'part_export', {exportnum=>$_} ),
        $conf->config('cust_location-exports'); #, $agentnum

    foreach my $part_export ( @part_export ) {
      my $error = $part_export->export_insert($self); #, @$export_args);
      if ( $error ) {
        $dbh->rollback if $oldAutoCommit;
        return "exporting to ". $part_export->exporttype.
               " (transaction rolled back): $error";
      }
    }
  }

  $dbh->commit or die $dbh->errstr if $oldAutoCommit;
  '';
}

=item delete

Delete this record from the database.

=item replace OLD_RECORD

Replaces the OLD_RECORD with this one in the database.  If there is an error,
returns the error, otherwise returns false.

=cut

sub replace {
  my $self = shift;
  my $old = shift;
  $old ||= $self->replace_old;

  warn "Warning: passed city to replace when cust_main-no_city_in_address is configured"
    if $conf->exists('cust_main-no_city_in_address') && $self->get('city');

  # the following fields are immutable if this is a customer location. if
  # it's a prospect location, then there are no active packages, no billing
  # history, no taxes, and in general no reason to keep the old location
  # around.
  if ( !$allow_location_edit and $self->custnum ) {
    foreach (qw(address1 address2 city state zip country)) {
      if ( $self->$_ ne $old->$_ ) {
        return "can't change cust_location field $_";
      }
    }
  }

  my $oldAutoCommit = $FS::UID::AutoCommit;
  local $FS::UID::AutoCommit = 0;
  my $dbh = dbh;

  my $error = $self->SUPER::replace($old);
  if ( $error ) {
    $dbh->rollback if $oldAutoCommit;
    return $error;
  }

  # cust_location exports
  #my $export_args = $options{'export_args'} || [];

  # don't export custnum_pending cases, let follow-up replace handle that
  if ($self->custnum || $self->prospectnum) {
    my @part_export =
      map qsearch( 'part_export', {exportnum=>$_} ),
        $conf->config('cust_location-exports'); #, $agentnum

    foreach my $part_export ( @part_export ) {
      my $error = $part_export->export_replace($self, $old); #, @$export_args);
      if ( $error ) {
        $dbh->rollback if $oldAutoCommit;
        return "exporting to ". $part_export->exporttype.
               " (transaction rolled back): $error";
      }
    }
  }

  $dbh->commit or die $dbh->errstr if $oldAutoCommit;
  '';
}


=item check

Checks all fields to make sure this is a valid location.  If there is
an error, returns the error, otherwise returns false.  Called by the insert
and replace methods.

=cut

sub check {
  my $self = shift;

  return '' if $self->disabled; # so that disabling locations never fails

  # whitespace in essential fields leads to problems figuring out if a
  # record is "new"; get rid of it.
  $self->trim_whitespace(@essential);

  my $error = 
    $self->ut_numbern('locationnum')
    || $self->ut_foreign_keyn('prospectnum', 'prospect_main', 'prospectnum')
    || $self->ut_foreign_keyn('custnum', 'cust_main', 'custnum')
    || $self->ut_textn('locationname')
    || $self->ut_text('address1')
    || $self->ut_textn('address2')
    || ($conf->exists('cust_main-no_city_in_address') 
        ? $self->ut_textn('city') 
        : $self->ut_text('city'))
    || $self->ut_textn('county')
    || $self->ut_textn('state')
    || $self->ut_country('country')
    || (!$import && $self->ut_zip('zip', $self->country))
    || $self->ut_coordn('latitude')
    || $self->ut_coordn('longitude')
    || $self->ut_enum('coord_auto', [ '', 'Y' ])
    || $self->ut_enum('addr_clean', [ '', 'Y' ])
    || $self->ut_alphan('location_type')
    || $self->ut_textn('location_number')
    || $self->ut_enum('location_kind', [ '', 'R', 'B' ] )
    || $self->ut_alphan('geocode')
    || $self->ut_alphan('district')
    || $self->ut_numbern('censusyear')
    || $self->ut_flag('incorporated')
  ;
  return $error if $error;
  if ( $self->censustract ne '' ) {
    if ( $self->censustract =~ /^\s*(\d{9})\.?(\d{2})\s*$/ ) { #old
      $self->censustract("$1.$2");
    } elsif ($self->censustract =~ /^\s*(\d{15})\s*$/ ) { #new
      $self->censustract($1);
    } else {
      return "Illegal census tract: ". $self->censustract;
    }
  }

  #yikes... this is ancient, pre-dates cust_location and will be harder to
  # implement now... how do we know this location is a service location from
  # here and not a billing? we can't just check locationnums, we might be new :/
  return "Unit # is required"
    if $conf->exists('cust_main-require_address2')
    && ! $self->address2 =~ /\S/;

  # tricky...we have to allow for the customer to not be inserted yet
  return "No prospect or customer!" unless $self->prospectnum 
                                        || $self->custnum
                                        || $self->get('custnum_pending');
  return "Prospect and customer!"       if $self->prospectnum && $self->custnum;

  return 'Location kind is required'
    if $self->prospectnum
    && $conf->exists('prospect_main-alt_address_format')
    && ! $self->location_kind;

  # Do not allow bad tax district values in cust_location when
  # using Washington State district sales tax calculation - would result
  # in incorrect or missing sales tax on invoices.
  my $tax_district_method = FS::Conf->new->config('tax_district_method');
  if (
    $tax_district_method
    && $tax_district_method eq 'wa_sales'
    && $self->district
  ) {
    my $cust_main_county = qsearchs(
      cust_main_county => { district => $self->district }
    );
    unless ( ref $cust_main_county ) {
      return sprintf (
        'WA State tax district %s does not exist in tax table',
        $self->district
      );
    }
  }

  unless ( $import or qsearch('cust_main_county', {
    'country' => $self->country,
    'state'   => '',
   } ) ) {
    return "Unknown state/county/country: ".
      $self->state. "/". $self->county. "/". $self->country
      unless qsearch('cust_main_county',{
        'state'   => $self->state,
        'county'  => $self->county,
        'country' => $self->country,
      } );
  }

  # set coordinates, unless we already have them
  if (!$import and !$self->latitude and !$self->longitude) {
    $self->set_coord;
  }

  $self->SUPER::check;
}

=item country_full

Returns this location's full country name

=cut

#moved to geocode_Mixin.pm

=item line

Synonym for location_label

=cut

sub line {
  my $self = shift;
  $self->location_label(@_);
}

=item has_ship_address

Returns false since cust_location objects do not have a separate shipping
address.

=cut

sub has_ship_address {
  '';
}

=item location_hash

Returns a list of key/value pairs, with the following keys: address1, address2,
city, county, state, zip, country, geocode, location_type, location_number,
location_kind.

=cut

=item disable_if_unused

Sets the "disabled" flag on the location if it is no longer in use as a 
prospect location, package location, or a customer's billing or default
service address.

=cut

sub disable_if_unused {

  my $self = shift;
  my $locationnum = $self->locationnum;
  return '' if FS::cust_main->count('bill_locationnum = '.$locationnum.' OR
                                     ship_locationnum = '.$locationnum)
            or FS::contact->count(      'locationnum  = '.$locationnum)
            or FS::cust_pkg->count('cancel IS NULL AND 
                                         locationnum  = '.$locationnum)
          ;
  $self->disabled('Y');
  $self->replace;

}

=item move_pkgs

Returns array of cust_pkg objects that would have their location
updated by L</move_to> (all packages that have this location as 
their service address, and aren't canceled, and aren't supplemental 
to another package, and aren't one-time charges that have already been charged.)

=cut

sub move_pkgs {
  my $self = shift;
  my @pkgs = ();
  # find all packages that have the old location as their service address,
  # and aren't canceled,
  # and aren't supplemental to another package
  # and aren't one-time charges that have already been charged
  foreach my $cust_pkg (
    qsearch('cust_pkg', { 
      'locationnum' => $self->locationnum,
      'cancel'      => '',
      'main_pkgnum' => '',
    })
  ) {
    next if $cust_pkg->part_pkg->freq eq '0'
            and ($cust_pkg->setup || 0) > 0;
    push @pkgs, $cust_pkg;
  }
  return @pkgs;
}

=item move_to NEW [ move_pkgs => \@move_pkgs ]

Takes a new L<FS::cust_location> object.  Moves all packages that use the 
existing location to the new one, then sets the "disabled" flag on the old
location.  Returns nothing on success, an error message on error.

Use option I<move_pkgs> to override the list of packages to update
(see L</move_pkgs>.)

=cut

sub move_to {
  my $old = shift;
  my $new = shift;
  my %opt = @_;
  
  warn "move_to:\nFROM:".Dumper($old)."\nTO:".Dumper($new) if $DEBUG;

  local $SIG{HUP} = 'IGNORE';
  local $SIG{INT} = 'IGNORE';
  local $SIG{QUIT} = 'IGNORE';
  local $SIG{TERM} = 'IGNORE';
  local $SIG{TSTP} = 'IGNORE';
  local $SIG{PIPE} = 'IGNORE';

  my $oldAutoCommit = $FS::UID::AutoCommit;
  local $FS::UID::AutoCommit = 0;
  my $dbh = dbh;
  my $error = '';

  # prevent this from failing because of pkg_svc quantity limits
  local( $FS::cust_svc::ignore_quantity ) = 1;

  if ( !$new->locationnum ) {
    $error = $new->insert;
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      return "Error creating location: $error";
    }
  } elsif ( $new->locationnum == $old->locationnum ) {
    # then they're the same location; the normal result of doing a minor
    # location edit
    $dbh->commit if $oldAutoCommit;
    return '';
  }

  my @pkgs;
  if ($opt{'move_pkgs'}) {
    @pkgs = @{$opt{'move_pkgs'}};
    my $pkgerr;
    foreach my $pkg (@pkgs) {
      my $pkgnum = $pkg->pkgnum;
      $pkgerr = "cust_pkg $pkgnum has already been charged"
        if $pkg->part_pkg->freq eq '0'
          and ($pkg->setup || 0) > 0;
      $pkgerr = "cust_pkg $pkgnum is supplemental"
        if $pkg->main_pkgnum;
      $pkgerr = "cust_pkg $pkgnum already cancelled"
        if $pkg->cancel;
      $pkgerr = "cust_pkg $pkgnum does not use this location"
        unless $pkg->locationnum eq $old->locationnum;
      last if $pkgerr;
    }
    if ($pkgerr) {
      $dbh->rollback if $oldAutoCommit;
      return "Cannot update package location: $pkgerr";
    }
  } else {
    @pkgs = $old->move_pkgs;
  }

  foreach my $cust_pkg (@pkgs) {
    $error = $cust_pkg->change(
      'locationnum' => $new->locationnum,
      'keep_dates'  => 1
    );
    if ( $error and not ref($error) ) {
      $dbh->rollback if $oldAutoCommit;
      return "Error moving pkgnum ".$cust_pkg->pkgnum.": $error";
    }
  }

  $error = $old->disable_if_unused;
  if ( $error ) {
    $dbh->rollback if $oldAutoCommit;
    return "Error disabling old location: $error";
  }

  $dbh->commit if $oldAutoCommit;
  '';
}

=item alternize

Attempts to parse data for location_type and location_number from address1
and address2.

=cut

sub alternize {
  my $self = shift;

  return '' if $self->get('location_type')
            || $self->get('location_number');

  my %parse;
  if ( 1 ) { #ikano, switch on via config
    { no warnings 'void';
      eval { 'use FS::part_export::ikano;' };
      die $@ if $@;
    }
    %parse = FS::part_export::ikano->location_types_parse;
  } else {
    %parse = (); #?
  }

  foreach my $from ('address1', 'address2') {
    foreach my $parse ( keys %parse ) {
      my $value = $self->get($from);
      if ( $value =~ s/(^|\W+)$parse\W+(\w+)\W*$//i ) {
        $self->set('location_type', $parse{$parse});
        $self->set('location_number', $2);
        $self->set($from, $value);
        return '';
      }
    }
  }

  #nothing matched, no changes
  $self->get('address2')
    ? "Can't parse unit type and number from address2"
    : '';
}

=item dealternize

Moves data from location_type and location_number to the end of address1.

=cut

sub dealternize {
  my $self = shift;

  #false laziness w/geocode_Mixin.pm::line
  my $lt = $self->get('location_type');
  if ( $lt ) {

    my %location_type;
    if ( 1 ) { #ikano, switch on via config
      { no warnings 'void';
        eval { 'use FS::part_export::ikano;' };
        die $@ if $@;
      }
      %location_type = FS::part_export::ikano->location_types;
    } else {
      %location_type = (); #?
    }

    $self->address1( $self->address1. ' '. $location_type{$lt} || $lt );
    $self->location_type('');
  }

  if ( length($self->location_number) ) {
    $self->address1( $self->address1. ' '. $self->location_number );
    $self->location_number('');
  }
 
  '';
}

=item location_label

Returns the label of the location object.

Options:

=over 4

=item cust_main

Customer object (see L<FS::cust_main>)

=item prospect_main

Prospect object (see L<FS::prospect_main>)

=item join_string

String used to join location elements

=item no_prefix

Don't label the default service location as "Default service location".
May become the default at some point.

=back

=cut

sub location_label {
  my( $self, %opt ) = @_;

  my $prefix = $self->label_prefix(%opt);
  $prefix .= ($opt{join_string} ||  ': ') if $prefix;
  $prefix = '' if $opt{'no_prefix'};

  $prefix . $self->SUPER::location_label(%opt);
}

=item label_prefix

Returns the optional site ID string (based on the cust_location-label_prefix
config option), "Default service location", or the empty string.

Options:

=over 4

=item cust_main

Customer object (see L<FS::cust_main>)

=item prospect_main

Prospect object (see L<FS::prospect_main>)

=back

=cut

sub label_prefix {
  my( $self, %opt ) = @_;

  my $cust_or_prospect = $opt{cust_main} || $opt{prospect_main};
  unless ( $cust_or_prospect ) {
    if ( $self->custnum ) {
      $cust_or_prospect = FS::cust_main->by_key($self->custnum);
    } elsif ( $self->prospectnum ) {
      $cust_or_prospect = FS::prospect_main->by_key($self->prospectnum);
    }
  }

  my $prefix = '';
  if ( $label_prefix eq 'CoStAg' ) {
    my $agent = $conf->config('cust_main-custnum-display_prefix',
                  $cust_or_prospect->agentnum)
                || $cust_or_prospect->agent->agent;
    # else this location is invalid
    $prefix = uc( join('',
        $self->country,
        ($self->state =~ /^(..)/),
        ($agent =~ /^(..)/),
        sprintf('%05d', $self->locationnum)
    ) );

  } elsif ( $label_prefix eq '_location' && $self->locationname ) {
    $prefix = $self->locationname;

  #} elsif (    ( $opt{'cust_main'} || $self->custnum )
  #        && $self->locationnum == $cust_or_prospect->ship_locationnum ) {
  #  $prefix = 'Default service location';
  #}
  } else {
    $prefix = '';
  }

  $prefix;
}

=item county_state_country

Returns a string consisting of just the county, state and country.

=cut

sub county_state_country {
  my $self = shift;
  my $label = $self->country;
  $label = $self->state.", $label" if $self->state;
  $label = $self->county." County, $label" if $self->county;
  $label;
}

=back

=head2 SUBROUTINES

=over 4

=item process_censustract_update LOCATIONNUM

Queueable function to update the census tract to the current year (as set in 
the 'census_year' configuration variable) and retrieve the new tract code.

=cut

sub process_censustract_update {
  eval "use FS::GeocodeCache";
  die $@ if $@;
  my $locationnum = shift;
  my $cust_location = 
    qsearchs( 'cust_location', { locationnum => $locationnum })
      or die "locationnum '$locationnum' not found!\n";

  my $new_year = $conf->config('census_legacy') || 2020;
  my $loc = FS::GeocodeCache->new( $cust_location->location_hash );
  $loc->set_censustract;
  my $error = $loc->get('censustract_error');
  die $error if $error;
  $cust_location->set('censustract', $loc->get('censustract'));
  $cust_location->set('censusyear',  $new_year);
  $error = $cust_location->replace;
  die $error if $error;
  return;
}

=item process_set_coord

Queueable function to find and fill in coordinates for all locations that 
lack them.  Because this uses the Google Maps API, it's internally rate
limited and must run in a single process.

=cut

sub process_set_coord {
  my $job = shift;
  # avoid starting multiple instances of this job
  my @others = qsearch('queue', {
      'status'  => 'locked',
      'job'     => $job->job,
      'jobnum'  => {op=>'!=', value=>$job->jobnum},
  });
  return if @others;

  $job->update_statustext('finding locations to update');
  my @missing_coords = qsearch('cust_location', {
      'disabled'  => '',
      'latitude'  => '',
      'longitude' => '',
  });
  my $i = 0;
  my $n = scalar @missing_coords;
  for my $cust_location (@missing_coords) {
    $cust_location->set_coord;
    my $error = $cust_location->replace;
    if ( $error ) {
      warn "error geocoding location#".$cust_location->locationnum.": $error\n";
    } else {
      $i++;
      $job->update_statustext("updated $i / $n locations");
      dbh->commit; # so that we don't have to wait for the whole thing to finish
      # Rate-limit to stay under the Google Maps usage limit (2500/day).
      # 86,400 / 35 = 2,468 lookups per day.
    }
    sleep 35;
  }
  if ( $i < $n ) {
    die "failed to update ".$n-$i." locations\n";
  }
  return;
}

=item process_standardize [ LOCATIONNUMS ]

Performs address standardization on locations with unclean addresses,
using whatever method you have configured.  If the standardize_* method 
returns a I<clean> address match, the location will be updated.  This is 
always an in-place update (because the physical location is the same, 
and is just being referred to by a more accurate name).

Disabled locations will be skipped, as nobody cares.

If any LOCATIONNUMS are provided, only those locations will be updated.

=cut

sub process_standardize {
  my $job = shift;
  my @others = qsearch('queue', {
      'status'  => 'locked',
      'job'     => $job->job,
      'jobnum'  => {op=>'!=', value=>$job->jobnum},
  });
  return if @others;
  my @locationnums = grep /^\d+$/, @_;
  my $where = "AND locationnum IN(".join(',',@locationnums).")"
    if scalar(@locationnums);
  my @locations = qsearch({
      table     => 'cust_location',
      hashref   => { addr_clean => '', disabled => '' },
      extra_sql => $where,
  });
  my $n_todo = scalar(@locations);
  my $n_done = 0;

  # special: log this
  my $log;
  eval "use Text::CSV";
  open $log, '>', "$FS::UID::cache_dir/process_standardize-" . 
                  time2str('%Y%m%d',time) .
                  ".csv";
  my $csv = Text::CSV->new({binary => 1, eol => "\n"});

  foreach my $cust_location (@locations) {
    $job->update_statustext( int(100 * $n_done/$n_todo) . ",$n_done / $n_todo locations" ) if $job;
    my $result = FS::GeocodeCache->standardize($cust_location);
    if ( $result->{addr_clean} and !$result->{error} ) {
      my @cols = ($cust_location->locationnum);
      foreach (keys %$result) {
        push @cols, $cust_location->get($_), $result->{$_};
        $cust_location->set($_, $result->{$_});
      }
      # bypass immutable field restrictions
      my $error = $cust_location->FS::Record::replace;
      warn "location ".$cust_location->locationnum.": $error\n" if $error;
      $csv->print($log, \@cols);
    }
    $n_done++;
    dbh->commit; # so that we can resume if interrupted
  }
  close $log;
}

sub _upgrade_data {
  my $class = shift;

  # are we going to need to update tax districts?
  my $use_districts = $conf->config('tax_district_method') ? 1 : 0;

  # trim whitespace on records that need it
  local $allow_location_edit = 1;
  foreach my $field (@essential) {
    next if $field eq 'custnum';
    next if $field eq 'disabled';
    foreach my $location (qsearch({
      table => 'cust_location',
      extra_sql => " WHERE disabled IS NULL AND ($field LIKE ' %' OR $field LIKE '% ')"
    })) {
      my $error = $location->replace;
      die "$error (fixing whitespace in $field, locationnum ".$location->locationnum.')'
        if $error;

      if (
        $use_districts
        && !$location->district
        && lc $location->state eq 'wa'
      ) {
        my $queue = new FS::queue {
          'job' => 'FS::geocode_Mixin::process_district_update'
        };
        $error = $queue->insert( 'FS::cust_location' => $location->locationnum );
        die $error if $error;
      }
    } # foreach $location
  } # foreach $field
  '';
}

=head1 BUGS

=head1 SEE ALSO

L<FS::cust_main_county>, L<FS::cust_pkg>, L<FS::Record>,
schema.html from the base documentation.

=cut

1;

