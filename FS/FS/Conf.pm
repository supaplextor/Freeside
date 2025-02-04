package FS::Conf;

use strict;
use vars qw( $base_dir @config_items @base_items @card_types @invoice_terms
             $DEBUG
             $conf_cache $conf_cache_enabled
           );
use Carp;
use IO::File;
use File::Basename;
use MIME::Base64;
use Locale::Currency;
use Email::Address;
use FS::ConfItem;
use FS::ConfDefaults;
use FS::Locales;
use FS::payby;
use FS::conf;
use FS::Record qw(qsearch qsearchs);
use FS::UID qw(dbh datasrc);
use FS::Misc::Invoicing qw( spool_formats );

$base_dir = '%%%FREESIDE_CONF%%%';

$DEBUG = 0;

$conf_cache_enabled = 0;

=head1 NAME

FS::Conf - Freeside configuration values

=head1 SYNOPSIS

  use FS::Conf;

  $conf = new FS::Conf;

  $value = $conf->config('key');
  @list  = $conf->config('key');
  $bool  = $conf->exists('key');

  $conf->touch('key');
  $conf->set('key' => 'value');
  $conf->delete('key');

  @config_items = $conf->config_items;

=head1 DESCRIPTION

Read and write Freeside configuration values.  Keys currently map to filenames,
but this may change in the future.

=head1 METHODS

=over 4

=item new [ HASHREF ]

Create a new configuration object.

HASHREF may contain options to set the configuration context.  Currently 
accepts C<locale>, and C<localeonly> to disable fallback to the null locale.

=cut

sub new {
  my($proto) = shift;
  my $opts = shift || {};
  my($class) = ref($proto) || $proto;
  my $self = {
    'base_dir'    => $base_dir,
    'locale'      => $opts->{locale},
    'localeonly'  => $opts->{localeonly}, # for config-view.cgi ONLY
  };
  warn "FS::Conf created with no locale fallback.\n" if $self->{localeonly};
  bless ($self, $class);
}

=item base_dir

Returns the base directory.  By default this is /usr/local/etc/freeside.

=cut

sub base_dir {
  my($self) = @_;
  my $base_dir = $self->{base_dir};
  -e $base_dir or die "FATAL: $base_dir doesn't exist!";
  -d $base_dir or die "FATAL: $base_dir isn't a directory!";
  -r $base_dir or die "FATAL: Can't read $base_dir!";
  -x $base_dir or die "FATAL: $base_dir not searchable (executable)!";
  $base_dir =~ /^(.*)$/;
  $1;
}

=item conf KEY [ AGENTNUM [ NODEFAULT ] ]

Returns the L<FS::conf> record for the key and agent.

=cut

sub conf {
  my $self = shift;
  $self->_config(@_);
}

=item config KEY [ AGENTNUM [ NODEFAULT ] ]

Returns the configuration value or values (depending on context) for key.
The optional agent number selects an agent specific value instead of the
global default if one is present.  If NODEFAULT is true only the agent
specific value(s) is returned.

=cut

sub _config {
  my($self,$name,$agentnum,$agentonly)=@_;
  my $hashref = { 'name' => $name };
  local $FS::Record::conf = undef;  # XXX evil hack prevents recursion
  $conf_cache = undef unless $conf_cache_enabled; # use cache only when it is
                                                  # safe to do so
  my $cv;
  my @a = (
    ($agentnum || ()),
    ($agentonly && $agentnum ? () : '')
  );
  my @l = (
    ($self->{locale} || ()),
    ($self->{localeonly} && $self->{locale} ? () : '')
  );
  # try with the agentnum first, then fall back to no agentnum if allowed
  foreach my $a (@a) {
    $hashref->{agentnum} = $a;
    foreach my $l (@l) {
      my $key = join(':',$name, $a, $l);
      if (! exists $conf_cache->{$key}){
        $hashref->{locale} = $l;
        # $conf_cache is reset in FS::UID during myconnect, so the cache is
        # reset per connection
        $conf_cache->{$key} = FS::Record::qsearchs('conf', $hashref);
      }
      return $conf_cache->{$key} if $conf_cache->{$key};
    }
  }
  return undef;
}

sub config {
  my $self = shift;

  carp "FS::Conf->config(". join(', ', @_). ") called"
    if $DEBUG > 1;

  my $cv = $self->_config(@_) or return;

  if ( wantarray ) {
    my $v = $cv->value;
    chomp $v;
    (split "\n", $v, -1);
  } else {
    (split("\n", $cv->value))[0];
  }
}

=item config_binary KEY [ AGENTNUM [ NODEFAULT ] ]

Returns the exact scalar value for key.

=cut

sub config_binary {
  my $self = shift;

  my $cv = $self->_config(@_) or return;
  length($cv->value) ? decode_base64($cv->value) : '';
}

=item exists KEY [ AGENTNUM [ NODEFAULT ] ]

Returns true if the specified key exists, even if the corresponding value
is undefined.

=cut

sub exists {
  my $self = shift;

  #my($name, $agentnum)=@_;

  carp "FS::Conf->exists(". join(', ', @_). ") called"
    if $DEBUG > 1;

  defined($self->_config(@_));
}

#maybe this should just be the new exists instead of getting a method of its
#own, but i wanted to avoid possible fallout

sub config_bool {
  my $self = shift;

  my($name,$agentnum,$agentonly) = @_;

  carp "FS::Conf->config_bool(". join(', ', @_). ") called"
    if $DEBUG > 1;

  #defined($self->_config(@_));

  #false laziness w/_config
  my $hashref = { 'name' => $name };
  local $FS::Record::conf = undef;  # XXX evil hack prevents recursion
  my $cv;
  my @a = (
    ($agentnum || ()),
    ($agentonly && $agentnum ? () : '')
  );
  my @l = (
    ($self->{locale} || ()),
    ($self->{localeonly} && $self->{locale} ? () : '')
  );
  # try with the agentnum first, then fall back to no agentnum if allowed
  foreach my $a (@a) {
    $hashref->{agentnum} = $a;
    foreach my $l (@l) {
      $hashref->{locale} = $l;
      $cv = FS::Record::qsearchs('conf', $hashref);
      if ( $cv ) {
        if ( $cv->value eq '0'
               && ($hashref->{agentnum} || $hashref->{locale} )
           ) 
        {
          return 0; #an explicit false override, don't continue looking
        } else {
          return 1;
        }
      }
    }
  }
  return 0;

}

=item config_orbase KEY SUFFIX

Returns the configuration value or values (depending on context) for 
KEY_SUFFIX, if it exists, otherwise for KEY

=cut

# outmoded as soon as we shift to agentnum based config values
# well, mostly.  still useful for e.g. late notices, etc. in that we want
# these to fall back to standard values
sub config_orbase {
  my $self = shift;

  my( $name, $suffix ) = @_;
  if ( $self->exists("${name}_$suffix") ) {
    $self->config("${name}_$suffix");
  } else {
    $self->config($name);
  }
}

=item key_orbase KEY SUFFIX

If the config value KEY_SUFFIX exists, returns KEY_SUFFIX, otherwise returns
KEY.  Useful for determining which exact configuration option is returned by
config_orbase.

=cut

sub key_orbase {
  my $self = shift;

  my( $name, $suffix ) = @_;
  if ( $self->exists("${name}_$suffix") ) {
    "${name}_$suffix";
  } else {
    $name;
  }
}

=item invoice_templatenames

Returns all possible invoice template names.

=cut

sub invoice_templatenames {
  my( $self ) = @_;

  my %templatenames = ();
  foreach my $item ( $self->config_items ) {
    foreach my $base ( @base_items ) {
      my( $main, $ext) = split(/\./, $base);
      $ext = ".$ext" if $ext;
      if ( $item->key =~ /^${main}_(.+)$ext$/ ) {
      $templatenames{$1}++;
      }
    }
  }
  
  map { $_ } #handle scalar context
  sort keys %templatenames;

}

=item touch KEY [ AGENT ];

Creates the specified configuration key if it does not exist.

=cut

sub touch {
  my $self = shift;

  my($name, $agentnum) = @_;
  #unless ( $self->exists($name, $agentnum) ) {
  unless ( $self->config_bool($name, $agentnum) ) {
    if ( $agentnum && $self->exists($name) && $self->config($name,$agentnum) eq '0' ) {
      $self->delete($name, $agentnum);
    } else {
      $self->set($name, '', $agentnum);
    }
  }
}

=item set KEY VALUE [ AGENTNUM ];

Sets the specified configuration key to the given value.

=cut

sub set {
  my $self = shift;

  my($name, $value, $agentnum) = @_;
  $value =~ /^(.*)$/s;
  $value = $1;

  warn "[FS::Conf] SET $name\n" if $DEBUG;

  my $hashref = {
    name => $name,
    agentnum => $agentnum,
    locale => $self->{locale}
  };

  my $old = FS::Record::qsearchs('conf', $hashref);
  my $new = new FS::conf { $old ? $old->hash : %$hashref };
  $new->value($value);

  my $error;
  if ($old) {
    $error = $new->replace($old);
  } else {
    $error = $new->insert;
  }

  if (! $error) {
    # clean the object cache
    my $key = join(':',$name, $agentnum, $self->{locale});
    $conf_cache->{ $key } = $new;
  }

  die "error setting configuration value: $error \n"
    if $error;

}

=item set_binary KEY VALUE [ AGENTNUM ]

Sets the specified configuration key to an exact scalar value which
can be retrieved with config_binary.

=cut

sub set_binary {
  my $self  = shift;

  my($name, $value, $agentnum)=@_;
  $self->set($name, encode_base64($value), $agentnum);
}

=item delete KEY [ AGENTNUM ];

Deletes the specified configuration key.

=cut

sub delete {
  my $self = shift;

  my($name, $agentnum) = @_;
  if ( my $cv = FS::Record::qsearchs('conf', {name => $name, agentnum => $agentnum, locale => $self->{locale}}) ) {
    warn "[FS::Conf] DELETE $name\n" if $DEBUG;

    my $oldAutoCommit = $FS::UID::AutoCommit;
    local $FS::UID::AutoCommit = 0;
    my $dbh = dbh;

    my $error = $cv->delete;

    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      die "error setting configuration value: $error \n"
    }

    $dbh->commit or die $dbh->errstr if $oldAutoCommit;

  }
}

#maybe this should just be the new delete instead of getting a method of its
#own, but i wanted to avoid possible fallout

sub delete_bool {
  my $self = shift;

  my($name, $agentnum) = @_;

  warn "[FS::Conf] DELETE $name\n" if $DEBUG;

  my $cv = FS::Record::qsearchs('conf', { name     => $name,
                                          agentnum => $agentnum,
                                          locale   => $self->{locale},
                                        });

  if ( $cv ) {
    my $error = $cv->delete;
    die $error if $error;
  } elsif ( $agentnum ) {
    $self->set($name, '0', $agentnum);
  }

}

=item import_config_item CONFITEM DIR 

  Imports the item specified by the CONFITEM (see L<FS::ConfItem>) into
the database as a conf record (see L<FS::conf>).  Imports from the file
in the directory DIR.

=cut

sub import_config_item { 
  my ($self,$item,$dir) = @_;
  my $key = $item->key;
  if ( -e "$dir/$key" ) {
    warn "Inserting $key\n" if $DEBUG;
    local $/;
    my $value = readline(new IO::File "$dir/$key");
    if ($item->type =~ /^(binary|image)$/ ) {
      $self->set_binary($key, $value);
    }else{
      $self->set($key, $value);
    }
  } else {
    warn "Not inserting $key\n" if $DEBUG;
  }
}

#item _orbase_items OPTIONS
#
#Returns all of the possible extensible config items as FS::ConfItem objects.
#See #L<FS::ConfItem>.  OPTIONS consists of name value pairs.  Possible
#options include
#
# dir - the directory to search for configuration option files instead
#       of using the conf records in the database
#
#cut

#quelle kludge
sub _orbase_items {
  my ($self, %opt) = @_; 

  my $listmaker = sub { my $v = shift;
                        $v =~ s/_/!_/g;
                        if ( $v =~ /\.(png|eps)$/ ) {
                          $v =~ s/\./!_%./;
                        }else{
                          $v .= '!_%';
                        }
                        map { $_->name }
                          FS::Record::qsearch( 'conf',
                                               {},
                                               '',
                                               "WHERE name LIKE '$v' ESCAPE '!'"
                                             );
                      };

  if (exists($opt{dir}) && $opt{dir}) {
    $listmaker = sub { my $v = shift;
                       if ( $v =~ /\.(png|eps)$/ ) {
                         $v =~ s/\./_*./;
                       }else{
                         $v .= '_*';
                       }
                       map { basename $_ } glob($opt{dir}. "/$v" );
                     };
  }

  ( map { 
          my $proto;
          my $base = $_;
          for ( @config_items ) { $proto = $_; last if $proto->key eq $base;  }
          die "don't know about $base items" unless $proto->key eq $base;

          map { new FS::ConfItem { 
                  'key'         => $_,
                  'base_key'    => $proto->key,
                  'section'     => $proto->section,
                  'description' => 'Alternate ' . $proto->description . '  See the <a href="http://www.freeside.biz/mediawiki/index.php/Freeside:3:Documentation:Administration#Invoice_templates">billing documentation</a> for details.',
                  'type'        => $proto->type,
                };
              } &$listmaker($base);
        } @base_items,
  );
}

=item config_items

Returns all of the possible global/default configuration items as
FS::ConfItem objects.  See L<FS::ConfItem>.

=cut

sub config_items {
  my $self = shift; 

  ( @config_items, $self->_orbase_items(@_) );
}

=item invoice_from_full [ AGENTNUM ]

Returns values of invoice_from and invoice_from_name (or, if that is not
defined, company_name), appropriately combined based on their current values.

=cut

sub invoice_from_full {
  my ($self, $agentnum) = @_;

  my $name =  $self->config('invoice_from_name', $agentnum)
           || $self->config('company_name', $agentnum);

  Email::Address->new( $name => $self->config('invoice_from', $agentnum ) )
    ->format;
}

=back

=head1 SUBROUTINES

=over 4

=item init-config DIR

Imports the configuration items from DIR (1.7 compatible)
to conf records in the database.

=cut

sub init_config {
  my $dir = shift;

  my $conf = new FS::Conf;
  foreach my $item ( $conf->config_items(dir => $dir) ) {
    $conf->import_config_item($item, $dir);
  }

  '';  #success
}

=back

=head1 BUGS

If this was more than just crud that will never be useful outside Freeside I'd
worry that config_items is freeside-specific and icky.

=head1 SEE ALSO

"Configuration" in the web interface (config/config.cgi).

=cut

#Business::CreditCard
@card_types = (
  "VISA card",
  "MasterCard",
  "Discover card",
  "American Express card",
  "Diner's Club/Carte Blanche",
  "enRoute",
  "JCB",
  "BankCard",
  "Switch",
  "Solo",
);

@base_items = qw(
invoice_template
invoice_latex
invoice_latexreturnaddress
invoice_latexfooter
invoice_latexsmallfooter
invoice_latexnotes
invoice_latexcoupon
invoice_latexwatermark
invoice_html
invoice_htmlreturnaddress
invoice_htmlfooter
invoice_htmlnotes
invoice_htmlwatermark
logo.png
logo.eps
);

@invoice_terms = (
  '',
  'Payable upon receipt',
  'Net 0', 'Net 3', 'Net 5', 'Net 7', 'Net 9', 'Net 10', 'Net 14', 
  'Net 15', 'Net 18', 'Net 20', 'Net 21', 'Net 25', 'End of Month', 'Net 30',
  'Net 45', 'Net 60', 'Net 90'
);

my %msg_template_options = (
  'type'        => 'select-sub',
  'options_sub' => sub { 
    my @templates = qsearch({
        'table' => 'msg_template', 
        'hashref' => { 'disabled' => '' },
        'extra_sql' => ' AND '. 
          $FS::CurrentUser::CurrentUser->agentnums_sql(null => 1),
        });
    map { $_->msgnum, $_->msgname } @templates;
  },
  'option_sub'  => sub { 
                         my $msg_template = FS::msg_template->by_key(shift);
                         $msg_template ? $msg_template->msgname : ''
                       },
  'per_agent' => 1,
);

my %payment_gateway_options = (
  'type'        => 'select-sub',
  'options_sub' => sub {
    my @gateways = qsearch({
        'table' => 'payment_gateway',
        'hashref' => { 'disabled' => '' },
      });
    map { $_->gatewaynum, $_->label } @gateways;
  },
  'option_sub'  => sub {
    my $gateway = FS::payment_gateway->by_key(shift);
    $gateway ? $gateway->label : ''
  },
);

my %batch_gateway_options = (
  %payment_gateway_options,
  'options_sub' => sub {
    my @gateways = qsearch('payment_gateway',
      {
        'disabled'          => '',
        'gateway_namespace' => 'Business::BatchPayment',
      }
    );
    map { $_->gatewaynum, $_->label } @gateways;
  },
  'per_agent' => 1,
);

my %invoice_mode_options = (
  'type'        => 'select-sub',
  'options_sub' => sub { 
    my @modes = qsearch({
        'table' => 'invoice_mode', 
        'extra_sql' => ' WHERE '.
          $FS::CurrentUser::CurrentUser->agentnums_sql(null => 1),
        });
    map { $_->modenum, $_->modename } @modes;
  },
  'option_sub'  => sub { 
                         my $mode = FS::invoice_mode->by_key(shift);
                         $mode ? $mode->modename : '',
                       },
  'per_agent' => 1,
);

my @cdr_formats = (
  '' => '',
  'default' => 'Default',
  'source_default' => 'Default with source',
  'accountcode_default' => 'Default plus accountcode',
  'description_default' => 'Default with description field as destination',
  'basic' => 'Basic',
  'simple' => 'Simple',
  'simple2' => 'Simple with source',
  'accountcode_simple' => 'Simple with accountcode',
);

# takes the reason class (C, R, S) as an argument
sub reason_type_options {
  my $reason_class = shift;

  'type'        => 'select-sub',
  'options_sub' => sub {
    map { $_->typenum => $_->type } 
      qsearch('reason_type', { class => $reason_class });
  },
  'option_sub'  => sub {
    my $type = FS::reason_type->by_key(shift);
    $type ? $type->type : '';
  }
}

my $validate_email = sub { $_[0] =~
                             /^[^@]+\@[[:alnum:]-]+(\.[[:alnum:]-]+)+$/
                             ? '' : 'Invalid email address';
                         };

#Billing (81 items)
#Invoicing (50 items)
#UI (69 items)
#Self-service (29 items)
#...
#Unclassified (77 items)

@config_items = map { new FS::ConfItem $_ } (

  {
    'key'         => 'event_log_level',
    'section'     => 'notification',
    'description' => 'Store events in the internal log if they are at least this severe.  "info" is the default, "debug" is very detailed and noisy.',
    'type'        => 'select',
    'select_enum' => [ '', 'debug', 'info', 'notice', 'warning', 'error', ],
    # don't bother with higher levels
  },

  {
    'key'         => 'log_sent_mail',
    'section'     => 'notification',
    'description' => 'Enable logging of all sent email.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'part_pkg-lineage',
    'section'     => 'packages',
    'description' => 'When editing a package definition, if setup or recur fees are changed, create a new package rather than changing the existing package.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'apacheip',
    #not actually deprecated yet
    #'section'     => 'deprecated',
    #'description' => '<b>DEPRECATED</b>, add an <i>apache</i> <a href="../browse/part_export.cgi">export</a> instead.  Used to be the current IP address to assign to new virtual hosts',
    'section'     => 'services',
    'description' => 'IP address to assign to new virtual hosts',
    'type'        => 'text',
  },
  
  {
    'key'         => 'credits-auto-apply-disable',
    'section'     => 'billing',
    'description' => 'Disable the "Auto-Apply to invoices" UI option for new credits',
    'type'        => 'checkbox',
  },
  
  {
    'key'         => 'credit-card-surcharge-percentage',
    'section'     => 'credit_cards',
    'description' => 'Add a credit card surcharge to invoices, as a % of the invoice total.  WARNING: Although permitted to US merchants in general since 2013, specific consumer protection laws may prohibit or restrict this practice in California, Colorado, Connecticut, Florda, Kansas, Maine, Massachusetts, New York, Oklahoma, and Texas.  Surcharging is also generally prohibited in most countries outside the US, AU and UK.  When allowed, typically not permitted to be above 4%.',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'credit-card-surcharge-flatfee',
    'section'     => 'credit_cards',
    'description' => 'Add a credit card surcharge to invoices, as a flat fee.  WARNING: Although permitted to US merchants in general since 2013, specific consumer protection laws may prohibit or restrict this practice in California, Colorado, Connecticut, Florda, Kansas, Maine, Massachusetts, New York, Oklahoma, and Texas.  Surcharging is also generally prohibited in most countries outside the US, AU and UK.  When allowed, typically not permitted to be above 4%.',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'credit-card-surcharge-text',
    'section'     => 'credit_cards',
    'description' => 'Text for the credit card surcharge invoice line.  If not set, it will default to Credit Card Surcharge.',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'discount-show-always',
    'section'     => 'invoicing',
    'description' => 'Generate a line item on an invoice even when a package is discounted 100%',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'discount-show_available',
    'section'     => 'invoicing',
    'description' => 'Show available prepayment discounts on invoices.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'invoice-barcode',
    'section'     => 'invoicing',
    'description' => 'Display a barcode on HTML and PDF invoices',
    'type'        => 'checkbox',
  },
  
  {
    'key'         => 'cust_main-select-billday',
    'section'     => 'payments',
    'description' => 'When used with a specific billing event, allows the selection of the day of month on which to charge credit card / bank account automatically, on a per-customer basis',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_main-select-prorate_day',
    'section'     => 'billing',
    'description' => 'When used with prorate or anniversary packages, allows the selection of the prorate day of month, on a per-customer basis',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'anniversary-rollback',
    'section'     => 'billing',
    'description' => 'When billing an anniversary package ordered after the 28th, roll the anniversary date back to the 28th instead of forward into the following month.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'encryption',
    'section'     => 'credit_cards',
    'description' => 'Enable encryption of credit cards and echeck numbers',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'encryptionmodule',
    'section'     => 'credit_cards',
    'description' => 'Use which module for encryption?',
    'type'        => 'select',
    'select_enum' => [ '', 'Crypt::OpenSSL::RSA', ],
  },

  {
    'key'         => 'encryptionpublickey',
    'section'     => 'credit_cards',
    'description' => 'Encryption public key',
    'type'        => 'textarea',
  },

  {
    'key'         => 'encryptionprivatekey',
    'section'     => 'credit_cards',
    'description' => 'Encryption private key',
    'type'        => 'textarea',
  },

  {
    'key'         => 'billco-url',
    'section'     => 'print_services',
    'description' => 'The url to use for performing uploads to the invoice mailing service.',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'billco-username',
    'section'     => 'print_services',
    'description' => 'The login name to use for uploads to the invoice mailing service.',
    'type'        => 'text',
    'per_agent'   => 1,
    'agentonly'   => 1,
  },

  {
    'key'         => 'billco-password',
    'section'     => 'print_services',
    'description' => 'The password to use for uploads to the invoice mailing service.',
    'type'        => 'text',
    'per_agent'   => 1,
    'agentonly'   => 1,
  },

  {
    'key'         => 'billco-clicode',
    'section'     => 'print_services',
    'description' => 'The clicode to use for uploads to the invoice mailing service.',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'billco-account_num',
    'section'     => 'print_services',
    'description' => 'The data to place in the "Transaction Account No" / "TRACCTNUM" field.',
    'type'        => 'select',
    'select_hash' => [
                       'invnum-date' => 'Invoice number - Date (default)',
                       'display_custnum'  => 'Customer number',
                     ],
    'per_agent'   => 1,
  },

  {
    'key'         => 'email-to-voice_domain',
    'section'     => 'email_to_voice_services',
    'description' => 'The domain name that phone numbers will be attached to for sending email to voice emails via a 3rd party email to voice service.  You will get this domain from your email to voice service provider.  This is utilized on the email customer page or when using the email to voice billing event action.  There you will be able to select the phone number for the email to voice service.',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'next-bill-ignore-time',
    'section'     => 'billing',
    'description' => 'Ignore the time portion of next bill dates when billing, matching anything from 00:00:00 to 23:59:59 on the billing day.',
    'type'        => 'checkbox',
  },
  
  {
    'key'         => 'business-onlinepayment',
    'section'     => 'credit_cards',
    'description' => '<a href="http://search.cpan.org/search?mode=module&query=Business%3A%3AOnlinePayment">Business::OnlinePayment</a> support, at least three lines: processor, login, and password.  An optional fourth line specifies the action or actions (multiple actions are separated with `,\': for example: `Authorization Only, Post Authorization\').    Optional additional lines are passed to Business::OnlinePayment as %processor_options.  For more detailed information and examples see the <a href="http://www.freeside.biz/mediawiki/index.php/Freeside:3:Documentation:Administration:Real-time_Processing">real-time credit card processing documentation</a>.',
    'type'        => 'textarea',
  },

  {
    'key'         => 'business-onlinepayment-ach',
    'section'     => 'e-checks',
    'description' => 'Alternate <a href="http://search.cpan.org/search?mode=module&query=Business%3A%3AOnlinePayment">Business::OnlinePayment</a> support for ACH transactions (defaults to regular <b>business-onlinepayment</b>).  At least three lines: processor, login, and password.  An optional fourth line specifies the action or actions (multiple actions are separated with `,\': for example: `Authorization Only, Post Authorization\').    Optional additional lines are passed to Business::OnlinePayment as %processor_options.',
    'type'        => 'textarea',
  },

  {
    'key'         => 'business-onlinepayment-namespace',
    'section'     => 'credit_cards',
    'description' => 'Specifies which perl module namespace (which group of collection routines) is used by default.',
    'type'        => 'select',
    'select_hash' => [
                       'Business::OnlinePayment' => 'Direct API (Business::OnlinePayment)',
		       'Business::OnlineThirdPartyPayment' => 'Web API (Business::ThirdPartyPayment)',
                     ],
  },

  {
    'key'         => 'business-onlinepayment-description',
    'section'     => 'credit_cards',
    'description' => 'String passed as the description field to <a href="http://search.cpan.org/search?mode=module&query=Business%3A%3AOnlinePayment">Business::OnlinePayment</a>.  Evaluated as a double-quoted perl string, with the following variables available: <code>$agent</code> (the agent name), and <code>$pkgs</code> (a comma-separated list of packages for which these charges apply - not available in all situations)',
    'type'        => 'text',
  },

  {
    'key'         => 'business-onlinepayment-email-override',
    'section'     => 'credit_cards',
    'description' => 'Email address used instead of customer email address when submitting a BOP transaction.',
    'type'        => 'text',
  },

  {
    'key'         => 'business-onlinepayment-email_customer',
    'section'     => 'credit_cards',
    'description' => 'Controls the "email_customer" flag used by some Business::OnlinePayment processors to enable customer receipts.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'business-onlinepayment-test_transaction',
    'section'     => 'credit_cards',
    'description' => 'Turns on the Business::OnlinePayment test_transaction flag.  Note that not all gateway modules support this flag; if yours does not, transactions will still be sent live.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'business-onlinepayment-currency',
    'section'     => 'credit_cards',
    'description' => 'Currency parameter for Business::OnlinePayment transactions.',
    'type'        => 'select',
    'select_enum' => [ '', qw( USD AUD CAD DKK EUR GBP ILS JPY NZD ARS ) ],
  },

  {
    'key'         => 'business-onlinepayment-verification',
    'section'     => 'credit_cards',
    'description' => 'Run a $1 authorization (followed by a void) to verify new credit card information.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'currency',
    'section'     => 'localization',
    'description' => 'Main accounting currency',
    'type'        => 'select',
    'select_enum' => [ '', qw( USD AUD CAD DKK EUR GBP ILS JPY NZD XAF ARS ) ],
  },

  {
    'key'         => 'currencies',
    'section'     => 'localization',
    'description' => 'Additional accepted currencies',
    'type'        => 'select-sub',
    'multiple'    => 1,
    'options_sub' => sub { 
                           map { $_ => code2currency($_) } all_currency_codes();
			 },
    'sort_sub'    => sub ($$) { $_[0] cmp $_[1]; },
    'option_sub'  => sub { code2currency(shift); },
  },

  {
    'key'         => 'business-batchpayment-test_transaction',
    'section'     => 'credit_cards',
    'description' => 'Turns on the Business::BatchPayment test_mode flag.  Note that not all gateway modules support this flag; if yours does not, using the batch gateway will fail.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'countrydefault',
    'section'     => 'localization',
    'description' => 'Default two-letter country code (if not supplied, the default is `US\')',
    'type'        => 'text',
  },

  {
    'key'         => 'date_format',
    'section'     => 'localization',
    'description' => 'Format for displaying dates',
    'type'        => 'select',
    'select_hash' => [
                       '%m/%d/%Y' => 'MM/DD/YYYY',
                       '%d/%m/%Y' => 'DD/MM/YYYY',
		       '%Y/%m/%d' => 'YYYY/MM/DD',
                       '%e %b %Y' => 'DD Mon YYYY',
                     ],
    'per_locale'  => 1,
  },

  {
    'key'         => 'date_format_long',
    'section'     => 'localization',
    'description' => 'Verbose format for displaying dates',
    'type'        => 'select',
    'select_hash' => [
                       '%b %o, %Y' => 'Mon DDth, YYYY',
                       '%e %b %Y'  => 'DD Mon YYYY',
                       '%m/%d/%Y'  => 'MM/DD/YYYY',
                       '%d/%m/%Y'  => 'DD/MM/YYYY',
		       '%Y/%m/%d'  => 'YYYY/MM/DD',
                     ],
    'per_locale'  => 1,
  },

  {
    'key'         => 'deleterefunds',
    'section'     => 'billing',
    'description' => 'Enable deletion of unclosed refunds.  Be very careful!  Only delete refunds that were data-entry errors, not adjustments.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'dirhash',
    'section'     => 'shell',
    'description' => 'Optional numeric value to control directory hashing.  If positive, hashes directories for the specified number of levels from the front of the username.  If negative, hashes directories for the specified number of levels from the end of the username.  Some examples: <ul><li>1: user -> <a href="#home">/home</a>/u/user<li>2: user -> <a href="#home">/home</a>/u/s/user<li>-1: user -> <a href="#home">/home</a>/r/user<li>-2: user -> <a href="#home">home</a>/r/e/user</ul>',
    'type'        => 'text',
  },

  {
    'key'         => 'disable_cust_attachment',
    'section'     => 'notes',
    'description' => 'Disable customer file attachments',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'max_attachment_size',
    'section'     => 'notes',
    'description' => 'Maximum size for customer file attachments (leave blank for unlimited)',
    'type'        => 'text',
  },

  {
    'key'         => 'disable_customer_referrals',
    'section'     => 'customer_fields',
    'description' => 'Disable new customer-to-customer referrals in the web interface',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'editreferrals',
    'section'     => 'customer_fields',
    'description' => 'Enable advertising source modification for existing customers',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'emailinvoiceonly',
    'section'     => 'invoice_email',
    'description' => 'Disables postal mail invoices',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'disablepostalinvoicedefault',
    'section'     => 'invoicing',
    'description' => 'Disables postal mail invoices as the default option in the UI.  Be careful not to setup customers which are not sent invoices.  See <a href ="#emailinvoiceauto">emailinvoiceauto</a>.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'emailinvoiceauto',
    'section'     => 'invoice_email',
    'description' => 'Automatically adds new accounts to the email invoice list',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'emailinvoiceautoalways',
    'section'     => 'invoice_email',
    'description' => 'Automatically adds new accounts to the email invoice list even when the list contains email addresses',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'emailinvoice-apostrophe',
    'section'     => 'invoice_email',
    'description' => 'Allows the apostrophe (single quote) character in the email addresses in the email invoice list.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'svc_acct-ip_addr',
    'section'     => 'services',
    'description' => 'Enable IP address management on login services like for broadband services.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'exclude_ip_addr',
    'section'     => 'services',
    'description' => 'Exclude these from the list of available IP addresses. (One per line)',
    'type'        => 'textarea',
  },
  
  {
    'key'         => 'auto_router',
    'section'     => 'wireless_broadband',
    'description' => 'Automatically choose the correct router/block based on supplied ip address when possible while provisioning broadband services',
    'type'        => 'checkbox',
  },
  
  {
    'key'         => 'hidecancelledpackages',
    'section'     => 'cancellation',
    'description' => 'Prevent cancelled packages from showing up in listings (though they will still be in the database)',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'hidecancelledcustomers',
    'section'     => 'cancellation',
    'description' => 'Prevent customers with only cancelled packages from showing up in listings (though they will still be in the database)',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'home',
    'section'     => 'shell',
    'description' => 'For new users, prefixed to username to create a directory name.  Should have a leading but not a trailing slash.',
    'type'        => 'text',
  },

  {
    'key'         => 'invoice_from',
    'section'     => 'important',
    'description' => 'Return address on email invoices ("user@domain" only)',
    'type'        => 'text',
    'per_agent'   => 1,
    'validate'    => $validate_email,
  },

  {
    'key'         => 'invoice_from_name',
    'section'     => 'invoice_email',
    'description' => 'Return name on email invoices (set address in invoice_from)',
    'type'        => 'text',
    'per_agent'   => 1,
    'validate'    => sub { (($_[0] =~ /[^[:alnum:][:space:]]/) && ($_[0] !~ /^\".*\"$/))
                           ? 'Invalid name.  Use quotation marks around names that contain punctuation.'
                           : '' }
  },

  {
    'key'         => 'quotation_from',
    'section'     => 'quotations',
    'description' => 'Return address on email quotations',
    'type'        => 'text',
    'per_agent'   => 1,
  },


  {
    'key'         => 'invoice_subject',
    'section'     => 'invoice_email',
    'description' => 'Subject: header on email invoices.  Defaults to "Invoice".  The following substitutions are available: $name, $name_short, $invoice_number, and $invoice_date.',
    'type'        => 'text',
    'per_agent'   => 1,
    'per_locale'  => 1,
  },

  {
    'key'         => 'quotation_subject',
    'section'     => 'quotations',
    'description' => 'Subject: header on email quotations.  Defaults to "Quotation".', #  The following substitutions are available: $name, $name_short, $invoice_number, and $invoice_date.',
    'type'        => 'text',
    #'per_agent'   => 1,
    'per_locale'  => 1,
  },

  {
    'key'         => 'invoice_usesummary',
    'section'     => 'invoicing',
    'description' => 'Indicates that html and latex invoices should be in summary style and make use of invoice_latexsummary.',
    'type'        => 'checkbox',
    'per_agent'   => 1,
  },

  {
    'key'         => 'invoice_template',
    'section'     => 'invoice_templates',
    'description' => 'Text template file for invoices.  Used if no invoice_html template is defined, and also seen by users using non-HTML capable mail clients.  See the <a href="http://www.freeside.biz/mediawiki/index.php/Freeside:3:Documentation:Administration#Plaintext_invoice_templates">billing documentation</a> for details.',
    'type'        => 'textarea',
  },

  {
    'key'         => 'invoice_html',
    'section'     => 'invoice_templates',
    'description' => 'HTML template for invoices.  See the <a href="http://www.freeside.biz/mediawiki/index.php/Freeside:3:Documentation:Administration#HTML_invoice_templates">billing documentation</a> for details.',

    'type'        => 'textarea',
  },

  {
    'key'         => 'quotation_html',
    'section'     => 'quotations',
    'description' => 'HTML template for quotations.',

    'type'        => 'textarea',
  },

  {
    'key'         => 'invoice_htmlnotes',
    'section'     => 'invoice_templates',
    'description' => 'Notes section for HTML invoices.  Defaults to the same data in invoice_latexnotes if not specified.',
    'type'        => 'textarea',
    'per_agent'   => 1,
    'per_locale'  => 1,
  },

  {
    'key'         => 'invoice_htmlfooter',
    'section'     => 'invoice_templates',
    'description' => 'Footer for HTML invoices.  Defaults to the same data in invoice_latexfooter if not specified.',
    'type'        => 'textarea',
    'per_agent'   => 1,
    'per_locale'  => 1,
  },

  {
    'key'         => 'invoice_htmlsummary',
    'section'     => 'invoice_templates',
    'description' => 'Summary initial page for HTML invoices.',
    'type'        => 'textarea',
    'per_agent'   => 1,
    'per_locale'  => 1,
  },

  {
    'key'         => 'invoice_htmlreturnaddress',
    'section'     => 'invoice_templates',
    'description' => 'Return address for HTML invoices.  Defaults to the same data in invoice_latexreturnaddress if not specified.',
    'type'        => 'textarea',
    'per_locale'  => 1,
  },

  {
    'key'         => 'invoice_htmlwatermark',
    'section'     => 'invoice_templates',
    'description' => 'Watermark for HTML invoices. Appears in a semitransparent positioned DIV overlaid on the main invoice container.',
    'type'        => 'textarea',
    'per_agent'   => 1,
    'per_locale'  => 1,
  },

  {
    'key'         => 'invoice_latex',
    'section'     => 'invoice_templates',
    'description' => 'Optional LaTeX template for typeset PostScript invoices.  See the <a href="http://www.freeside.biz/mediawiki/index.php/Freeside:3:Documentation:Administration#Typeset_.28LaTeX.29_invoice_templates">billing documentation</a> for details.',
    'type'        => 'textarea',
  },

  {
    'key'         => 'quotation_latex',
    'section'     => 'quotations',
    'description' => 'LaTeX template for typeset PostScript quotations.',
    'type'        => 'textarea',
  },

  {
    'key'         => 'invoice_latextopmargin',
    'section'     => 'invoicing',
    'description' => 'Optional LaTeX invoice topmargin setting. Include units.',
    'type'        => 'text',
    'per_agent'   => 1,
    'validate'    => sub { shift =~
                             /^-?\d*\.?\d+(in|mm|cm|pt|em|ex|pc|bp|dd|cc|sp)$/
                             ? '' : 'Invalid LaTex length';
                         },
  },

  {
    'key'         => 'invoice_latexheadsep',
    'section'     => 'invoicing',
    'description' => 'Optional LaTeX invoice headsep setting. Include units.',
    'type'        => 'text',
    'per_agent'   => 1,
    'validate'    => sub { shift =~
                             /^-?\d*\.?\d+(in|mm|cm|pt|em|ex|pc|bp|dd|cc|sp)$/
                             ? '' : 'Invalid LaTex length';
                         },
  },

  {
    'key'         => 'invoice_latexaddresssep',
    'section'     => 'invoicing',
    'description' => 'Optional LaTeX invoice separation between invoice header
and customer address. Include units.',
    'type'        => 'text',
    'per_agent'   => 1,
    'validate'    => sub { shift =~
                             /^-?\d*\.?\d+(in|mm|cm|pt|em|ex|pc|bp|dd|cc|sp)$/
                             ? '' : 'Invalid LaTex length';
                         },
  },

  {
    'key'         => 'invoice_latextextheight',
    'section'     => 'invoicing',
    'description' => 'Optional LaTeX invoice textheight setting. Include units.',
    'type'        => 'text',
    'per_agent'   => 1,
    'validate'    => sub { shift =~
                             /^-?\d*\.?\d+(in|mm|cm|pt|em|ex|pc|bp|dd|cc|sp)$/
                             ? '' : 'Invalid LaTex length';
                         },
  },

  {
    'key'         => 'invoice_latexnotes',
    'section'     => 'invoice_templates',
    'description' => 'Notes section for LaTeX typeset PostScript invoices.',
    'type'        => 'textarea',
    'per_agent'   => 1,
    'per_locale'  => 1,
  },

  {
    'key'         => 'quotation_latexnotes',
    'section'     => 'quotations',
    'description' => 'Notes section for LaTeX typeset PostScript quotations.',
    'type'        => 'textarea',
    'per_agent'   => 1,
    'per_locale'  => 1,
  },

  {
    'key'         => 'invoice_latexfooter',
    'section'     => 'invoice_templates',
    'description' => 'Footer for LaTeX typeset PostScript invoices.',
    'type'        => 'textarea',
    'per_agent'   => 1,
    'per_locale'  => 1,
  },

  {
    'key'         => 'invoice_latexsummary',
    'section'     => 'invoice_templates',
    'description' => 'Summary initial page for LaTeX typeset PostScript invoices.',
    'type'        => 'textarea',
    'per_agent'   => 1,
    'per_locale'  => 1,
  },

  {
    'key'         => 'invoice_latexcoupon',
    'section'     => 'invoice_templates',
    'description' => 'Remittance coupon for LaTeX typeset PostScript invoices.',
    'type'        => 'textarea',
    'per_agent'   => 1,
    'per_locale'  => 1,
  },

  {
    'key'         => 'invoice_latexextracouponspace',
    'section'     => 'invoicing',
    'description' => 'Optional LaTeX invoice textheight space to reserve for a tear off coupon.  Include units.  Default is 2.7 inches.',
    'type'        => 'text',
    'per_agent'   => 1,
    'validate'    => sub { shift =~
                             /^-?\d*\.?\d+(in|mm|cm|pt|em|ex|pc|bp|dd|cc|sp)$/
                             ? '' : 'Invalid LaTex length';
                         },
  },

  {
    'key'         => 'invoice_latexcouponfootsep',
    'section'     => 'invoicing',
    'description' => 'Optional LaTeX invoice separation between bottom of coupon address and footer. Include units. Default is 0.2 inches.',
    'type'        => 'text',
    'per_agent'   => 1,
    'validate'    => sub { shift =~
                             /^-?\d*\.?\d+(in|mm|cm|pt|em|ex|pc|bp|dd|cc|sp)$/
                             ? '' : 'Invalid LaTex length';
                         },
  },

  {
    'key'         => 'invoice_latexcouponamountenclosedsep',
    'section'     => 'invoicing',
    'description' => 'Optional LaTeX invoice separation between total due and amount enclosed line. Include units. Default is 2.25 em.',
    'type'        => 'text',
    'per_agent'   => 1,
    'validate'    => sub { shift =~
                             /^-?\d*\.?\d+(in|mm|cm|pt|em|ex|pc|bp|dd|cc|sp)$/
                             ? '' : 'Invalid LaTex length';
                         },
  },
  {
    'key'         => 'invoice_latexcoupontoaddresssep',
    'section'     => 'invoicing',
    'description' => 'Optional LaTeX invoice separation between invoice data and the address (usually invoice_latexreturnaddress).  Include units. Default is 1 inch.',
    'type'        => 'text',
    'per_agent'   => 1,
    'validate'    => sub { shift =~
                             /^-?\d*\.?\d+(in|mm|cm|pt|em|ex|pc|bp|dd|cc|sp)$/
                             ? '' : 'Invalid LaTex length';
                         },
  },

  {
    'key'         => 'invoice_latexreturnaddress',
    'section'     => 'invoice_templates',
    'description' => 'Return address for LaTeX typeset PostScript invoices.',
    'type'        => 'textarea',
  },

  {
    'key'         => 'invoice_latexverticalreturnaddress',
    'section'     => 'deprecated',
    'description' => 'Deprecated.  With old invoice_latex template, places the return address under the company logo rather than beside it.',
    'type'        => 'checkbox',
    'per_agent'   => 1,
  },

  {
    'key'         => 'invoice_latexcouponaddcompanytoaddress',
    'section'     => 'invoicing',
    'description' => 'Add the company name to the To address on the remittance coupon because the return address does not contain it.',
    'type'        => 'checkbox',
    'per_agent'   => 1,
  },

  {
    'key'         => 'invoice_latexcouponlocation',
    'section'     => 'invoicing',
    'description' => 'Location of the remittance coupon.Either top or bottom of page, defaults to bottom.',
    'type'        => 'select',
    'select_hash' => [
                       'bottom' => 'Bottom of page (default)',
                       'top'    => 'Top of page',
                     ],
    'per_agent'   => 1,
  },

  {
    'key'         => 'invoice_latexsmallfooter',
    'section'     => 'invoice_templates',
    'description' => 'Optional small footer for multi-page LaTeX typeset PostScript invoices.',
    'type'        => 'textarea',
    'per_agent'   => 1,
    'per_locale'  => 1,
  },

  {
    'key'         => 'invoice_latexwatermark',
    'section'     => 'invocie_templates',
    'description' => 'Watermark for LaTeX invoices. See "texdoc background" for information on what this can contain. The content itself should be enclosed in braces, optionally followed by a comma and any formatting options.',
    'type'        => 'textarea',
    'per_agent'   => 1,
    'per_locale'  => 1,
  },

  {
    'key'         => 'invoice_email_pdf',
    'section'     => 'invoice_email',
    'description' => 'Send PDF invoice as an attachment to emailed invoices.  By default, includes the HTML invoice as the email body, unless invoice_email_pdf_note is set.',
    'type'        => 'checkbox'
  },

  {
    'key'         => 'quotation_email_pdf',
    'section'     => 'quotations',
    'description' => 'Send PDF quotations as an attachment to emailed quotations.  By default, includes the HTML quotation as the email body, unless quotation_email_pdf_note is set.',
    'type'        => 'checkbox'
  },

  {
    'key'         => 'invoice_email_pdf_msgnum',
    'section'     => 'invoice_email',
    'description' => 'Message template to send as the text and HTML part of PDF invoices. If not selected, a text and HTML version of the invoice will be sent.',
    %msg_template_options,
  },

  {
    'key'         => 'invoice_email_pdf_note',
    'section'     => 'invoice_email',
    'description' => 'If defined, this text will replace the default HTML invoice as the body of emailed PDF invoices.',
    'type'        => 'textarea'
  },

  {
    'key'         => 'quotation_email_pdf_note',
    'section'     => 'quotations',
    'description' => 'If defined, this text will replace the default HTML quotation as the body of emailed PDF quotations.',
    'type'        => 'textarea'
  },

  {
    'key'         => 'quotation_disable_after_days',
    'section'     => 'quotations',
    'description' => 'The number of days, if set, after which a non-converted quotation will be automatically disabled.',
    'type'        => 'text'
  },

  {
    'key'         => 'invoice_print_pdf',
    'section'     => 'printing',
    'description' => 'For all invoice print operations, store postal invoices for download in PDF format rather than printing them directly.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'invoice_print_pdf-spoolagent',
    'section'     => 'printing',
    'description' => 'Store postal invoices PDF downloads in per-agent spools.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'invoice_print_pdf-duplex',
    'section'     => 'printing',
    'description' => 'Insert blank pages so that spooled invoices are each an even number of pages.  Use this for double-sided printing.',
    'type'        => 'checkbox',
  },

  { 
    'key'         => 'invoice_default_terms',
    'section'     => 'invoicing',
    'description' => 'Optional default invoice term, used to calculate a due date printed on invoices.  WARNING: If you do not want to change the terms on existing invoices, do not change this after going live.',
    'type'        => 'select',
    'per_agent'   => 1,
    'select_enum' => \@invoice_terms,
  },

  { 
    'key'         => 'invoice_show_prior_due_date',
    'section'     => 'invoice_balances',
    'description' => 'Show previous invoice due dates when showing prior balances.  Default is to show invoice date.',
    'type'        => 'checkbox',
  },

  { 
    'key'         => 'invoice_omit_due_date',
    'section'     => 'invoice_balances',
    'description' => 'Omit the "Please pay by (date)" from invoices.',
    'type'        => 'checkbox',
    'per_agent'   => 1,
  },

  { 
    'key'         => 'invoice_pay_by_msg',
    'section'     => 'invoice_balances',
    'description' => 'Test of the "Please pay by (date)" message.  Include [_1] to indicate the date, for example: "Please pay by [_1]"',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  { 
    'key'         => 'invoice_sections',
    'section'     => 'invoicing',
    'description' => 'Split invoice into sections and label according to either package category or location when enabled.',
    'type'        => 'checkbox',
    'per_agent'   => 1,
    'config_bool' => 1,
  },

  {
    'key'         => 'invoice_sections_multilocation',
    'section'     => 'invoicing',
    'description' => 'Enable invoice_sections for for any bill with at least this many locations on the bill.',
    'type'        => 'text',
    'per_agent'   => 1,
    'validate'    => sub { shift =~ /^\d+$/ ? undef : 'Please enter a number' },
  },

  { 
    'key'         => 'invoice_include_aging',
    'section'     => 'invoice_balances',
    'description' => 'Show an aging line after the prior balance section.  Only valid when invoice_sections is enabled.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'invoice_sections_method',
    'section'     => 'invoicing',
    'description' => 'How to group line items on multi-section invoices.',
    'type'        => 'select',
    'select_enum' => [ qw(category location) ],
  },

  {
    'key'         => 'invoice_sections_with_taxes',
    'section'     => 'invoicing',
    'description' => 'Include taxes within each section of mutli-section invoices.',
    'type'        => 'checkbox',
    'per_agent'   => 1,
    'agent_bool'  => 1,
  },

  {
    'key'         => 'summary_subtotals_method',
    'section'     => 'invoicing',
    'description' => 'How to group line items when calculating summary subtotals.  By default, it will be the same method used for grouping invoice sections.',
    'type'        => 'select',
    'select_enum' => [ qw(category location) ],
  },

  #quotations seem broken-ish with sections ATM?
  #{ 
  #  'key'         => 'quotation_sections',
  #  'section'     => 'invoicing',
  #  'description' => 'Split quotations into sections and label according to package category when enabled.',
  #  'type'        => 'checkbox',
  #  'per_agent'   => 1,
  #},

  {
    'key'         => 'usage_class_summary',
    'section'     => 'telephony_invoicing',
    'description' => 'On invoices, summarize total usage by usage class in a separate section',
    'type'        => 'checkbox',
  },

  { 
    'key'         => 'usage_class_as_a_section',
    'section'     => 'telephony_invoicing',
    'description' => 'On invoices, split usage into sections and label according to usage class name when enabled.  Only valid when invoice_sections is enabled.',
    'type'        => 'checkbox',
  },

  { 
    'key'         => 'phone_usage_class_summary',
    'section'     => 'telephony_invoicing',
    'description' => 'On invoices, summarize usage per DID by usage class and display all CDRs together regardless of usage class. Only valid when svc_phone_sections is enabled.',
    'type'        => 'checkbox',
  },

  { 
    'key'         => 'svc_phone_sections',
    'section'     => 'telephony_invoicing',
    'description' => 'On invoices, create a section for each svc_phone when enabled.  Only valid when invoice_sections is enabled.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'finance_pkgclass',
    'section'     => 'billing',
    'description' => 'The default package class for late fee charges, used if the fee event does not specify a package class itself.',
    'type'        => 'select-pkg_class',
  },

  { 
    'key'         => 'separate_usage',
    'section'     => 'telephony_invoicing',
    'description' => 'On invoices, split the rated call usage into a separate line from the recurring charges.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'allow_payment_receipt_noemail',
    'section'     => 'notification',
    'description' => 'Add option on customer edit/view page to disable emailing of payment receipts.  If this option is set to NO it will override customer specific option, so when set to NO system will not check for payment_receipt_noemail option at customer level.',
    'type'        => 'checkbox',
    'per_agent'   => 1,
    'agent_bool'  => 1,
  },

  {
    'key'         => 'payment_receipt',
    'section'     => 'notification',
    'description' => 'Send payment receipts.',
    'type'        => 'checkbox',
    'per_agent'   => 1,
    'agent_bool'  => 1,
  },

  {
    'key'         => 'payment_receipt_statement_mode',
    'section'     => 'notification',
    'description' => 'Automatic payments will cause a post-payment statement to be sent to the customer. Select the invoice mode to use for this statement. If unspecified, it will use the "_statement" versions of invoice configuration settings, and have the notice name "Statement".',
    %invoice_mode_options,
  },

  {
    'key'         => 'payment_receipt_msgnum',
    'section'     => 'notification',
    'description' => 'Template to use for manual payment receipts.',
    %msg_template_options,
  },

  {
    'key'         => 'payment_receipt_msgnum_auto',
    'section'     => 'notification',
    'description' => 'Automatic payments will cause a post-payment to use a message template for automatic payment receipts rather than a post payment statement.',
    %msg_template_options,
  },
  
  {
    'key'         => 'payment_receipt_from',
    'section'     => 'notification',
    'description' => 'From: address for payment receipts, if not specified in the template.',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'payment_receipt-trigger',
    'section'     => 'notification',
    'description' => 'When payment receipts are triggered.  Defaults to when payment is made.',
    'type'        => 'select',
    'select_hash' => [
                       'cust_pay'          => 'When payment is made.',
                       'cust_bill_pay_pkg' => 'When payment is applied.',
                     ],
    'per_agent'   => 1,
  },

  {
    'key'         => 'refund_receipt_msgnum',
    'section'     => 'notification',
    'description' => 'Template to use for manual refund receipts.',
    %msg_template_options,
  },
  
  {
    'key'         => 'trigger_export_insert_on_payment',
    'section'     => 'payments',
    'description' => 'Enable exports on payment application.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'lpr',
    'section'     => 'printing',
    'description' => 'Print command for paper invoices, for example `lpr -h\'',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'lpr-postscript_prefix',
    'section'     => 'printing',
    'description' => 'Raw printer commands prepended to the beginning of postscript print jobs (evaluated as a double-quoted perl string - backslash escapes are available)',
    'type'        => 'text',
  },

  {
    'key'         => 'lpr-postscript_suffix',
    'section'     => 'printing',
    'description' => 'Raw printer commands added to the end of postscript print jobs (evaluated as a double-quoted perl string - backslash escapes are available)',
    'type'        => 'text',
  },

  {
    'key'         => 'papersize',
    'section'     => 'printing',
    'description' => 'Invoice paper size.  Default is "letter" (U.S. standard).  The LaTeX template must be configured to match this size.',
    'type'        => 'select',
    'select_enum' => [ qw(letter a4) ],
  },

  {
    'key'         => 'money_char',
    'section'     => 'localization',
    'description' => 'Currency symbol - defaults to `$\'',
    'type'        => 'text',
  },

  {
    'key'         => 'defaultrecords',
    'section'     => 'BIND',
    'description' => 'DNS entries to add automatically when creating a domain',
    'type'        => 'editlist',
    'editlist_parts' => [ { type=>'text' },
                          { type=>'immutable', value=>'IN' },
                          { type=>'select',
                            select_enum => {
                              map { $_=>$_ }
                                  #@{ FS::domain_record->rectypes }
                                  qw(A AAAA CNAME MX NS PTR SPF SRV TXT)
                            },
                          },
                          { type=> 'text' }, ],
  },

  {
    'key'         => 'passwordmin',
    'section'     => 'password',
    'description' => 'Minimum password length (default 8)',
    'type'        => 'text',
  },

  {
    'key'         => 'passwordmax',
    'section'     => 'password',
    'description' => 'Maximum password length (default 12) (don\'t set this over 12 if you need to import or export crypt() passwords)',
    'type'        => 'text',
  },

  {
    'key'         => 'sip_passwordmin',
    'section'     => 'telephony',
    'description' => 'Minimum SIP password length (default 6)',
    'type'        => 'text',
  },

  {
    'key'         => 'sip_passwordmax',
    'section'     => 'telephony',
    'description' => 'Maximum SIP password length (default 80)',
    'type'        => 'text',
  },


  {
    'key'         => 'password-noampersand',
    'section'     => 'password',
    'description' => 'Disallow ampersands in passwords',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'password-noexclamation',
    'section'     => 'password',
    'description' => 'Disallow exclamations in passwords (Not setting this could break old text Livingston or Cistron Radius servers)',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'default-password-encoding',
    'section'     => 'password',
    'description' => 'Default storage format for passwords',
    'type'        => 'select',
    'select_hash' => [
      'plain'       => 'Plain text',
      'crypt-des'   => 'Unix password (DES encrypted)',
      'crypt-md5'   => 'Unix password (MD5 digest)',
      'ldap-plain'  => 'LDAP (plain text)',
      'ldap-crypt'  => 'LDAP (DES encrypted)',
      'ldap-md5'    => 'LDAP (MD5 digest)',
      'ldap-sha1'   => 'LDAP (SHA1 digest)',
      'legacy'      => 'Legacy mode',
    ],
  },

  {
    'key'         => 'referraldefault',
    'section'     => 'customer_fields',
    'description' => 'Default referral, specified by refnum',
    'type'        => 'select-sub',
    'options_sub' => sub { require FS::Record;
                           require FS::part_referral;
                           map { $_->refnum => $_->referral }
                               FS::Record::qsearch( 'part_referral', 
			                            { 'disabled' => '' }
						  );
			 },
    'option_sub'  => sub { require FS::Record;
                           require FS::part_referral;
                           my $part_referral = FS::Record::qsearchs(
			     'part_referral', { 'refnum'=>shift } );
                           $part_referral ? $part_referral->referral : '';
			 },
  },

  {
    'key'         => 'maxsearchrecordsperpage',
    'section'     => 'reporting',
    'description' => 'If set, number of search records to return per page.',
    'type'        => 'text',
  },

  {
    'key'         => 'cust_main-packages-num_per_page',
    'section'     => 'packages',
    'description' => 'Number of packages to display per page on customer view (default 10).',
    'type'        => 'text',
  },

  {
    'key'         => 'disable_maxselect',
    'section'     => 'reporting',
    'description' => 'Prevent changing the number of records per page.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'session-start',
    'section'     => 'deprecated',
    'description' => 'Used to define the command which is executed on the Freeside machine when a session begins.  The contents of the file are treated as a double-quoted perl string, with the following variables available: <code>$ip</code>, <code>$nasip</code> and <code>$nasfqdn</code>, which are the IP address of the starting session, and the IP address and fully-qualified domain name of the NAS this session is on.',
    'type'        => 'text',
  },

  {
    'key'         => 'session-stop',
    'section'     => 'deprecated',
    'description' => 'Used to define the command which is executed on the Freeside machine when a session ends.  The contents of the file are treated as a double-quoted perl string, with the following variables available: <code>$ip</code>, <code>$nasip</code> and <code>$nasfqdn</code>, which are the IP address of the starting session, and the IP address and fully-qualified domain name of the NAS this session is on.',
    'type'        => 'text',
  },

  {
    'key'         => 'shells',
    'section'     => 'shell',
    'description' => 'Legal shells (think /etc/shells).  You probably want to `cut -d: -f7 /etc/passwd | sort | uniq\' initially so that importing doesn\'t fail with `Illegal shell\' errors, then remove any special entries afterwords.  A blank line specifies that an empty shell is permitted.',
    'type'        => 'textarea',
  },

  {
    'key'         => 'showpasswords',
    'section'     => 'password',
    'description' => 'Display unencrypted user passwords in the backend (employee) web interface',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'report-showpasswords',
    'section'     => 'password',
    'description' => 'This is a terrible idea.  Do not enable it.  STRONGLY NOT RECOMMENDED.  Enables display of passwords on services reports.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'signupurl',
    'section'     => 'signup',
    'description' => 'if you are using customer-to-customer referrals, and you enter the URL of your <a href="http://www.freeside.biz/mediawiki/index.php/Freeside:3:Documentation:Self-Service_Installation">signup server CGI</a>, the customer view screen will display a customized link to self-signup with the appropriate customer as referral',
    'type'        => 'text',
  },

  {
    'key'         => 'smtpmachine',
    'section'     => 'important',
    'description' => 'SMTP relay for Freeside\'s outgoing mail',
    'type'        => 'text',
  },

  {
    'key'         => 'smtp-username',
    'section'     => 'notification',
    'description' => 'Optional SMTP username for Freeside\'s outgoing mail',
    'type'        => 'text',
  },

  {
    'key'         => 'smtp-password',
    'section'     => 'notification',
    'description' => 'Optional SMTP password for Freeside\'s outgoing mail',
    'type'        => 'text',
  },

  {
    'key'         => 'smtp-encryption',
    'section'     => 'notification',
    'description' => 'Optional SMTP encryption method.  The STARTTLS methods require smtp-username and smtp-password to be set.',
    'type'        => 'select',
    'select_hash' => [ '25'           => 'None (port 25)',
                       '25-starttls'  => 'STARTTLS (port 25)',
                       '587-starttls' => 'STARTTLS / submission (port 587)',
                       '465-tls'      => 'SMTPS (SSL) (port 465)',
                       '2525'         => 'None (Non-standard port 2525)',
                     ],
  },

  {
    'key'         => 'soadefaultttl',
    'section'     => 'BIND',
    'description' => 'SOA default TTL for new domains.',
    'type'        => 'text',
  },

  {
    'key'         => 'soaemail',
    'section'     => 'BIND',
    'description' => 'SOA email for new domains, in BIND form (`.\' instead of `@\'), with trailing `.\'',
    'type'        => 'text',
  },

  {
    'key'         => 'soaexpire',
    'section'     => 'BIND',
    'description' => 'SOA expire for new domains',
    'type'        => 'text',
  },

  {
    'key'         => 'soamachine',
    'section'     => 'BIND',
    'description' => 'SOA machine for new domains, with trailing `.\'',
    'type'        => 'text',
  },

  {
    'key'         => 'soarefresh',
    'section'     => 'BIND',
    'description' => 'SOA refresh for new domains',
    'type'        => 'text',
  },

  {
    'key'         => 'soaretry',
    'section'     => 'BIND',
    'description' => 'SOA retry for new domains',
    'type'        => 'text',
  },

  {
    'key'         => 'statedefault',
    'section'     => 'localization',
    'description' => 'Default state or province (if not supplied, the default is `CA\')',
    'type'        => 'text',
  },

  {
    'key'         => 'unsuspend_balance',
    'section'     => 'suspension',
    'description' => 'Enables the automatic unsuspension of suspended packages when a customer\'s balance due is at or below the specified amount after a payment or credit',
    'type'        => 'select',
    'select_enum' => [ 
      '', 'Zero', 'Latest invoice charges', 'Charges not past due'
    ],
  },

  {
    'key'         => 'unsuspend_reason_type',
    'section'     => 'suspension',
    'description' => 'If set, limits automatic unsuspension to packages which were suspended for this reason type.',
    reason_type_options('S'),
  },

  {
    'key'         => 'unsuspend-always_adjust_next_bill_date',
    'section'     => 'suspension',
    'description' => 'Global override that causes unsuspensions to always adjust the next bill date under any circumstances.  This is now controlled on a per-package bases - probably best not to use this option unless you are a legacy installation that requires this behaviour.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'usernamemin',
    'section'     => 'username',
    'description' => 'Minimum username length (default 2)',
    'type'        => 'text',
  },

  {
    'key'         => 'usernamemax',
    'section'     => 'username',
    'description' => 'Maximum username length',
    'type'        => 'text',
  },

  {
    'key'         => 'username-ampersand',
    'section'     => 'username',
    'description' => 'Allow the ampersand character (&amp;) in usernames.  Be careful when using this option in conjunction with <a href="../browse/part_export.cgi">exports</a> which execute shell commands, as the ampersand will be interpreted by the shell if not quoted.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'username-letter',
    'section'     => 'username',
    'description' => 'Usernames must contain at least one letter',
    'type'        => 'checkbox',
    'per_agent'   => 1,
  },

  {
    'key'         => 'username-letterfirst',
    'section'     => 'username',
    'description' => 'Usernames must start with a letter',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'username-noperiod',
    'section'     => 'username',
    'description' => 'Disallow periods in usernames',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'username-nounderscore',
    'section'     => 'username',
    'description' => 'Disallow underscores in usernames',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'username-nodash',
    'section'     => 'username',
    'description' => 'Disallow dashes in usernames',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'username-uppercase',
    'section'     => 'username',
    'description' => 'Allow uppercase characters in usernames.  Not recommended for use with FreeRADIUS with MySQL backend, which is case-insensitive by default.',
    'type'        => 'checkbox',
    'per_agent'   => 1,
  },

  { 
    'key'         => 'username-percent',
    'section'     => 'username',
    'description' => 'Allow the percent character (%) in usernames.',
    'type'        => 'checkbox',
  },

  { 
    'key'         => 'username-colon',
    'section'     => 'username',
    'description' => 'Allow the colon character (:) in usernames.',
    'type'        => 'checkbox',
  },

  { 
    'key'         => 'username-slash',
    'section'     => 'username',
    'description' => 'Allow the slash character (/) in usernames.  When using, make sure to set "Home directory" to fixed and blank in all svc_acct service definitions.',
    'type'        => 'checkbox',
  },

  { 
    'key'         => 'username-equals',
    'section'     => 'username',
    'description' => 'Allow the equal sign character (=) in usernames.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'google_maps_api_key',
    'section'     => 'addresses',
    'description' => 'API key for google maps.  This must be set for map and directions links to work.  See <a href="https://developers.google.com/maps/documentation/javascript/get-api-key" target="_top">Getting a Google Maps API Key</a>',
    'type'        => 'text',
  },

  {
    'key'         => 'company_physical_address',
    'section'     => 'addresses',
    'description' => 'Your physical company address, for use in supplying google map directions, defaults to company_address',
    'type'        => 'textarea',
    'per_agent'   => 1,
  },

  {
    'key'         => 'show_ship_company',
    'section'     => 'addresses',
    'description' => 'Turns on display/collection of a "service company name" field for customers.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'show_ss',
    'section'     => 'e-checks',
    'description' => 'Turns on display/collection of social security numbers in the web interface.  Sometimes required by electronic check (ACH) processors.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'unmask_ss',
    'section'     => 'deprecated',
    'description' => "Don't mask social security numbers in the web interface.",
    'type'        => 'checkbox',
  },

  {
    'key'         => 'show_stateid',
    'section'     => 'e-checks',
    'description' => "Turns on display/collection of driver's license/state issued id numbers in the web interface.  Sometimes required by electronic check (ACH) processors.",
    'type'        => 'checkbox',
  },

  {
    'key'         => 'national_id-country',
    'section'     => 'localization',
    'description' => 'Track a national identification number, for specific countries.',
    'type'        => 'select',
    'select_enum' => [ '', 'MY' ],
  },

  {
    'key'         => 'show_bankstate',
    'section'     => 'e-checks',
    'description' => "Turns on display/collection of state for bank accounts in the web interface.  Sometimes required by electronic check (ACH) processors.",
    'type'        => 'checkbox',
  },

  { 
    'key'         => 'agent_defaultpkg',
    'section'     => 'packages',
    'description' => 'Setting this option will cause new packages to be available to all agent types by default.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'legacy_link',
    'section'     => 'UI',
    'description' => 'Display options in the web interface to link legacy pre-Freeside services.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'legacy_link-steal',
    'section'     => 'UI',
    'description' => 'Allow "stealing" an already-audited service from one customer (or package) to another using the link function.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'queue_dangerous_controls',
    'section'     => 'development',
    'description' => 'Enable queue modification controls on account pages and for new jobs.  Unless you are a developer working on new export code, you should probably leave this off to avoid causing provisioning problems.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'security_phrase',
    'section'     => 'password',
    'description' => 'Enable the tracking of a "security phrase" with each account.  Not recommended, as it is vulnerable to social engineering.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'locale',
    'section'     => 'localization',
    'description' => 'Default locale',
    'type'        => 'select-sub',
    'options_sub' => sub {
      map { $_ => FS::Locales->description($_) } FS::Locales->locales;
    },
    'option_sub'  => sub {
      FS::Locales->description(shift)
    },
  },

  {
    'key'         => 'signup_server-payby',
    'section'     => 'signup',
    'description' => 'Acceptable payment types for self-signup',
    'type'        => 'selectmultiple',
    'select_enum' => [ qw(CARD DCRD CHEK DCHK PREPAY PPAL ) ], # BILL COMP) ],
  },

  {
    'key'         => 'selfservice-payment_gateway',
    'section'     => 'deprecated',
    'description' => '(no longer supported) Force the use of this payment gateway for self-service.',
    %payment_gateway_options,
  },

  {
    'key'         => 'selfservice-save_unchecked',
    'section'     => 'self-service',
    'description' => 'In self-service, uncheck "Remember information" checkboxes by default (normally, they are checked by default).',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'default_agentnum',
    'section'     => 'customer_fields',
    'description' => 'Default agent for the backoffice',
    'type'        => 'select-agent',
  },

  {
    'key'         => 'signup_server-default_agentnum',
    'section'     => 'signup',
    'description' => 'Default agent for self-signup',
    'type'        => 'select-agent',
  },

  {
    'key'         => 'signup_server-default_refnum',
    'section'     => 'signup',
    'description' => 'Default advertising source for self-signup',
    'type'        => 'select-sub',
    'options_sub' => sub { require FS::Record;
                           require FS::part_referral;
                           map { $_->refnum => $_->referral }
                               FS::Record::qsearch( 'part_referral', 
			                            { 'disabled' => '' }
						  );
			 },
    'option_sub'  => sub { require FS::Record;
                           require FS::part_referral;
                           my $part_referral = FS::Record::qsearchs(
			     'part_referral', { 'refnum'=>shift } );
                           $part_referral ? $part_referral->referral : '';
			 },
  },

  {
    'key'         => 'signup_server-default_pkgpart',
    'section'     => 'signup',
    'description' => 'Default package for self-signup',
    'type'        => 'select-part_pkg',
  },

  {
    'key'         => 'signup_server-default_svcpart',
    'section'     => 'signup',
    'description' => 'Default service definition for self-signup - only necessary for services that trigger special provisioning widgets (such as DID provisioning or domain selection).',
    'type'        => 'select-part_svc',
  },

  {
    'key'         => 'signup_server-default_domsvc',
    'section'     => 'signup',
    'description' => 'If specified, the default domain svcpart for self-signup (useful when domain is set to selectable choice).',
    'type'        => 'text',
  },

  {
    'key'         => 'signup_server-mac_addr_svcparts',
    'section'     => 'signup',
    'description' => 'Service definitions which can receive mac addresses (current mapped to username for svc_acct).',
    'type'        => 'select-part_svc',
    'multiple'    => 1,
  },

  {
    'key'         => 'signup_server-nomadix',
    'section'     => 'deprecated',
    'description' => 'Signup page Nomadix integration',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'signup_server-service',
    'section'     => 'signup',
    'description' => 'Service for the self-signup - "Account (svc_acct)" is the default setting, or "Phone number (svc_phone)" for ITSP signup',
    'type'        => 'select',
    'select_hash' => [
                       'svc_acct'  => 'Account (svc_acct)',
                       'svc_phone' => 'Phone number (svc_phone)',
                       'svc_pbx'   => 'PBX (svc_pbx)',
                       'none'      => 'None - package only',
                     ],
  },
  
  {
    'key'         => 'signup_server-prepaid-template-custnum',
    'section'     => 'signup',
    'description' => 'When self-signup is used with prepaid cards and customer info is not required for signup, the contact/address info will be copied from this customer, if specified',
    'type'        => 'text',
  },

  {
    'key'         => 'signup_server-terms_of_service',
    'section'     => 'signup',
    'description' => 'Terms of Service for self-signup.  May contain HTML.',
    'type'        => 'textarea',
    'per_agent'   => 1,
  },

  {
    'key'         => 'selfservice_server-base_url',
    'section'     => 'self-service',
    'description' => 'Base URL for the self-service web interface - necessary for some widgets to find their way, including retrieval of non-US state information and phone number provisioning.',
    'type'        => 'text',
  },

  {
    'key'         => 'show-msgcat-codes',
    'section'     => 'development',
    'description' => 'Show msgcat codes in error messages.  Turn this option on before reporting errors to the mailing list.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'signup_server-realtime',
    'section'     => 'signup',
    'description' => 'Run billing for self-signups immediately, and do not provision accounts which subsequently have a balance.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'signup_server-classnum2',
    'section'     => 'signup',
    'description' => 'Package Class for first optional purchase',
    'type'        => 'select-pkg_class',
  },

  {
    'key'         => 'signup_server-classnum3',
    'section'     => 'signup',
    'description' => 'Package Class for second optional purchase',
    'type'        => 'select-pkg_class',
  },

  {
    'key'         => 'signup_server-third_party_as_card',
    'section'     => 'signup',
    'description' => 'Allow customer payment type to be set to CARD even when using third-party credit card billing.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'selfservice-xmlrpc',
    'section'     => 'API',
    'description' => 'Run a standalone self-service XML-RPC server on the backend (on port 8080).',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'selfservice-timeout',
    'section'     => 'self-service',
    'description' => 'Timeout for the self-service login cookie, in seconds.  Defaults to 1 hour.',
    'type'        => 'text',
  },

  {
    'key'         => 'backend-realtime',
    'section'     => 'billing',
    'description' => 'Run billing for backend signups immediately.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'decline_msgnum',
    'section'     => 'notification',
    'description' => 'Template to use for credit card and electronic check decline messages.',
    %msg_template_options,
  },

  {
    'key'         => 'emaildecline',
    'section'     => 'notification',
    'description' => 'Enable emailing of credit card and electronic check decline notices.',
    'type'        => 'checkbox',
    'per_agent'   => 1,
  },

  {
    'key'         => 'emaildecline-exclude',
    'section'     => 'notification',
    'description' => 'List of error messages that should not trigger email decline notices, one per line.',
    'type'        => 'textarea',
    'per_agent'   => 1,
  },

  {
    'key'         => 'cancel_msgnum',
    'section'     => 'cancellation',
    'description' => 'Template to use for cancellation emails.',
    %msg_template_options,
  },

  {
    'key'         => 'emailcancel',
    'section'     => 'cancellation',
    'description' => 'Enable emailing of cancellation notices.  Make sure to select the template in the cancel_msgnum option.',
    'type'        => 'checkbox',
    'per_agent'   => 1,
  },

  {
    'key'         => 'bill_usage_on_cancel',
    'section'     => 'cancellation',
    'description' => 'Enable automatic generation of an invoice for usage when a package is cancelled.  Not all packages can do this.  Usage data must already be available.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cancel_msgnum-referring_cust-pkg_class',
    'section'     => 'cancellation',
    'description' => 'Enable cancellation messages to the referring customer for these package classes.',
    'type'        => 'select-pkg_class',
    'multiple'    => 1,
  },

  {
    'key'         => 'cancel_msgnum-referring_cust',
    'section'     => 'cancellation',
    'description' => 'Template to use for cancellation emails sent to the referring customer.',
    %msg_template_options,
  },

  {
    'key'         => 'require_cardname',
    'section'     => 'credit_cards',
    'description' => 'Require an "Exact name on card" to be entered explicitly; don\'t default to using the first and last name.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'enable_taxclasses',
    'section'     => 'taxation',
    'description' => 'Enable per-package tax classes',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'require_taxclasses',
    'section'     => 'taxation',
    'description' => 'Require a taxclass to be entered for every package',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'tax_data_vendor',
    'section'     => 'taxation',
    'description' => 'Tax data vendor you are using.',
    'type'        => 'select',
    'select_enum' => [ '', 'cch', 'billsoft', 'avalara', 'suretax', 'compliance_solutions' ],
  },

  {
    'key'         => 'taxdatadirectdownload',
    'section'     => 'taxation',
    'description' => 'Enable downloading tax data directly from CCH. at least three lines: URL, username, and password.j',
    'type'        => 'textarea',
  },

  {
    'key'         => 'ignore_incalculable_taxes',
    'section'     => 'taxation',
    'description' => 'Prefer to invoice without tax over not billing at all',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'billsoft-company_code',
    'section'     => 'taxation',
    'description' => 'Billsoft (AvaTax for Communications) tax service company code (3 letters)',
    'type'        => 'text',
  },

  {
    'key'         => 'billsoft-taxconfig',
    'section'     => 'taxation',
    'description' => 'Billsoft tax configuration flags. Four lines: Facilities, Franchise, Regulated, Business Class. See the Avalara documentation for instructions on setting these flags.',
    'type'        => 'textarea',
  },

  {
    'key'         => 'avalara-taxconfig',
    'section'     => 'taxation',
    'description' => 'Avalara tax service configuration. Four lines: company code, account number, license key, test mode (1 to enable).',
    'type'        => 'textarea',
  },

  {
    'key'         => 'suretax-hostname',
    'section'     => 'taxation',
    'description' => 'SureTax server name; defaults to the test server.',
    'type'        => 'text',
  },

  {
    'key'         => 'suretax-client_number',
    'section'     => 'taxation',
    'description' => 'SureTax tax service client ID.',
    'type'        => 'text',
  },
  {
    'key'         => 'suretax-validation_key',
    'section'     => 'taxation',
    'description' => 'SureTax validation key (UUID).',
    'type'        => 'text',
  },
  {
    'key'         => 'suretax-business_unit',
    'section'     => 'taxation',
    'description' => 'SureTax client business unit name; optional.',
    'type'        => 'text',
    'per_agent'   => 1,
  },
  {
    'key'         => 'suretax-regulatory_code',
    'section'     => 'taxation',
    'description' => 'SureTax client regulatory status.',
    'type'        => 'select',
    'select_enum' => [ '', 'ILEC', 'IXC', 'CLEC', 'VOIP', 'ISP', 'Wireless' ],
    'per_agent'   => 1,
  },

  {
    'key'         => 'compliance_solutions-access_code',
    'section'     => 'taxation',
    'description' => 'Access code for <a href="http://csilongwood.com/">Compliance Solutions</a> tax rating service',
    'type'        => 'text',
  },
  {
    'key'         => 'compliance_solutions-regulatory_code',
    'section'     => 'taxation',
    'description' => 'Compliance Solutions regulatory status.',
    'type'        => 'select',
    'select_enum' => [ '', 'ILEC', 'IXC', 'CLEC', 'VOIP', 'ISP', 'Wireless' ],
    'per_agent'   => 1,
  },

  {
    'key'         => 'welcome_msgnum',
    'section'     => 'deprecated',
    'description' => 'Deprecated; use a billing event instead.  Used to be the template to use for welcome messages when a svc_acct record is created.',
    %msg_template_options,
  },
  
  {
    'key'         => 'svc_acct_welcome_exclude',
    'section'     => 'deprecated',
    'description' => 'Deprecated; use a billing event instead.  A list of svc_acct services for which no welcome email is to be sent.',
    'type'        => 'select-part_svc',
    'multiple'    => 1,
  },

  {
    'key'         => 'welcome_letter',
    'section'     => 'notification',
    'description' => 'Optional LaTex template file for a printed welcome letter.  A welcome letter is printed the first time a cust_pkg record is created.  See the <a href="http://search.cpan.org/dist/Text-Template/lib/Text/Template.pm">Text::Template</a> documentation and the billing documentation for details on the template substitution language.  A variable exists for each fieldname in the customer record (<code>$first, $last, etc</code>).  The following additional variables are available<ul><li><code>$payby</code> - a friendler represenation of the field<li><code>$payinfo</code> - the masked payment information<li><code>$expdate</code> - the time at which the payment method expires (a UNIX timestamp)<li><code>$returnaddress</code> - the invoice return address for this customer\'s agent</ul>',
    'type'        => 'textarea',
  },

  {
    'key'         => 'threshold_warning_msgnum',
    'section'     => 'notification',
    'description' => 'Template to use for warning messages sent to the customer email invoice destination(s) when a svc_acct record has its usage drop below a threshold.  Extra substitutions available: $column, $amount, $threshold',
    %msg_template_options,
  },

  {
    'key'         => 'payby',
    'section'     => 'payments',
    'description' => 'Available payment types.',
    'type'        => 'selectmultiple',
    'select_enum' => [ qw(CARD DCRD CHEK DCHK PPAL) ], #BILL CASH WEST MCRD MCHK PPAL) ],
  },

  {
    'key'         => 'processing-fee',
    'section'     => 'payments',
    'description' => 'Fee for back end payment processing.',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'processing-fee_on_separate_invoice',
    'section'     => 'payments',
    'description' => 'Places the processing fee on a separate invoice by itself.  Only works with real time processing.',
    'type'        => 'checkbox',
    'validate'    => sub {
                        my $conf = new FS::Conf;
                        !$conf->config('batch-enable_payby') ? '' : 'You can not set this option while batch processing is enabled.';
                     },
  },

  {
    'key'         => 'banned_pay-pad',
    'section'     => 'credit_cards',
    'description' => 'Padding for encrypted storage of banned credit card hashes.  If you already have new-style SHA512 entries in the banned_pay table, do not change as this will invalidate the old entries.',
    'type'        => 'text',
  },

  {
    'key'         => 'payby-default',
    'section'     => 'deprecated',
    'description' => 'Deprecated; in 4.x there is no longer the concept of a single "payment type".  Used to indicate the default payment type.  HIDE disables display of billing information and sets customers to BILL.',
    'type'        => 'select',
    'select_enum' => [ '', qw(CARD DCRD CHEK DCHK BILL CASH WEST MCRD PPAL COMP HIDE) ],
  },

  {
    'key'         => 'require_cash_deposit_info',
    'section'     => 'payments',
    'description' => 'When recording cash payments, display bank deposit information fields.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'svc_acct-notes',
    'section'     => 'deprecated',
    'description' => 'Extra HTML to be displayed on the Account View screen.',
    'type'        => 'textarea',
  },

  {
    'key'         => 'radius-password',
    'section'     => 'RADIUS',
    'description' => 'RADIUS attribute for plain-text passwords.',
    'type'        => 'select',
    'select_enum' => [ 'Password', 'User-Password', 'Cleartext-Password' ],
  },

  {
    'key'         => 'radius-ip',
    'section'     => 'RADIUS',
    'description' => 'RADIUS attribute for IP addresses.',
    'type'        => 'select',
    'select_enum' => [ 'Framed-IP-Address', 'Framed-Address' ],
  },

  #http://dev.coova.org/svn/coova-chilli/doc/dictionary.chillispot
  {
    'key'         => 'radius-chillispot-max',
    'section'     => 'RADIUS',
    'description' => 'Enable ChilliSpot (and CoovaChilli) Max attributes, specifically ChilliSpot-Max-{Input,Output,Total}-{Octets,Gigawords}.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'radius-canopy',
    'section'     => 'RADIUS',
    'description' => 'Enable RADIUS attributes for Cambium (formerly Motorola) Canopy (Motorola-Canopy-Gateway).',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'svc_broadband-radius',
    'section'     => 'RADIUS',
    'description' => 'Enable RADIUS groups for broadband services.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'svc_acct-alldomains',
    'section'     => 'services',
    'description' => 'Allow accounts to select any domain in the database.  Normally accounts can only select from the domain set in the service definition and those purchased by the customer.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'dump-localdest',
    'section'     => 'backup',
    'description' => 'Destination for local database dumps (full path)',
    'type'        => 'text',
  },

  {
    'key'         => 'dump-scpdest',
    'section'     => 'backup',
    'description' => 'Destination for scp database dumps: user@host:/path',
    'type'        => 'text',
  },

  {
    'key'         => 'dump-pgpid',
    'section'     => 'backup',
    'description' => "Optional PGP public key user or key id for database dumps.  The public key should exist on the freeside user's public keyring, and the gpg binary and GnuPG perl module should be installed.",
    'type'        => 'text',
  },

  {
    'key'         => 'credit_card-recurring_billing_flag',
    'section'     => 'credit_cards',
    'description' => 'This controls when the system passes the "recurring_billing" flag on credit card transactions.  If supported by your processor (and the Business::OnlinePayment processor module), passing the flag indicates this is a recurring transaction and may turn off the CVV requirement. ',
    'type'        => 'select',
    'select_hash' => [
                       'actual_oncard' => 'Default/classic behavior: set the flag if a customer has actual previous charges on the card.',
		       'transaction_is_recur' => 'Set the flag if the transaction itself is recurring, regardless of previous charges on the card.',
                     ],
  },

  {
    'key'         => 'credit_card-recurring_billing_acct_code',
    'section'     => 'credit_cards',
    'description' => 'When the "recurring billing" flag is set, also set the "acct_code" to "rebill".  Useful for reporting purposes with supported gateways (PlugNPay, others?)',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cvv-save',
    'section'     => 'credit_cards',
    'description' => 'NOT RECOMMENDED.  Saves CVV2 information after the initial transaction for the selected credit card types.  Enabling this option is almost certainly in violation of your merchant agreement(s), so please check them carefully before enabling this option for any credit card types.',
    'type'        => 'selectmultiple',
    'select_enum' => \@card_types,
  },

  {
    'key'         => 'signup-require_cvv',
    'section'     => 'credit_cards',
    'description' => 'Require CVV for credit card signup.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'backoffice-require_cvv',
    'section'     => 'credit_cards',
    'description' => 'Require CVV for manual credit card entry.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'selfservice-onfile_require_cvv',
    'section'     => 'credit_cards',
    'description' => 'Require CVV for on-file credit card during self-service payments.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'selfservice-require_cvv',
    'section'     => 'credit_cards',
    'description' => 'Require CVV for credit card self-service payments, except for cards on-file.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'manual_process-single_invoice_amount',
    'section'     => 'deprecated',
    'description' => 'When entering manual credit card and ACH payments, amount will not autofill if the customer has more than one open invoice',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'manual_process-pkgpart',
    'section'     => 'payments',
    'description' => 'Package to add to each manual credit card and ACH payment entered by employees from the backend.  WARNING: Although recently permitted to US merchants in general, specific consumer protection laws may prohibit or restrict this practice in California, Colorado, Connecticut, Florda, Kansas, Maine, Massachusetts, New York, Oklahome, and Texas. Surcharging is also generally prohibited in most countries outside the US, AU and UK.',
    'type'        => 'select-part_pkg',
    'per_agent'   => 1,
  },

  {
    'key'         => 'manual_process-display',
    'section'     => 'payments',
    'description' => 'When using manual_process-pkgpart, add the fee to the amount entered (default), or subtract the fee from the amount entered.',
    'type'        => 'select',
    'select_hash' => [
                       'add'      => 'Add fee to amount entered',
                       'subtract' => 'Subtract fee from amount entered',
                     ],
  },

  {
    'key'         => 'manual_process-skip_first',
    'section'     => 'payments',
    'description' => "When using manual_process-pkgpart, omit the fee if it is the customer's first payment.",
    'type'        => 'checkbox',
  },

  {
    'key'         => 'selfservice_immutable-package',
    'section'     => 'self-service',
    'description' => 'Disable package changes in self-service interface.',
    'type'        => 'checkbox',
    'per_agent'   => 1,
  },

  {
    'key'         => 'selfservice_hide-usage',
    'section'     => 'self-service',
    'description' => 'Hide usage data in self-service interface.',
    'type'        => 'checkbox',
    'per_agent'   => 1,
  },

  {
    'key'         => 'selfservice_process-pkgpart',
    'section'     => 'payments',
    'description' => 'Package to add to each manual credit card and ACH payment entered by the customer themselves in the self-service interface.  Enabling this option may be in violation of your merchant agreement(s), so please check it(/them) carefully before enabling this option.',
    'type'        => 'select-part_pkg',
    'per_agent'   => 1,
  },

  {
    'key'         => 'selfservice_process-display',
    'section'     => 'payments',
    'description' => 'When using selfservice_process-pkgpart, add the fee to the amount entered (default), or subtract the fee from the amount entered.',
    'type'        => 'select',
    'select_hash' => [
                       'add'      => 'Add fee to amount entered',
                       'subtract' => 'Subtract fee from amount entered',
                     ],
  },

  {
    'key'         => 'selfservice_process-skip_first',
    'section'     => 'payments',
    'description' => "When using selfservice_process-pkgpart, omit the fee if it is the customer's first payment.",
    'type'        => 'checkbox',
  },

#  {
#    'key'         => 'auto_process-pkgpart',
#    'section'     => 'billing',
#    'description' => 'Package to add to each automatic credit card and ACH payment processed by billing events.  Enabling this option may be in violation of your merchant agreement(s), so please check them carefully before enabling this option.',
#    'type'        => 'select-part_pkg',
#  },
#
##  {
##    'key'         => 'auto_process-display',
##    'section'     => 'billing',
##    'description' => 'When using auto_process-pkgpart, add the fee to the amount entered (default), or subtract the fee from the amount entered.',
##    'type'        => 'select',
##    'select_hash' => [
##                       'add'      => 'Add fee to amount entered',
##                       'subtract' => 'Subtract fee from amount entered',
##                     ],
##  },
#
#  {
#    'key'         => 'auto_process-skip_first',
#    'section'     => 'billing',
#    'description' => "When using auto_process-pkgpart, omit the fee if it is the customer's first payment.",
#    'type'        => 'checkbox',
#  },

  {
    'key'         => 'allow_negative_charges',
    'section'     => 'deprecated',
    'description' => 'Allow negative charges.  Normally not used unless importing data from a legacy system that requires this.',
    'type'        => 'checkbox',
  },
  {
      'key'         => 'auto_unset_catchall',
      'section'     => 'cancellation',
      'description' => 'When canceling a svc_acct that is the email catchall for one or more svc_domains, automatically set their catchall fields to null.  If this option is not set, the attempt will simply fail.',
      'type'        => 'checkbox',
  },

  {
    'key'         => 'system_usernames',
    'section'     => 'username',
    'description' => 'A list of system usernames that cannot be edited or removed, one per line.  Use a bare username to prohibit modification/deletion of the username in any domain, or username@domain to prohibit modification/deletetion of a specific username and domain.',
    'type'        => 'textarea',
  },

  {
    'key'         => 'cust_pkg-change_svcpart',
    'section'     => 'packages',
    'description' => "When changing packages, move services even if svcparts don't match between old and new pacakge definitions.",
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_pkg-change_pkgpart-bill_now',
    'section'     => 'RADIUS',
    'description' => "When changing packages, bill the new package immediately.  Useful for prepaid situations with RADIUS where an Expiration attribute based on the package must be present at all times.",
    'type'        => 'checkbox',
  },

  {
    'key'         => 'disable_autoreverse',
    'section'     => 'BIND',
    'description' => 'Disable automatic synchronization of reverse-ARPA entries.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'svc_www-enable_subdomains',
    'section'     => 'services',
    'description' => 'Enable selection of specific subdomains for virtual host creation.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'svc_www-usersvc_svcpart',
    'section'     => 'services',
    'description' => 'Allowable service definition svcparts for virtual hosts, one per line.',
    'type'        => 'select-part_svc',
    'multiple'    => 1,
  },

  {
    'key'         => 'selfservice_server-primary_only',
    'section'     => 'self-service',
    'description' => 'Only allow primary accounts to access self-service functionality.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'selfservice_server-phone_login',
    'section'     => 'self-service',
    'description' => 'Allow login to self-service with phone number and PIN.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'selfservice_server-single_domain',
    'section'     => 'self-service',
    'description' => 'If specified, only use this one domain for self-service access.',
    'type'        => 'text',
  },

  {
    'key'         => 'selfservice_server-login_svcpart',
    'section'     => 'self-service',
    'description' => 'If specified, only allow the specified svcparts to login to self-service.',
    'type'        => 'select-part_svc',
    'multiple'    => 1,
  },

  {
    'key'         => 'selfservice-svc_forward_svcpart',
    'section'     => 'self-service',
    'description' => 'Service for self-service forward editing.',
    'type'        => 'select-part_svc',
  },

  {
    'key'         => 'selfservice-password_reset_verification',
    'section'     => 'self-service',
    'description' => 'If enabled, specifies the type of verification required for self-service password resets.',
    'type'        => 'select',
    'select_hash' => [ '' => 'Password reset disabled',
                       'email' => 'Click on a link in email',
                       'paymask,amount,zip' => 'Click on a link in email, and also verify with credit card (or bank account) last 4 digits, payment amount and zip code.  Note: Do not use if you have multi-customer contacts, as they will be unable to reset their passwords.',
                     ],
  },

  {
    'key'         => 'selfservice-password_reset_hours',
    'section'     => 'self-service',
    'description' => 'Numbers of hours an email password reset is valid.  Defaults to 24.',
    'type'        => 'text',
  },

  {
    'key'         => 'selfservice-password_reset_msgnum',
    'section'     => 'self-service',
    'description' => 'Template to use for password reset emails.',
    %msg_template_options,
  },

  {
    'key'         => 'selfservice-password_change_oldpass',
    'section'     => 'self-service',
    'description' => 'Require old password to be entered again for password changes (in addition to being logged in), at the API level.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'selfservice-hide_invoices-taxclass',
    'section'     => 'self-service',
    'description' => 'Hide invoices with only this package tax class from self-service and supress sending (emailing, printing, faxing) them.  Typically set to something like "Previous balance" and used when importing legacy invoices into legacy_cust_bill.',
    'type'        => 'text',
  },

  {
    'key'         => 'selfservice-recent-did-age',
    'section'     => 'self-service',
    'description' => 'If specified, defines "recent", in number of seconds, for "Download recently allocated DIDs" in self-service.',
    'type'        => 'text',
  },

  {
    'key'         => 'selfservice_server-view-wholesale',
    'section'     => 'self-service',
    'description' => 'If enabled, use a wholesale package view in the self-service.',
    'type'        => 'checkbox',
  },
  
  {
    'key'         => 'selfservice-agent_signup',
    'section'     => 'self-service',
    'description' => 'Allow agent signup via self-service.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'selfservice-agent_signup-agent_type',
    'section'     => 'self-service',
    'description' => 'Agent type when allowing agent signup via self-service.',
    'type'        => 'select-sub',
    'options_sub' => sub { require FS::Record;
                           require FS::agent_type;
			   map { $_->typenum => $_->atype }
                               FS::Record::qsearch('agent_type', {} ); # disabled=>'' } );
			 },
    'option_sub'  => sub { require FS::Record;
                           require FS::agent_type;
			   my $agent_type = FS::Record::qsearchs(
			     'agent_type', { 'typenum'=>shift }
			   );
                           $agent_type ? $agent_type->atype : '';
			 },
  },

  {
    'key'         => 'selfservice-agent_login',
    'section'     => 'self-service',
    'description' => 'Allow agent login via self-service.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'selfservice-self_suspend_reason',
    'section'     => 'self-service',
    'description' => 'Suspend reason when customers suspend their own packages. Set to nothing to disallow self-suspension.',
    'type'        => 'select-sub',
    #false laziness w/api_credit_reason
    'options_sub' => sub { require FS::Record;
                           require FS::reason;
                           my $type = qsearchs('reason_type', 
                             { class => 'S' }) 
                              or return ();
			   map { $_->reasonnum => $_->reason }
                               FS::Record::qsearch('reason', 
                                 { reason_type => $type->typenum } 
                               );
			 },
    'option_sub'  => sub { require FS::Record;
                           require FS::reason;
			   my $reason = FS::Record::qsearchs(
			     'reason', { 'reasonnum' => shift }
			   );
                           $reason ? $reason->reason : '';
			 },

    'per_agent'   => 1,
  },

  {
    'key'         => 'card_refund-days',
    'section'     => 'credit_cards',
    'description' => 'After a payment, the number of days a refund link will be available for that payment.  Defaults to 120.',
    'type'        => 'text',
  },

  {
    'key'         => 'agent-showpasswords',
    'section'     => 'deprecated',
    'description' => 'Display unencrypted user passwords in the agent (reseller) interface',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'global_unique-username',
    'section'     => 'username',
    'description' => 'Global username uniqueness control: none (usual setting - check uniqueness per exports), username (all usernames are globally unique, regardless of domain or exports), or username@domain (all username@domain pairs are globally unique, regardless of exports).  disabled turns off duplicate checking completely and is STRONGLY NOT RECOMMENDED unless you REALLY need to turn this off.',
    'type'        => 'select',
    'select_enum' => [ 'none', 'username', 'username@domain', 'disabled' ],
  },

  {
    'key'         => 'global_unique-phonenum',
    'section'     => 'telephony',
    'description' => 'Global phone number uniqueness control: none (usual setting - check countrycode+phonenumun uniqueness per exports), or countrycode+phonenum (all countrycode+phonenum pairs are globally unique, regardless of exports).  disabled turns off duplicate checking completely and is STRONGLY NOT RECOMMENDED unless you REALLY need to turn this off.',
    'type'        => 'select',
    'select_enum' => [ 'none', 'countrycode+phonenum', 'disabled' ],
  },

  {
    'key'         => 'global_unique-pbx_title',
    'section'     => 'telephony',
    'description' => 'Global phone number uniqueness control: none (check uniqueness per exports), enabled (check across all services), or disabled (no duplicate checking).',
    'type'        => 'select',
    'select_enum' => [ 'enabled', 'disabled' ],
  },

  {
    'key'         => 'global_unique-pbx_id',
    'section'     => 'telephony',
    'description' => 'Global PBX id uniqueness control: none (check uniqueness per exports), enabled (check across all services), or disabled (no duplicate checking).',
    'type'        => 'select',
    'select_enum' => [ 'enabled', 'disabled' ],
  },

  {
    'key'         => 'svc_external-skip_manual',
    'section'     => 'UI',
    'description' => 'When provisioning svc_external services, skip manual entry of id and title fields in the UI.  Usually used in conjunction with an export that populates these fields (i.e. artera_turbo).',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'svc_external-display_type',
    'section'     => 'UI',
    'description' => 'Select a specific svc_external type to enable some UI changes specific to that type (i.e. artera_turbo).',
    'type'        => 'select',
    'select_enum' => [ 'generic', 'artera_turbo', ],
  },

  {
    'key'         => 'ticket_system',
    'section'     => 'ticketing',
    'description' => 'Ticketing system integration.  <b>RT_Internal</b> uses the built-in RT ticketing system (see the <a href="http://www.freeside.biz/mediawiki/index.php/Freeside:3:Documentation:RT_Installation">integrated ticketing installation instructions</a>).   <b>RT_External</b> accesses an external RT installation in a separate database (local or remote).',
    'type'        => 'select',
    #'select_enum' => [ '', qw(RT_Internal RT_Libs RT_External) ],
    'select_enum' => [ '', qw(RT_Internal RT_External) ],
  },

  {
    'key'         => 'network_monitoring_system',
    'section'     => 'network_monitoring',
    'description' => 'Networking monitoring system (NMS) integration.  <b>Torrus_Internal</b> uses the built-in Torrus network monitoring system (see the <a href="http://www.freeside.biz/mediawiki/index.php/Freeside:3:Documentation:Torrus_Installation">installation instructions</a>).',
    'type'        => 'select',
    'select_enum' => [ '', qw(Torrus_Internal) ],
  },

  {
    'key'         => 'nms-auto_add-svc_ips',
    'section'     => 'network_monitoring',
    'description' => 'Automatically add (and remove) IP addresses from these service tables to the network monitoring system.',
    'type'        => 'selectmultiple',
    'select_enum' => [ 'svc_acct', 'svc_broadband', 'svc_dsl' ],
  },

  {
    'key'         => 'nms-auto_add-community',
    'section'     => 'network_monitoring',
    'description' => 'SNMP community string to use when automatically adding IP addresses from these services to the network monitoring system.',
    'type'        => 'text',
  },

  {
    'key'         => 'pingd-interval',
    'section'     => 'network_monitoring',
    'description' => 'Run ping scans of broadband services at this interval.',
    'type'        => 'select',
    'select_hash' => [ ''     => '',
                       60     => '1 min',
                       300    => '5 min',
                       600    => '10 min',
                       1800   => '30 min',
                       3600   => '1 hour',
                       14400  => '4 hours',
                       28800  => '8 hours',
                       86400  => '1 day',
                     ],
  },

  {
    'key'         => 'ticket_system-default_queueid',
    'section'     => 'ticketing',
    'description' => 'Default queue used when creating new customer tickets.',
    'type'        => 'select-sub',
    'options_sub' => sub {
                           my $conf = new FS::Conf;
                           if ( $conf->config('ticket_system') ) {
                             eval "use FS::TicketSystem;";
                             die $@ if $@;
                             FS::TicketSystem->queues();
                           } else {
                             ();
                           }
                         },
    'option_sub'  => sub { 
                           my $conf = new FS::Conf;
                           if ( $conf->config('ticket_system') ) {
                             eval "use FS::TicketSystem;";
                             die $@ if $@;
                             FS::TicketSystem->queue(shift);
                           } else {
                             '';
                           }
                         },
  },

  {
    'key'         => 'ticket_system-force_default_queueid',
    'section'     => 'ticketing',
    'description' => 'Disallow queue selection when creating new tickets from customer view.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'ticket_system-selfservice_queueid',
    'section'     => 'ticketing',
    'description' => 'Queue used when creating new customer tickets from self-service.  Defautls to ticket_system-default_queueid if not specified.',
    #false laziness w/above
    'type'        => 'select-sub',
    'options_sub' => sub {
                           my $conf = new FS::Conf;
                           if ( $conf->config('ticket_system') ) {
                             eval "use FS::TicketSystem;";
                             die $@ if $@;
                             FS::TicketSystem->queues();
                           } else {
                             ();
                           }
                         },
    'option_sub'  => sub { 
                           my $conf = new FS::Conf;
                           if ( $conf->config('ticket_system') ) {
                             eval "use FS::TicketSystem;";
                             die $@ if $@;
                             FS::TicketSystem->queue(shift);
                           } else {
                             '';
                           }
                         },
  },

  {
    'key'         => 'ticket_system-requestor',
    'section'     => 'ticketing',
    'description' => 'Email address to use as the requestor for new tickets.  If blank, the customer\'s invoicing address(es) will be used.',
    'type'        => 'text',
  },

  {
    'key'         => 'ticket_system-priority_reverse',
    'section'     => 'ticketing',
    'description' => 'Enable this to consider lower numbered priorities more important.  A bad habit we picked up somewhere.  You probably want to avoid it and use the default.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'ticket_system-custom_priority_field',
    'section'     => 'ticketing',
    'description' => 'Custom field from the ticketing system to use as a custom priority classification.',
    'type'        => 'text',
  },

  {
    'key'         => 'ticket_system-custom_priority_field-values',
    'section'     => 'ticketing',
    'description' => 'Values for the custom field from the ticketing system to break down and sort customer ticket lists.',
    'type'        => 'textarea',
  },

  {
    'key'         => 'ticket_system-custom_priority_field_queue',
    'section'     => 'ticketing',
    'description' => 'Ticketing system queue in which the custom field specified in ticket_system-custom_priority_field is located.',
    'type'        => 'text',
  },

  {
    'key'         => 'ticket_system-selfservice_priority_field',
    'section'     => 'ticketing',
    'description' => 'Custom field from the ticket system to use as a customer-managed priority field.',
    'type'        => 'text',
  },

  {
    'key'         => 'ticket_system-selfservice_edit_subject',
    'section'     => 'ticketing',
    'description' => 'Allow customers to edit ticket subjects through selfservice.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'ticket_system-appointment-queueid',
    'section'     => 'appointments',
    'description' => 'Ticketing queue to use for appointments.',
    #false laziness w/above
    'type'        => 'select-sub',
    'options_sub' => sub {
                           my $conf = new FS::Conf;
                           if ( $conf->config('ticket_system') ) {
                             eval "use FS::TicketSystem;";
                             die $@ if $@;
                             FS::TicketSystem->queues();
                           } else {
                             ();
                           }
                         },
    'option_sub'  => sub { 
                           my $conf = new FS::Conf;
                           if ( $conf->config('ticket_system') ) {
                             eval "use FS::TicketSystem;";
                             die $@ if $@;
                             FS::TicketSystem->queue(shift);
                           } else {
                             '';
                           }
                         },
  },

  {
    'key'         => 'ticket_system-appointment-custom_field',
    'section'     => 'appointments',
    'description' => 'Ticketing custom field to use as an appointment classification.',
    'type'        => 'text',
  },

  {
    'key'         => 'ticket_system-escalation',
    'section'     => 'ticketing',
    'description' => 'Enable priority escalation of tickets as part of daily batch processing.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'ticket_system-rt_external_datasrc',
    'section'     => 'ticketing',
    'description' => 'With external RT integration, the DBI data source for the external RT installation, for example, <code>DBI:Pg:user=rt_user;password=rt_word;host=rt.example.com;dbname=rt</code>',
    'type'        => 'text',

  },

  {
    'key'         => 'ticket_system-rt_external_url',
    'section'     => 'ticketing',
    'description' => 'With external RT integration, the URL for the external RT installation, for example, <code>https://rt.example.com/rt</code>',
    'type'        => 'text',
  },

  {
    'key'         => 'company_name',
    'section'     => 'important',
    'description' => 'Your company name',
    'type'        => 'text',
    'per_agent'   => 1, #XXX just FS/FS/ClientAPI/Signup.pm
  },

  {
    'key'         => 'company_url',
    'section'     => 'UI',
    'description' => 'Your company URL',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'company_address',
    'section'     => 'important',
    'description' => 'Your company address',
    'type'        => 'textarea',
    'per_agent'   => 1,
  },

  {
    'key'         => 'company_phonenum',
    'section'     => 'important',
    'description' => 'Your company phone number',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'address1-search',
    'section'     => 'addresses',
    'description' => 'Enable the ability to search the address1 field from the quick customer search.  Not recommended in most cases as it tends to bring up too many search results - use explicit address searching from the advanced customer search instead.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'address2-search',
    'section'     => 'addresses',
    'description' => 'Enable a "Unit" search box which searches the second address field.  Useful for multi-tenant applications.  See also: cust_main-require_address2',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_main-require_address2',
    'section'     => 'addresses',
    'description' => 'Second address field is required.  Also enables "Unit" labeling of address2 on customer view and edit pages.  Useful for multi-tenant applications.  See also: address2-search', # service address only part not working in the modern world, see #41184  (on service address only, if billing and service addresses differ)
    'type'        => 'checkbox',
  },

  {
    'key'         => 'agent-ship_address',
    'section'     => 'addresses',
    'description' => "Use the agent's master service address as the service address (only ship_address2 can be entered, if blank on the master address).  Useful for multi-tenant applications.",
    'type'        => 'checkbox',
    'per_agent'   => 1,
  },

  { 'key'         => 'selfservice_server-cache_module',
    'section'     => 'self-service',
    'description' => 'Module used to store self-service session information.  All modules handle any number of self-service servers.  Cache::SharedMemoryCache is appropriate for a single database / single Freeside server.  Cache::FileCache is useful for multiple databases on a single server, or when IPC::ShareLite is not available (i.e. FreeBSD).', #  _Database stores session information in the database and is appropriate for multiple Freeside servers, but may be slower.',
    'type'        => 'select',
    'select_enum' => [ 'Cache::SharedMemoryCache', 'Cache::FileCache', ], # '_Database' ],
  },

  {
    'key'         => 'hylafax',
    'section'     => 'deprecated',
    'description' => 'Options for a HylaFAX server to enable the FAX invoice destination.  They should be in the form of a space separated list of arguments to the Fax::Hylafax::Client::sendfax subroutine.  You probably shouldn\'t override things like \'docfile\'.  *Note* Only supported when using typeset invoices (see the invoice_latex configuration option).',
    'type'        => [qw( checkbox textarea )],
  },

  {
    'key'         => 'cust_bill-ftpformat',
    'section'     => 'print_services',
    'description' => 'Enable FTP of raw invoice data - format.',
    'type'        => 'select',
    'options'     => [ spool_formats() ],
  },

  {
    'key'         => 'cust_bill-ftpserver',
    'section'     => 'print_services',
    'description' => 'Enable FTP of raw invoice data - server.',
    'type'        => 'text',
  },

  {
    'key'         => 'cust_bill-ftpusername',
    'section'     => 'print_services',
    'description' => 'Enable FTP of raw invoice data - server.',
    'type'        => 'text',
  },

  {
    'key'         => 'cust_bill-ftppassword',
    'section'     => 'print_services',
    'description' => 'Enable FTP of raw invoice data - server.',
    'type'        => 'text',
  },

  {
    'key'         => 'cust_bill-ftpdir',
    'section'     => 'print_services',
    'description' => 'Enable FTP of raw invoice data - server.',
    'type'        => 'text',
  },

  {
    'key'         => 'cust_bill-spoolformat',
    'section'     => 'print_services',
    'description' => 'Enable spooling of raw invoice data - format.',
    'type'        => 'select',
    'options'     => [ spool_formats() ],
  },

  {
    'key'         => 'cust_bill-spoolagent',
    'section'     => 'print_services',
    'description' => 'Enable per-agent spooling of raw invoice data.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'bridgestone-batch_counter',
    'section'     => 'print_services',
    'description' => 'Batch counter for spool files.  Increments every time a spool file is uploaded.',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'bridgestone-prefix',
    'section'     => 'print_services',
    'description' => 'Agent identifier for uploading to BABT printing service.',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'bridgestone-confirm_template',
    'section'     => 'print_services',
    'description' => 'Confirmation email template for uploading to BABT service.  Text::Template format, with variables "$zipfile" (name of the zipped file), "$seq" (sequence number), "$prefix" (user ID string), and "$rows" (number of records in the file).  Should include Subject: and To: headers, separated from the rest of the message by a blank line.',
    # this could use a true message template, but it's hard to see how that
    # would make the world a better place
    'type'        => 'textarea',
    'per_agent'   => 1,
  },

  {
    'key'         => 'ics-confirm_template',
    'section'     => 'print_services',
    'description' => 'Confirmation email template for uploading to ICS invoice printing.  Text::Template format, with variables "%count" and "%sum".',
    'type'        => 'textarea',
    'per_agent'   => 1,
  },

  {
    'key'         => 'svc_acct-usage_suspend',
    'section'     => 'suspension',
    'description' => 'Suspends the package an account belongs to when svc_acct.seconds or a bytecount is decremented to 0 or below (accounts with an empty seconds and up|down|totalbytes value are ignored).  Typically used in conjunction with prepaid packages and freeside-sqlradius-radacctd.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'svc_acct-usage_unsuspend',
    'section'     => 'suspension',
    'description' => 'Unuspends the package an account belongs to when svc_acct.seconds or a bytecount is incremented from 0 or below to a positive value (accounts with an empty seconds and up|down|totalbytes value are ignored).  Typically used in conjunction with prepaid packages and freeside-sqlradius-radacctd.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'svc_acct-usage_threshold',
    'section'     => 'notification',
    'description' => 'The threshold (expressed as percentage) of acct.seconds or acct.up|down|totalbytes at which a warning message is sent to a service holder.  Typically used in conjunction with prepaid packages and freeside-sqlradius-radacctd.',
    'type'        => 'text',
  },

  {
    'key'         => 'overlimit_groups',
    'section'     => 'suspension',
    'description' => 'RADIUS group(s) to assign to svc_acct which has exceeded its bandwidth or time limit.',
    'type'        => 'select-sub',
    'per_agent'   => 1,
    'multiple'    => 1,
    'options_sub' => sub { require FS::Record;
                           require FS::radius_group;
			   map { $_->groupnum => $_->long_description }
                               FS::Record::qsearch('radius_group', {} );
			 },
    'option_sub'  => sub { require FS::Record;
                           require FS::radius_group;
			   my $radius_group = FS::Record::qsearchs(
			     'radius_group', { 'groupnum' => shift }
			   );
               $radius_group ? $radius_group->long_description : '';
			 },
  },

  {
    'key'         => 'cust-fields',
    'section'     => 'reporting',
    'description' => 'Which customer fields to display on reports by default',
    'type'        => 'select',
    'select_hash' => [ FS::ConfDefaults->cust_fields_avail() ],
  },

  {
    'key'         => 'cust_location-label_prefix',
    'section'     => 'addresses',
    'description' => 'Optional "site ID" to show in the location label',
    'type'        => 'select',
    'select_hash' => [ '' => '',
                       'CoStAg'    => 'CoStAgXXXXX (country, state, agent name, locationnum)',
                       '_location' => 'Manually defined per location',
                      ],
  },

  {
    'key'         => 'cust_pkg-display_times',
    'section'     => 'packages',
    'description' => 'Display full timestamps (not just dates) for customer packages.  Useful if you are doing real-time things like hourly prepaid.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_pkg-group_by_location',
    'section'     => 'packages',
    'description' => "Group packages by location.",
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_pkg-large_pkg_size',
    'section'     => 'scalability',
    'description' => "In customer view, summarize packages with more than this many services.  Set to zero to never summarize packages.",
    'type'        => 'text',
  },

  {
    'key'         => 'cust_pkg-hide_discontinued-part_svc',
    'section'     => 'packages',
    'description' => "In customer view, hide provisioned services which are no longer available in the package definition.  Not normally used except for very specific situations as it hides still-provisioned services.",
    'type'        => 'checkbox',
  },

  {
    'key'         => 'part_pkg-show_fcc_options',
    'section'     => 'packages',
    'description' => "Show fields on package definitions for FCC Form 477 classification",
    'type'        => 'checkbox',
  },

  {
    'key'         => 'svc_acct-edit_uid',
    'section'     => 'shell',
    'description' => 'Allow UID editing.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'svc_acct-edit_gid',
    'section'     => 'shell',
    'description' => 'Allow GID editing.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'svc_acct-no_edit_username',
    'section'     => 'shell',
    'description' => 'Disallow username editing.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'zone-underscore',
    'section'     => 'BIND',
    'description' => 'Allow underscores in zone names.  As underscores are illegal characters in zone names, this option is not recommended.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'echeck-country',
    'section'     => 'e-checks',
    'description' => 'Format electronic check information for the specified country.',
    'type'        => 'select',
    'select_hash' => [ 'US' => 'United States',
                       'CA' => 'Canada (enables branch)',
                       'XX' => 'Other',
                     ],
  },

  {
    'key'         => 'voip-cust_accountcode_cdr',
    'section'     => 'telephony_invoicing',
    'description' => 'Enable the per-customer option for CDR breakdown by accountcode.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'voip-cust_cdr_squelch',
    'section'     => 'telephony_invoicing',
    'description' => 'Enable the per-customer option for not printing CDR on invoices.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'voip-cdr_email',
    'section'     => 'telephony_invoicing',
    'description' => 'Include the call details inline on emailed invoices (and HTML invoices viewed in the backend), even if the customer is configured for not printing them on the invoices.  Useful for including these details in electronic delivery but omitting them when printing.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'voip-cdr_email_attach',
    'section'     => 'telephony_invoicing',
    'description' => 'Enable the per-customer option for including CDR information as an attachment on emailed invoices.',
    'type'        => 'select',
    'select_hash' => [ ''    => 'Disabled',
                       'csv' => 'Text (CSV) attachment',
                       'zip' => 'Zip attachment',
                     ],
  },

  {
    'key'         => 'cgp_rule-domain_templates',
    'section'     => 'services',
    'description' => 'Communigate Pro rule templates for domains, one per line, "svcnum Name"',
    'type'        => 'textarea',
  },

  {
    'key'         => 'svc_forward-no_srcsvc',
    'section'     => 'services',
    'description' => "Don't allow forwards from existing accounts, only arbitrary addresses.  Useful when exporting to systems such as Communigate Pro which treat forwards in this fashion.",
    'type'        => 'checkbox',
  },

  {
    'key'         => 'svc_forward-arbitrary_dst',
    'section'     => 'services',
    'description' => "Allow forwards to point to arbitrary strings that don't necessarily look like email addresses.  Only used when using forwards for weird, non-email things.",
    'type'        => 'checkbox',
  },

  {
    'key'         => 'tax-ship_address',
    'section'     => 'taxation',
    'description' => 'By default, tax calculations are done based on the billing address.  Enable this switch to calculate tax based on the shipping address instead.',
    'type'        => 'checkbox',
  }
,
  {
    'key'         => 'tax-pkg_address',
    'section'     => 'taxation',
    'description' => 'By default, tax calculations are done based on the billing address.  Enable this switch to calculate tax based on the package address instead (when present).',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'invoice-ship_address',
    'section'     => 'invoicing',
    'description' => 'Include the shipping address on invoices.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'invoice-all_pkg_addresses',
    'section'     => 'invoicing',
    'description' => 'Show all package addresses on invoices, even the default.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'invoice-unitprice',
    'section'     => 'invoicing',
    'description' => 'Enable unit pricing on invoices and quantities on packages.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'invoice-smallernotes',
    'section'     => 'invoicing',
    'description' => 'Display the notes section in a smaller font on invoices.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'invoice-smallerfooter',
    'section'     => 'invoicing',
    'description' => 'Display footers in a smaller font on invoices.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'postal_invoice-fee_pkgpart',
    'section'     => 'invoicing',
    'description' => 'This allows selection of a package to insert on invoices for customers with postal invoices selected.',
    'type'        => 'select-part_pkg',
    'per_agent'   => 1,
  },

  {
    'key'         => 'postal_invoice-recurring_only',
    'section'     => 'invoicing',
    'description' => 'The postal invoice fee is omitted on invoices without recurring charges when this is set.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'batch-enable',
    'section'     => 'deprecated', #make sure batch-enable_payby is set for
                                   #everyone before removing
    'description' => 'Enable credit card and/or ACH batching - leave disabled for real-time installations.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'batch-enable_payby',
    'section'     => 'payment_batching',
    'description' => 'Enable batch processing for the specified payment types.',
    'type'        => 'selectmultiple',
    'select_enum' => [qw( CARD CHEK )],
    'validate'    => sub {
                        ## can not create a new invoice and pay it silently with batch processing, only realtime processing.
                        my $conf = new FS::Conf;
                        !$conf->exists('processing-fee_on_separate_invoice') ? '' : 'You can not enable batch processing while processing-fee_on_separate_invoice option is enabled.';
                     },
  },

  {
    'key'         => 'realtime-disable_payby',
    'section'     => 'payments',
    'description' => 'Disable realtime processing for the specified payment types.',
    'type'        => 'selectmultiple',
    'select_enum' => [qw( CARD CHEK )],
  },

  {
    'key'         => 'batch-default_format',
    'section'     => 'payment_batching',
    'description' => 'Default format for batches.',
    'type'        => 'select',
    'select_enum' => [ 'NACHA', 'csv-td_canada_trust-merchant_pc_batch',
                       'csv-chase_canada-E-xactBatch', 'BoM', 'PAP',
                       'paymentech', 'ach-spiritone', 'RBC', 'CIBC',
                    ]
  },

  { 'key'         => 'batch-gateway-CARD',
    'section'     => 'payment_batching',
    'description' => 'Business::BatchPayment gateway for credit card batches.',
    %batch_gateway_options,
  },

  { 'key'         => 'batch-gateway-CHEK',
    'section'     => 'payment_batching', 
    'description' => 'Business::BatchPayment gateway for check batches.',
    %batch_gateway_options,
  },

  {
    'key'         => 'batch-reconsider',
    'section'     => 'payment_batching',
    'description' => 'Allow imported batch results to change the status of payments from previous imports.  Enable this only if your gateway is known to send both positive and negative results for the same batch.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'batch-auto_resolve_days',
    'section'     => 'payment_batching',
    'description' => 'Automatically resolve payment batches this many days after they were first downloaded.',
    'type'        => 'text',
  },

  {
    'key'         => 'batch-auto_resolve_status',
    'section'     => 'payment_batching',
    'description' => 'When automatically resolving payment batches, take this action for payments of unknown status.',
    'type'        => 'select',
    'select_enum' => [ 'approve', 'decline' ],
  },

  # replaces batch-errors_to (sent email on error)
  {
    'key'         => 'batch-errors_not_fatal',
    'section'     => 'payment_batching',
    'description' => 'If checked, when importing batches from a gateway, item errors will be recorded in the system log without aborting processing.  If unchecked, batch processing will fail on error.',
    'type'        => 'checkbox',
  },

  #lists could be auto-generated from pay_batch info
  {
    'key'         => 'batch-fixed_format-CARD',
    'section'     => 'payment_batching',
    'description' => 'Fixed (unchangeable) format for credit card batches.',
    'type'        => 'select',
    'select_enum' => [ 'csv-td_canada_trust-merchant_pc_batch', 'BoM', 'PAP' ,
                       'csv-chase_canada-E-xactBatch', 'paymentech' ]
  },

  {
    'key'         => 'batch-fixed_format-CHEK',
    'section'     => 'payment_batching',
    'description' => 'Fixed (unchangeable) format for electronic check batches.',
    'type'        => 'select',
    'select_enum' => [ 'NACHA', 'csv-td_canada_trust-merchant_pc_batch', 'BoM',
                       'PAP', 'paymentech', 'ach-spiritone', 'RBC',
                       'td_eft1464', 'eft_canada', 'CIBC'
                     ]
  },

  {
    'key'         => 'batch-increment_expiration',
    'section'     => 'payment_batching',
    'description' => 'Increment expiration date years in batches until cards are current.  Make sure this is acceptable to your batching provider before enabling.',
    'type'        => 'checkbox'
  },

  {
    'key'         => 'batchconfig-BoM',
    'section'     => 'payment_batching',
    'description' => 'Configuration for Bank of Montreal batching, seven lines: 1. Origin ID, 2. Datacenter, 3. Typecode, 4. Short name, 5. Long name, 6. Bank, 7. Bank account',
    'type'        => 'textarea',
  },

{
    'key'         => 'batchconfig-CIBC',
    'section'     => 'payment_batching',
    'description' => 'Configuration for Canadian Imperial Bank of Commerce, six lines: 1. Origin ID, 2. Datacenter, 3. Typecode, 4. Short name, 5. Bank, 6. Bank account',
    'type'        => 'textarea',
  },

  {
    'key'         => 'batchconfig-PAP',
    'section'     => 'payment_batching',
    'description' => 'Configuration for PAP batching, seven lines: 1. Origin ID, 2. Datacenter, 3. Typecode, 4. Short name, 5. Long name, 6. Bank, 7. Bank account',
    'type'        => 'textarea',
  },

  {
    'key'         => 'batchconfig-csv-chase_canada-E-xactBatch',
    'section'     => 'payment_batching',
    'description' => 'Gateway ID for Chase Canada E-xact batching',
    'type'        => 'text',
  },

  {
    'key'         => 'batchconfig-paymentech',
    'section'     => 'payment_batching',
    'description' => 'Configuration for Chase Paymentech batching, six lines: 1. BIN, 2. Terminal ID, 3. Merchant ID, 4. Username, 5. Password (for batch uploads), 6. Flag to send recurring indicator.',
    'type'        => 'textarea',
  },

  {
    'key'         => 'batchconfig-RBC',
    'section'     => 'payment_batching',
    'description' => 'Configuration for Royal Bank of Canada PDS batching, five lines: 1. Client number, 2. Short name, 3. Long name, 4. Transaction code 5. (optional) set to TEST to turn on test mode.',
    'type'        => 'textarea',
  },

  {
    'key'         => 'batchconfig-RBC-login',
    'section'     => 'payment_batching',
    'description' => 'FTPS login for uploading Royal Bank of Canada batches. Two lines: 1. username, 2. password. If not supplied, batches can still be created but not automatically uploaded.',
    'type'        => 'textarea',
  },

  {
    'key'         => 'batchconfig-td_eft1464',
    'section'     => 'payment_batching',
    'description' => 'Configuration for TD Bank EFT1464 batching, seven lines: 1. Originator ID, 2. Datacenter Code, 3. Short name, 4. Long name, 5. Returned payment branch number, 6. Returned payment account, 7. Transaction code.',
    'type'        => 'textarea',
  },

  {
    'key'         => 'batchconfig-eft_canada',
    'section'     => 'payment_batching',
    'description' => 'Configuration for EFT Canada batching, five lines: 1. SFTP username, 2. SFTP password, 3. Business transaction code, 4. Personal transaction code, 5. Number of days to delay process date.  If you are using separate per-agent batches (batch-spoolagent), you must set this option separately for each agent, as the global setting will be ignored.',
    'type'        => 'textarea',
    'per_agent'   => 1,
  },

  {
    'key'         => 'batchconfig-nacha-destination',
    'section'     => 'payment_batching',
    'description' => 'Configuration for NACHA batching, Destination (9 digit transit routing number).',
    'type'        => 'text',
  },

  {
    'key'         => 'batchconfig-nacha-destination_name',
    'section'     => 'payment_batching',
    'description' => 'Configuration for NACHA batching, Destination (Bank Name, up to 23 characters).',
    'type'        => 'text',
  },

  {
    'key'         => 'batchconfig-nacha-origin',
    'section'     => 'payment_batching',
    'description' => 'Configuration for NACHA batching, Origin (your 10-digit company number, IRS tax ID recommended).',
    'type'        => 'text',
  },

  {
    'key'         => 'batchconfig-nacha-origin_name',
    'section'     => 'payment_batching',
    'description' => 'Configuration for NACHA batching, Origin name (defaults to company name, but sometimes bank name is needed instead.)',
    'type'        => 'text',
  },

  {
    'key'         => 'batch-manual_approval',
    'section'     => 'payment_batching',
    'description' => 'Allow manual batch closure, which will approve all payments that do not yet have a status.  This is not advised unless needed for specific payment processors that provide a report of rejected rather than approved payments.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'batch-spoolagent',
    'section'     => 'payment_batching',
    'description' => 'Store payment batches per-agent.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'payment_history-years',
    'section'     => 'UI',
    'description' => 'Number of years of payment history to show by default.  Currently defaults to 2.',
    'type'        => 'text',
  },

  {
    'key'         => 'change_history-years',
    'section'     => 'UI',
    'description' => 'Number of years of change history to show by default.  Currently defaults to 0.5.',
    'type'        => 'text',
  },

  {
    'key'         => 'cust_main-packages-years',
    'section'     => 'packages',
    'description' => 'Number of years to show old (cancelled and one-time charge) packages by default.  Currently defaults to 2.',
    'type'        => 'text',
  },

  {
    'key'         => 'cust_main-use_comments',
    'section'     => 'deprecated',
    'description' => 'Display free form comments on the customer edit screen.  Useful as a scratch pad.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_main-disable_notes',
    'section'     => 'customer_fields',
    'description' => 'Disable new style customer notes - timestamped and user identified customer notes.  Useful in tracking who did what.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_main_note-display_times',
    'section'     => 'customer_fields',
    'description' => 'Display full timestamps (not just dates) for customer notes.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_main_note-require_class',
    'section'     => 'customer_fields',
    'description' => 'Require customer note classes for customer notes',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_main-ticket_statuses',
    'section'     => 'ticketing',
    'description' => 'Show tickets with these statuses on the customer view page.',
    'type'        => 'selectmultiple',
    'select_enum' => [qw( new open stalled resolved rejected deleted )],
  },

  {
    'key'         => 'cust_main-max_tickets',
    'section'     => 'ticketing',
    'description' => 'Maximum number of tickets to show on the customer view page.',
    'type'        => 'text',
  },

  {
    'key'         => 'cust_main-enable_birthdate',
    'section'     => 'customer_fields',
    'description' => 'Enable tracking of a birth date with each customer record',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_main-enable_spouse',
    'section'     => 'customer_fields',
    'description' => 'Enable tracking of a spouse\'s name and date of birth with each customer record',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_main-enable_anniversary_date',
    'section'     => 'customer_fields',
    'description' => 'Enable tracking of an anniversary date with each customer record',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_main-edit_calling_list_exempt',
    'section'     => 'customer_fields',
    'description' => 'Display the "calling_list_exempt" checkbox on customer edit.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'support-key',
    'section'     => 'important',
    'description' => 'A support key enables access to <A HREF="http://freeside.biz/freeside/services.html#support">commercial services</A> delivered over the network, such as address normalization and invoice printing.',
    'type'        => 'text',
  },

  {
    'key'         => 'freesideinc-webservice-svcpart',
    'section'     => 'development',
    'description' => 'Do not set this.',
    'type'        => 'text',
  },

  {
    'key'         => 'card-types',
    'section'     => 'credit_cards',
    'description' => 'Select one or more card types to enable only those card types.  If no card types are selected, all card types are available.',
    'type'        => 'selectmultiple',
    'select_enum' => \@card_types,
  },

  {
    'key'         => 'disable-fuzzy',
    'section'     => 'scalability',
    'description' => 'Disable fuzzy searching.  Speeds up searching for large sites, but only shows exact matches.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'fuzzy-fuzziness',
    'section'     => 'scalability',
    'description' => 'Set the "fuzziness" of fuzzy searching (see the String::Approx manpage for details).  Defaults to 10%',
    'type'        => 'text',
  },

  { 'key'         => 'pkg_referral',
    'section'     => 'packages',
    'description' => 'Enable package-specific advertising sources.',
    'type'        => 'checkbox',
  },

  { 'key'         => 'pkg_referral-multiple',
    'section'     => 'packages',
    'description' => 'In addition, allow multiple advertising sources to be associated with a single package.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'dashboard-install_welcome',
    'section'     => 'UI',
    'description' => 'New install welcome screen.',
    'type'        => 'select',
    'select_enum' => [ '', 'ITSP_fsinc_hosted', ],
  },

  {
    'key'         => 'dashboard-topnotes',
    'section'     => 'UI',
    'description' => 'Note to display on the top of the front page',
    'type'        => 'textarea',
  },

  {
    'key'         => 'dashboard-toplist',
    'section'     => 'UI',
    'description' => 'List of items to display on the top of the front page',
    'type'        => 'textarea',
  },

  {
    'key'         => 'impending_recur_msgnum',
    'section'     => 'notification',
    'description' => 'Template to use for alerts about first-time recurring billing.',
    %msg_template_options,
  },

  {
    'key'         => 'logo.png',
    'section'     => 'important',  #'invoicing' ?
    'description' => 'Company logo for HTML invoices and the backoffice interface, in PNG format.  Suggested size somewhere near 92x62.',
    'type'        => 'image',
    'per_agent'   => 1, #XXX just view/logo.cgi, which is for the global
                        #old-style editor anyway...?
    'per_locale'  => 1,
  },

  {
    'key'         => 'logo.eps',
    'section'     => 'printing',
    'description' => 'Company logo for printed and PDF invoices and quotations, in EPS format.',
    'type'        => 'image',
    'per_agent'   => 1, #XXX as above, kinda
    'per_locale'  => 1,
  },

  {
    'key'         => 'selfservice-ignore_quantity',
    'section'     => 'self-service',
    'description' => 'Ignores service quantity restrictions in self-service context.  Strongly not recommended - just set your quantities correctly in the first place.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'selfservice-session_timeout',
    'section'     => 'self-service',
    'description' => 'Self-service session timeout.  Defaults to 1 hour.',
    'type'        => 'select',
    'select_enum' => [ '1 hour', '2 hours', '4 hours', '8 hours', '1 day', '1 week', ],
  },

  # 3.x-only options for a more tolerant password policy

#  {
#    'key'         => 'password-generated-characters',
#    'section'     => 'password',
#    'description' => 'Set of characters to use when generating random passwords. This must contain at least one lowercase letter, uppercase letter, digit, and punctuation mark.',
#    'type'        => 'textarea',
#  },
#
#  {
#    'key'         => 'password-no_reuse',
#    'section'     => 'password',
#    'description' => 'Minimum number of password changes before a password can be reused. By default, passwords can be reused without restriction.',
#    'type'        => 'text',
#  },
#
  {
    'key'         => 'datavolume-forcemegabytes',
    'section'     => 'UI',
    'description' => 'All data volumes are expressed in megabytes',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'datavolume-significantdigits',
    'section'     => 'UI',
    'description' => 'number of significant digits to use to represent data volumes',
    'type'        => 'text',
  },

  {
    'key'         => 'disable_void_after',
    'section'     => 'payments',
    'description' => 'Number of seconds after which freeside won\'t attempt to VOID a payment first when performing a refund.',
    'type'        => 'text',
  },

  {
    'key'         => 'disable_line_item_date_ranges',
    'section'     => 'invoicing',
    'description' => 'Prevent freeside from automatically generating date ranges on invoice line items.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_bill-line_item-date_style',
    'section'     => 'invoicing',
    'description' => 'Display format for line item date ranges on invoice line items.',
    'type'        => 'select',
    'select_hash' => [ ''           => 'STARTDATE-ENDDATE',
                       'month_of'   => 'Month of MONTHNAME',
                       'X_month'    => 'DATE_DESC MONTHNAME',
                     ],
    'per_agent'   => 1,
  },

  {
    'key'         => 'cust_bill-line_item-date_style-non_monthly',
    'section'     => 'invoicing',
    'description' => 'If set, override cust_bill-line_item-date_style for non-monthly charges.',
    'type'        => 'select',
    'select_hash' => [ ''           => 'Default',
                       'start_end'  => 'STARTDATE-ENDDATE',
                       'month_of'   => 'Month of MONTHNAME',
                       'X_month'    => 'DATE_DESC MONTHNAME',
                     ],
    'per_agent'   => 1,
  },

  {
    'key'         => 'cust_bill-line_item-date_description',
    'section'     => 'invoicing',
    'description' => 'Text to display for "DATE_DESC" when using cust_bill-line_item-date_style DATE_DESC MONTHNAME.',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'support_packages',
    'section'     => 'development',
    'description' => 'A list of packages eligible for RT ticket time transfer, one pkgpart per line.', #this should really be a select multiple, or specified in the packages themselves...
    'type'        => 'select-part_pkg',
    'multiple'    => 1,
  },

  {
    'key'         => 'cust_main-require_phone',
    'section'     => 'customer_fields',
    'description' => 'Require daytime or night phone for all customer records.',
    'type'        => 'checkbox',
    'per_agent'   => 1,
  },

  {
    'key'         => 'cust_main-require_invoicing_list_email',
    'section'     => 'customer_fields',
    'description' => 'Email address field is required: require at least one invoicing email address for all customer records.',
    'type'        => 'checkbox',
    'per_agent'   => 1,
  },

  {
    'key'         => 'cust_main-require_classnum',
    'section'     => 'customer_fields',
    'description' => 'Customer class is required: require customer class for all customer records.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_main-check_unique',
    'section'     => 'customer_fields',
    'description' => 'Warn before creating a customer record where these fields duplicate another customer.',
    'type'        => 'select',
    'multiple'    => 1,
    'select_hash' => [ 
      'address' => 'Billing or service address',
    ],
  },

  {
    'key'         => 'svc_acct-display_paid_time_remaining',
    'section'     => 'services',
    'description' => 'Show paid time remaining in addition to time remaining.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cancel_credit_type',
    'section'     => 'cancellation',
    'description' => 'The group to use for new, automatically generated credit reasons resulting from cancellation.',
    reason_type_options('R'),
  },

  {
    'key'         => 'suspend_credit_type',
    'section'     => 'suspension',
    'description' => 'The group to use for new, automatically generated credit reasons resulting from package suspension.',
    reason_type_options('R'),
  },

  {
    'key'         => 'prepayment_discounts-credit_type',
    'section'     => 'billing',
    'description' => 'Enables the offering of prepayment discounts and establishes the credit reason type.',
    reason_type_options('R'),
  },

  {
    'key'         => 'cust_main-agent_custid-format',
    'section'     => 'customer_number',
    'description' => 'Enables searching of various formatted values in cust_main.agent_custid',
    'type'        => 'select',
    'select_hash' => [
                       ''       => 'Numeric only',
                       '\d{7}'  => 'Numeric only, exactly 7 digits',
                       'ww?d+'  => 'Numeric with one or two letter prefix',
                       'd+-w'   => 'Numeric with a dash and one letter suffix',
                     ],
  },

  {
    'key'         => 'card_masking_method',
    'section'     => 'credit_cards',
    'description' => 'Digits to display when masking credit cards.  Note that the first six digits are necessary to canonically identify the credit card type (Visa/MC, Amex, Discover, Maestro, etc.) in all cases.  The first four digits can identify the most common credit card types in most cases (Visa/MC, Amex, and Discover).  The first two digits can distinguish between Visa/MC and Amex.  Note: You should manually remove stored paymasks if you change this value on an existing database, to avoid problems using stored cards.',
    'type'        => 'select',
    'select_hash' => [
                       ''            => '123456xxxxxx1234',
                       'first6last2' => '123456xxxxxxxx12',
                       'first4last4' => '1234xxxxxxxx1234',
                       'first4last2' => '1234xxxxxxxxxx12',
                       'first2last4' => '12xxxxxxxxxx1234',
                       'first2last2' => '12xxxxxxxxxxxx12',
                       'first0last4' => 'xxxxxxxxxxxx1234',
                       'first0last2' => 'xxxxxxxxxxxxxx12',
                     ],
  },

  {
    'key'         => 'disable_previous_balance',
    'section'     => 'invoice_balances',
    'description' => 'Show new charges only; do not list previous invoices, payments, or credits on the invoice.',
    'type'        => 'checkbox',
    'per_agent'   => 1,
  },

  {
    'key'         => 'previous_balance-exclude_from_total',
    'section'     => 'invoice_balances',
    'description' => 'Show separate totals for previous invoice balance and new charges. Only meaningful when invoice_sections is false.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'previous_balance-text',
    'section'     => 'invoice_balances',
    'description' => 'Text for the label of the total previous balance, when it is shown separately. Defaults to "Previous Balance".',
    'type'        => 'text',
    'per_locale'  => 1,
  },

  {
    'key'         => 'previous_balance-text-total_new_charges',
    'section'     => 'invoice_balances',
    'description' => 'Text for the label of the total of new charges, when it is shown separately. If invoice_show_prior_due_date is enabled, the due date of current charges will be appended. Defaults to "Total New Charges".',
    'type'        => 'text',
    'per_locale'  => 1,
  },

  {
    'key'         => 'previous_balance-section',
    'section'     => 'invoice_balances',
    'description' => 'Show previous invoice balances in a separate invoice section.  Does not require invoice_sections to be enabled.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'previous_balance-summary_only',
    'section'     => 'invoice_balances',
    'description' => 'Only show a single line summarizing the total previous balance rather than one line per invoice.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'previous_balance-show_credit',
    'section'     => 'invoice_balances',
    'description' => 'Show the customer\'s credit balance on invoices when applicable.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'previous_balance-show_on_statements',
    'section'     => 'invoice_balances',
    'description' => 'Show previous invoices on statements, without itemized charges.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'previous_balance-payments_since',
    'section'     => 'invoice_balances',
    'description' => 'Instead of showing payments (and credits) applied to the invoice, show those received since the previous invoice date.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'previous_invoice_history',
    'section'     => 'invoice_balances',
    'description' => 'Show a month-by-month history of the customer\'s '.
                     'billing amounts.  This requires template '.
                     'modification and is currently not supported on the '.
                     'stock template.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'balance_due_below_line',
    'section'     => 'invoice_balances',
    'description' => 'Place the balance due message below a line.  Only meaningful when when invoice_sections is false.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'always_show_tax',
    'section'     => 'taxation',
    'description' => 'Show a line for tax on the invoice even when the tax is zero.  Optionally provide text for the tax name to show.',
    'type'        => [ qw(checkbox text) ],
  },

  {
    'key'         => 'address_standardize_method',
    'section'     => 'addresses', #???
    'description' => 'Method for standardizing customer addresses.',
    'type'        => 'select',
    'select_hash' => [ '' => '', 
                       'uscensus' => 'U.S. Census Bureau',
                       'usps'     => 'U.S. Postal Service',
                       'melissa'  => 'Melissa WebSmart',
                       'freeside' => 'Freeside web service (support contract required)',
                     ],
  },

  {
    'key'         => 'usps_webtools-userid',
    'section'     => 'addresses',
    'description' => 'Production UserID for USPS web tools.   Enables USPS address standardization.  See the <a href="http://www.usps.com/webtools/">USPS website</a>, register and agree not to use the tools for batch purposes.',
    'type'        => 'text',
  },

  {
    'key'         => 'usps_webtools-password',
    'section'     => 'addresses',
    'description' => 'Production password for USPS web tools.   Enables USPS address standardization.  See <a href="http://www.usps.com/webtools/">USPS website</a>, register and agree not to use the tools for batch purposes.',
    'type'        => 'text',
  },

  {
    'key'         => 'melissa-userid',
    'section'     => 'addresses', # it's really not...
    'description' => 'User ID for Melissa WebSmart service.  See <a href="http://www.melissadata.com/">the Melissa website</a> for access and pricing.',
    'type'        => 'text',
  },

  {
    'key'         => 'melissa-enable_geocoding',
    'section'     => 'addresses',
    'description' => 'Use the Melissa service for census tract and coordinate lookups.  Enable this only if your subscription includes geocoding access.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_main-auto_standardize_address',
    'section'     => 'addresses',
    'description' => 'When using USPS web tools, automatically standardize the address without asking.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_main-require_censustract',
    'section'     => 'addresses',
    'description' => 'Customer is required to have a census tract.  Useful for FCC form 477 reports. See also: cust_main-auto_standardize_address',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_main-no_city_in_address',
    'section'     => 'localization',
    'description' => 'Turn off City for billing & shipping addresses',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'census_year',
    'section'     => 'deprecated',
    'description' => 'Deprecated.  Used to control the year used for census lookups.  2020 census data is now the default.  Use the freeside-censustract-update tool if exisitng customers need to be changed.  See the <a href ="#census_legacy">census_legacy</a> configuration option if you need old census data to re-file pre-2022 FCC 477 reports.',
    'type'        => 'select',
    'select_enum' => [ qw( 2017 2016 2015 ) ],
  },

  {
    'key'         => 'census_legacy',
    'section'     => 'addresses',
    'description' => 'Use old census data (and source).  Should only be needed if re-filing pre-2022 FCC 477 reports.',
    'type'        => 'select',
    'select_hash' => [ '' => 'Disabled (2020)',
                       '2015' => '2015',
                       '2016' => '2016',
                       '2017' => '2017',
                     ],
  },

  {
    'key'         => 'tax_district_method',
    'section'     => 'taxation',
    'description' => 'The method to use to look up tax district codes.',
    'type'        => 'select',
    #'select_hash' => [ FS::Misc::Geo::get_district_methods() ],
    #after RT#13763, using FS::Misc::Geo here now causes a dependancy loop :/
    'select_hash' => [
                       ''         => '',
                       'wa_sales' => 'Washington sales tax',
                     ],
  },

  {
    'key'         => 'tax_district_taxname',
    'section'     => 'taxation',
    'description' => 'The tax name to display on the invoice for district sales taxes. Defaults to "Tax".',
    'type'        => 'text',
  },

  {
    'key'         => 'company_latitude',
    'section'     => 'taxation',
    'description' => 'For Avalara taxation, your company latitude (-90 through 90)',
    'type'        => 'text',
  },

  {
    'key'         => 'company_longitude',
    'section'     => 'taxation',
    'description' => 'For Avalara taxation, your company longitude (-180 thru 180)',
    'type'        => 'text',
  },

  #if we can't change it from the default yet, what good is it to the end-user? 
  #{
  #  'key'         => 'geocode_module',
  #  'section'     => 'addresses',
  #  'description' => 'Module to geocode (retrieve a latitude and longitude for) addresses',
  #  'type'        => 'select',
  #  'select_enum' => [ 'Geo::Coder::Googlev3' ],
  #},

  {
    'key'         => 'geocode-require_nw_coordinates',
    'section'     => 'addresses',
    'description' => 'Require latitude and longitude in the North Western quadrant, e.g. for North American co-ordinates, etc.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'disable_acl_changes',
    'section'     => 'development',
    'description' => 'Disable all ACL changes, for demos.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'disable_settings_changes',
    'section'     => 'development',
    'description' => 'Disable all settings changes, for demos, except for the usernames given in the comma-separated list.',
    'type'        => [qw( checkbox text )],
  },

  {
    'key'         => 'cust_main-edit_agent_custid',
    'section'     => 'customer_number',
    'description' => 'Enable editing of the agent_custid field.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_main-default_agent_custid',
    'section'     => 'customer_number',
    'description' => 'Display the agent_custid field when available instead of the custnum field.  Restart Apache after changing.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_main-title-display_custnum',
    'section'     => 'customer_number',
    'description' => 'Add the display_custnum (agent_custid or custnum) to the title on customer view pages.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_bill-default_agent_invid',
    'section'     => 'invoicing',
    'description' => 'Display the agent_invid field when available instead of the invnum field.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_main-auto_agent_custid',
    'section'     => 'customer_number',
    'description' => 'Automatically assign an agent_custid - select format',
    'type'        => 'select',
    'select_hash' => [ '' => 'No',
                       '1YMMXXXXXXXX' => '1YMMXXXXXXXX',
                     ],
  },

  {
    'key'         => 'cust_main-custnum-display_prefix',
    'section'     => 'customer_number',
    'description' => 'Prefix the customer number with this string for display purposes.',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'cust_main-custnum-display_length',
    'section'     => 'customer_number',
    'description' => 'Zero fill the customer number to this many digits for display purposes.  Restart Apache after changing.',
    'type'        => 'text',
  },

  {
    'key'         => 'cust_main-default_areacode',
    'section'     => 'localization',
    'description' => 'Default area code for customers.',
    'type'        => 'text',
  },

  {
    'key'         => 'order_pkg-no_start_date',
    'section'     => 'packages',
    'description' => 'Don\'t set a default start date for new packages.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'part_pkg-delay_start',
    'section'     => 'packages',
    'description' => 'Enabled "delayed start" option for packages.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'part_pkg-delay_cancel-days',
    'section'     => 'cancellation',
    'description' => 'Number of days to suspend when using automatic suspension period before cancel (default is 1)',
    'type'        => 'text',
    'validate'    => sub { (($_[0] =~ /^\d*$/) && (($_[0] eq '') || $_[0]))
                           ? ''
                           : 'Must specify an integer number of days' }
  },

  {
    'key'         => 'mcp_svcpart',
    'section'     => 'development',
    'description' => 'Master Control Program svcpart.  Leave this blank.',
    'type'        => 'text', #select-part_svc
  },

  {
    'key'         => 'cust_bill-max_same_services',
    'section'     => 'invoicing',
    'description' => 'Maximum number of the same service to list individually on invoices before condensing to a single line listing the number of services.  Defaults to 5.',
    'type'        => 'text',
  },

  {
    'key'         => 'cust_bill-consolidate_services',
    'section'     => 'invoicing',
    'description' => 'Consolidate service display into fewer lines on invoices rather than one per service.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'suspend_email_admin',
    'section'     => 'suspension',
    'description' => 'Destination admin email address to enable suspension notices',
    'type'        => 'text',
  },

  {
    'key'         => 'unsuspend_email_admin',
    'section'     => 'suspension',
    'description' => 'Destination admin email address to enable unsuspension notices',
    'type'        => 'text',
  },
  
  {
    'key'         => 'selfservice-head',
    'section'     => 'self-service_skinning',
    'description' => 'HTML for the HEAD section of the self-service interface, typically used for LINK stylesheet tags',
    'type'        => 'textarea', #htmlarea?
    'per_agent'   => 1,
  },


  {
    'key'         => 'selfservice-body_header',
    'section'     => 'self-service_skinning',
    'description' => 'HTML header for the self-service interface',
    'type'        => 'textarea', #htmlarea?
    'per_agent'   => 1,
  },

  {
    'key'         => 'selfservice-body_footer',
    'section'     => 'self-service_skinning',
    'description' => 'HTML footer for the self-service interface',
    'type'        => 'textarea', #htmlarea?
    'per_agent'   => 1,
  },


  {
    'key'         => 'selfservice-body_bgcolor',
    'section'     => 'self-service_skinning',
    'description' => 'HTML background color for the self-service interface, for example, #FFFFFF',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'selfservice-box_bgcolor',
    'section'     => 'self-service_skinning',
    'description' => 'HTML color for self-service interface input boxes, for example, #C0C0C0',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'selfservice-stripe1_bgcolor',
    'section'     => 'self-service_skinning',
    'description' => 'HTML color for self-service interface lists (primary stripe), for example, #FFFFFF',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'selfservice-stripe2_bgcolor',
    'section'     => 'self-service_skinning',
    'description' => 'HTML color for self-service interface lists (alternate stripe), for example, #DDDDDD',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'selfservice-text_color',
    'section'     => 'self-service_skinning',
    'description' => 'HTML text color for the self-service interface, for example, #000000',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'selfservice-link_color',
    'section'     => 'self-service_skinning',
    'description' => 'HTML link color for the self-service interface, for example, #0000FF',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'selfservice-vlink_color',
    'section'     => 'self-service_skinning',
    'description' => 'HTML visited link color for the self-service interface, for example, #FF00FF',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'selfservice-hlink_color',
    'section'     => 'self-service_skinning',
    'description' => 'HTML hover link color for the self-service interface, for example, #808080',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'selfservice-alink_color',
    'section'     => 'self-service_skinning',
    'description' => 'HTML active (clicked) link color for the self-service interface, for example, #808080',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'selfservice-font',
    'section'     => 'self-service_skinning',
    'description' => 'HTML font CSS for the self-service interface, for example, 0.9em/1.5em Arial, Helvetica, Geneva, sans-serif',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'selfservice-no_logo',
    'section'     => 'self-service_skinning',
    'description' => 'Disable the logo in self-service',
    'type'        => 'checkbox',
    'per_agent'   => 1,
  },

  {
    'key'         => 'selfservice-title_color',
    'section'     => 'self-service_skinning',
    'description' => 'HTML color for the self-service title, for example, #000000',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'selfservice-title_align',
    'section'     => 'self-service_skinning',
    'description' => 'HTML alignment for the self-service title, for example, center',
    'type'        => 'text',
    'per_agent'   => 1,
  },
  {
    'key'         => 'selfservice-title_size',
    'section'     => 'self-service_skinning',
    'description' => 'HTML font size for the self-service title, for example, 3',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'selfservice-title_left_image',
    'section'     => 'self-service_skinning',
    'description' => 'Image used for the top of the menu in the self-service interface, in PNG format.',
    'type'        => 'image',
    'per_agent'   => 1,
  },

  {
    'key'         => 'selfservice-title_right_image',
    'section'     => 'self-service_skinning',
    'description' => 'Image used for the top of the menu in the self-service interface, in PNG format.',
    'type'        => 'image',
    'per_agent'   => 1,
  },

  {
    'key'         => 'selfservice-menu_disable',
    'section'     => 'self-service',
    'description' => 'Disable the selected menu entries in the self-service menu',
    'type'        => 'selectmultiple',
    'select_enum' => [ #false laziness w/myaccount_menu.html
                       'Overview',
                       'Purchase',
                       'Purchase additional package',
                       'Recharge my account with a credit card',
                       'Recharge my account with a check',
                       'Recharge my account with a prepaid card',
                       'View my usage',
                       'Create a ticket',
                       'Setup my services',
                       'Change my information',
                       'Change billing address',
                       'Change service address',
                       'Change payment information',
                       'Change packages',
                       'Change password(s)',
                       'Logout',
                     ],
    'per_agent'   => 1,
  },

  {
    'key'         => 'selfservice-menu_skipblanks',
    'section'     => 'self-service',
    'description' => 'Skip blank (spacer) entries in the self-service menu',
    'type'        => 'checkbox',
    'per_agent'   => 1,
  },

  {
    'key'         => 'selfservice-menu_skipheadings',
    'section'     => 'self-service',
    'description' => 'Skip the unclickable heading entries in the self-service menu',
    'type'        => 'checkbox',
    'per_agent'   => 1,
  },

  {
    'key'         => 'selfservice-menu_bgcolor',
    'section'     => 'self-service_skinning',
    'description' => 'HTML color for the self-service menu, for example, #C0C0C0',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'selfservice-menu_fontsize',
    'section'     => 'self-service_skinning',
    'description' => 'HTML font size for the self-service menu, for example, -1',
    'type'        => 'text',
    'per_agent'   => 1,
  },
  {
    'key'         => 'selfservice-menu_nounderline',
    'section'     => 'self-service_skinning',
    'description' => 'Styles menu links in the self-service without underlining.',
    'type'        => 'checkbox',
    'per_agent'   => 1,
  },


  {
    'key'         => 'selfservice-menu_top_image',
    'section'     => 'self-service_skinning',
    'description' => 'Image used for the top of the menu in the self-service interface, in PNG format.',
    'type'        => 'image',
    'per_agent'   => 1,
  },

  {
    'key'         => 'selfservice-menu_body_image',
    'section'     => 'self-service_skinning',
    'description' => 'Repeating image used for the body of the menu in the self-service interface, in PNG format.',
    'type'        => 'image',
    'per_agent'   => 1,
  },

  {
    'key'         => 'selfservice-menu_bottom_image',
    'section'     => 'self-service_skinning',
    'description' => 'Image used for the bottom of the menu in the self-service interface, in PNG format.',
    'type'        => 'image',
    'per_agent'   => 1,
  },
  
  {
    'key'         => 'selfservice-view_usage_nodomain',
    'section'     => 'self-service',
    'description' => 'Show usernames without their domains in "View my usage" in the self-service interface.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'selfservice-login_banner_image',
    'section'     => 'self-service_skinning',
    'description' => 'Banner image shown on the login page, in PNG format.',
    'type'        => 'image',
  },

  {
    'key'         => 'selfservice-login_banner_url',
    'section'     => 'self-service_skinning',
    'description' => 'Link for the login banner.',
    'type'        => 'text',
  },

  {
    'key'         => 'ng_selfservice-menu',
    'section'     => 'self-service',
    'description' => 'Custom menu for the next-generation self-service interface.  Each line is in the format "link Label", for example "main.php Home".  Sub-menu items are listed on subsequent lines.  Blank lines terminate the submenu.', #more docs/examples would be helpful
    'type'        => 'textarea',
  },

  {
    'key'         => 'signup-no_company',
    'section'     => 'signup',
    'description' => "Don't display a field for company name on signup.",
    'type'        => 'checkbox',
  },

  {
    'key'         => 'signup-recommend_email',
    'section'     => 'signup',
    'description' => 'Encourage the entry of an invoicing email address on signup.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'signup-recommend_daytime',
    'section'     => 'signup',
    'description' => 'Encourage the entry of a daytime phone number on signup.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'signup-duplicate_cc-warn_hours',
    'section'     => 'signup',
    'description' => 'Issue a warning if the same credit card is used for multiple signups within this many hours.',
    'type'        => 'text',
  },

  {
    'key'         => 'svc_phone-radius-password',
    'section'     => 'telephony',
    'description' => 'Password when exporting svc_phone records to RADIUS',
    'type'        => 'select',
    'select_hash' => [
      '' => 'Use default from svc_phone-radius-default_password config',
      'countrycode_phonenum' => 'Phone number (with country code)',
    ],
  },

  {
    'key'         => 'svc_phone-radius-default_password',
    'section'     => 'telephony',
    'description' => 'Default password when exporting svc_phone records to RADIUS',
    'type'        => 'text',
  },

  {
    'key'         => 'svc_phone-allow_alpha_phonenum',
    'section'     => 'telephony',
    'description' => 'Allow letters in phone numbers.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'svc_phone-domain',
    'section'     => 'telephony',
    'description' => 'Track an optional domain association with each phone service.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'svc_phone-phone_name-max_length',
    'section'     => 'telephony',
    'description' => 'Maximum length of the phone service "Name" field (svc_phone.phone_name).  Sometimes useful to limit this (to 15?) when exporting as Caller ID data.',
    'type'        => 'text',
  },

  {
    'key'         => 'svc_phone-random_pin',
    'section'     => 'telephony',
    'description' => 'Number of random digits to generate in the "PIN" field, if empty.',
    'type'        => 'text',
  },

  {
    'key'         => 'svc_phone-lnp',
    'section'     => 'telephony',
    'description' => 'Enables Number Portability features for svc_phone',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'svc_phone-bulk_provision_simple',
    'section'     => 'telephony',
    'description' => 'Bulk provision phone numbers with a simple number range instead of from DID vendor orders',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'default_phone_countrycode',
    'section'     => 'telephony',
    'description' => 'Default countrycode',
    'type'        => 'text',
  },

  {
    'key'         => 'cdr-charged_party-field',
    'section'     => 'telephony',
    'description' => 'Set the charged_party field of CDRs to this field.  Restart Apache and Freeside daemons after changing.',
    'type'        => 'select-sub',
    'options_sub' => sub { my $fields = FS::cdr->table_info->{'fields'};
                           map { $_ => $fields->{$_}||$_ }
                           grep { $_ !~ /^(acctid|charged_party)$/ }
                           FS::Schema::dbdef->table('cdr')->columns;
                         },
    'option_sub'  => sub { my $f = shift;
                           FS::cdr->table_info->{'fields'}{$f} || $f;
                         },
  },

  #probably deprecate in favor of cdr-charged_party-field above
  {
    'key'         => 'cdr-charged_party-accountcode',
    'section'     => 'telephony',
    'description' => 'Set the charged_party field of CDRs to the accountcode.  Restart Apache and Freeside daemons after changing.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cdr-charged_party-accountcode-trim_leading_0s',
    'section'     => 'telephony',
    'description' => 'When setting the charged_party field of CDRs to the accountcode, trim any leading zeros.  Restart Apache and Freeside daemons after changing.',
    'type'        => 'checkbox',
  },

#  {
#    'key'         => 'cdr-charged_party-truncate_prefix',
#    'section'     => '',
#    'description' => 'If the charged_party field has this prefix, truncate it to the length in cdr-charged_party-truncate_length.',
#    'type'        => 'text',
#  },
#
#  {
#    'key'         => 'cdr-charged_party-truncate_length',
#    'section'     => '',
#    'description' => 'If the charged_party field has the prefix in cdr-charged_party-truncate_prefix, truncate it to this length.',
#    'type'        => 'text',
#  },

  {
    'key'         => 'cdr-skip_duplicate_rewrite',
    'section'     => 'telephony',
    'description' => 'Use the freeside-cdrrewrited daemon to prevent billing CDRs with a src, dst and calldate identical to an existing CDR',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cdr-skip_duplicate_rewrite-sipcallid',
    'section'     => 'telephony',
    'description' => 'Use the freeside-cdrrewrited daemon to prevent billing CDRs with a sipcallid identical to an existing CDR',
    'type'        => 'checkbox',
  },


  {
    'key'         => 'cdr-charged_party_rewrite',
    'section'     => 'telephony',
    'description' => 'Do charged party rewriting in the freeside-cdrrewrited daemon; useful if CDRs are being dropped off directly in the database and require special charged_party processing such as cdr-charged_party-accountcode or cdr-charged_party-truncate*.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cdr-taqua-da_rewrite',
    'section'     => 'telephony',
    'description' => 'For the Taqua CDR format, a comma-separated list of directory assistance 800 numbers.  Any CDRs with these numbers as "BilledNumber" will be rewritten to the "CallingPartyNumber" (and CallType "12") on import.',
    'type'        => 'text',
  },

  {
    'key'         => 'cdr-taqua-accountcode_rewrite',
    'section'     => 'telephony',
    'description' => 'For the Taqua CDR format, pull accountcodes from secondary CDRs with matching sessionNumber.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cdr-taqua-callerid_rewrite',
    'section'     => 'telephony',
    'description' => 'For the Taqua CDR format, pull Caller ID blocking information from secondary CDRs.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cdr-asterisk_australia_rewrite',
    'section'     => 'telephony',
    'description' => 'For Asterisk CDRs, assign CDR type numbers based on Australian conventions.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cdr-userfield_dnis_rewrite',
    'section'     => 'telephony',
    'description' => 'If the CDR userfield contains "DNIS=" followed by a sequence of digits, use that as the destination number for the call.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cdr-intl_to_domestic_rewrite',
    'section'     => 'telephony',
    'description' => 'Strip the "011" international prefix from CDR destination numbers if the rest of the number is 7 digits or shorter, and so probably does not contain a country code.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cdr-gsm_tap3-sender',
    'section'     => 'telephony',
    'description' => 'GSM TAP3 Sender network (5 letter code)',
    'type'        => 'text',
  },

  {
    'key'         => 'cust_pkg-show_autosuspend',
    'section'     => 'suspension',
    'description' => 'Show package auto-suspend dates.  Use with caution for now; can slow down customer view for large insallations.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cdr-asterisk_forward_rewrite',
    'section'     => 'telephony',
    'description' => 'Enable special processing for CDRs representing forwarded calls: For CDRs that have a dcontext that starts with "Local/" but does not match dst, set charged_party to dst, parse a new dst from dstchannel, and set amaflags to "2" ("BILL"/"BILLING").',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cdr-max_duration',
    'section'     => 'telephony',
    'description' => 'If set, defines a global maximum billsec/duration for (prefix-based) call rating, in seconds.  Used with questionable/dirty CDR data that may contain bad records with long billsecs/durations.  Restart Apache and Freeside daemons after changing.',
    'type'        => 'text',
  },

  {
    'key'         => 'disable-cust-pkg_class',
    'section'     => 'packages',
    'description' => 'Disable the two-step dropdown for selecting package class and package, and return to the classic single dropdown.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'queued-max_kids',
    'section'     => 'scalability',
    'description' => 'Maximum number of queued processes.  Defaults to 10.',
    'type'        => 'text',
  },

  {
    'key'         => 'queued-sleep_time',
    'section'     => 'telephony',
    'description' => 'Time to sleep between attempts to find new jobs to process in the queue.  Defaults to 10.  Installations doing real-time CDR processing for prepaid may want to set it lower.',
    'type'        => 'text',
  },

  {
    'key'         => 'queue-no_history',
    'section'     => 'scalability',
    'description' => "Don't recreate the h_queue and h_queue_arg tables on upgrades.  This can save disk space for large installs, especially when using prepaid or multi-process billing.  After turning this option on, drop the h_queue and h_queue_arg tables, run freeside-dbdef-create and restart Apache and Freeside.",
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cancelled_cust-noevents',
    'section'     => 'cancellation',
    'description' => "Don't run events for cancelled customers",
    'type'        => 'checkbox',
  },

  {
    'key'         => 'agent-invoice_template',
    'section'     => 'deprecated',
    'description' => 'Enable display/edit of old-style per-agent invoice template selection',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'svc_broadband-manage_link',
    'section'     => 'wireless_broadband',
    'description' => 'URL for svc_broadband "Manage Device" link.  The following substitutions are available: $ip_addr and $mac_addr.',
    'type'        => 'text',
  },

  {
    'key'         => 'svc_broadband-manage_link_text',
    'section'     => 'wireless_broadband',
    'description' => 'Label for "Manage Device" link',
    'type'        => 'text',
  },

  {
    'key'         => 'svc_broadband-manage_link_loc',
    'section'     => 'wireless_broadband',
    'description' => 'Location for "Manage Device" link',
    'type'        => 'select',
    'select_hash' => [
      'bottom' => 'Near Unprovision link',
      'right'  => 'With export-related links',
    ],
  },

  {
    'key'         => 'svc_broadband-manage_link-new_window',
    'section'     => 'wireless_broadband',
    'description' => 'Open the "Manage Device" link in a new window',
    'type'        => 'checkbox',
  },

  #more fine-grained, service def-level control could be useful eventually?
  {
    'key'         => 'svc_broadband-allow_null_ip_addr',
    'section'     => 'wireless_broadband',
    'description' => '',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'svc_hardware-check_mac_addr',
    'section'     => 'services',
    'description' => 'Require the "hardware address" field in hardware services to be a valid MAC address.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'tax-report_groups',
    'section'     => 'taxation',
    'description' => 'List of grouping possibilities for tax names on reports, one per line, "label op value" (op can be = or !=).',
    'type'        => 'textarea',
  },

  {
    'key'         => 'tax-cust_exempt-groups',
    'section'     => 'taxation',
    'description' => 'List of grouping possibilities for tax names, for per-customer exemption purposes, one tax name per line.  For example, "GST" would indicate the ability to exempt customers individually from taxes named "GST" (but not other taxes).',
    'type'        => 'textarea',
  },

  {
    'key'         => 'tax-cust_exempt-groups-num_req',
    'section'     => 'taxation',
    'description' => 'When using tax-cust_exempt-groups, control whether individual tax exemption numbers are required for exemption from different taxes.',
    'type'        => 'select',
    'select_hash' => [ ''            => 'Not required',
                       'residential' => 'Required for residential customers only',
                       'all'         => 'Required for all customers',
                     ],
  },

  {
    'key'         => 'tax-round_per_line_item',
    'section'     => 'taxation',
    'description' => 'Calculate tax and round to the nearest cent for each line item, rather than for the whole invoice.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_main-default_view',
    'section'     => 'UI',
    'description' => 'Default customer view, for users who have not selected a default view in their preferences.',
    'type'        => 'select',
    'select_hash' => [
      #false laziness w/view/cust_main.cgi and pref/pref.html
      'basics'          => 'Basics',
      'notes'           => 'Notes',
      'tickets'         => 'Tickets',
      'packages'        => 'Packages',
      'payment_history' => 'Payment History',
      'change_history'  => 'Change History',
      'jumbo'           => 'Jumbo',
    ],
  },

  {
    'key'         => 'enable_tax_adjustments',
    'section'     => 'taxation',
    'description' => 'Enable the ability to add manual tax adjustments.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'rt-crontool',
    'section'     => 'ticketing',
    'description' => 'Enable the RT CronTool extension.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'pkg-balances',
    'section'     => 'packages',
    'description' => 'Enable per-package balances.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'pkg-addon_classnum',
    'section'     => 'packages',
    'description' => 'Enable the ability to restrict additional package orders based on package class.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_main-edit_signupdate',
    'section'     => 'customer_fields',
    'description' => 'Enable manual editing of the signup date.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'svc_acct-disable_access_number',
    'section'     => 'UI',
    'description' => 'Disable access number selection.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_bill_pay_pkg-manual',
    'section'     => 'UI',
    'description' => 'Allow manual application of payments to line items.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_credit_bill_pkg-manual',
    'section'     => 'UI',
    'description' => 'Allow manual application of credits to line items.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'breakage-days',
    'section'     => 'billing',
    'description' => 'If set to a number of days, after an account goes that long without activity, recognizes any outstanding payments and credits as "breakage" by creating a breakage charge and invoice.',
    'type'        => 'text',
    'per_agent'   => 1,
  },

  {
    'key'         => 'breakage-pkg_class',
    'section'     => 'billing',
    'description' => 'Package class to use for breakage reconciliation.',
    'type'        => 'select-pkg_class',
  },

  {
    'key'         => 'disable_cron_billing',
    'section'     => 'billing',
    'description' => 'Disable billing and collection from being run by freeside-daily and freeside-monthly, while still allowing other actions to run, such as notifications and backup.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'svc_domain-edit_domain',
    'section'     => 'services',
    'description' => 'Enable domain renaming',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'enable_legacy_prepaid_income',
    'section'     => 'reporting',
    'description' => "Enable legacy prepaid income reporting.  Only useful when you have imported pre-Freeside packages with longer-than-monthly duration, and need to do prepaid income reporting on them before they've been invoiced the first time.",
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_main-exports',
    'section'     => 'API',
    'description' => 'Export(s) to call on cust_main insert, modification and deletion.',
    'type'        => 'select-sub',
    'multiple'    => 1,
    'options_sub' => sub {
      require FS::Record;
      require FS::part_export;
      my @part_export =
        map { qsearch( 'part_export', {exporttype => $_ } ) }
          keys %{FS::part_export::export_info('cust_main')};
      map { $_->exportnum => $_->exportname } @part_export;
    },
    'option_sub'  => sub {
      require FS::Record;
      require FS::part_export;
      my $part_export = FS::Record::qsearchs(
        'part_export', { 'exportnum' => shift }
      );
      $part_export
        ? $part_export->exportname
        : '';
    },
  },

  #false laziness w/above options_sub and option_sub
  {
    'key'         => 'cust_location-exports',
    'section'     => 'API',
    'description' => 'Export(s) to call on cust_location insert or modification',
    'type'        => 'select-sub',
    'multiple'    => 1,
    'options_sub' => sub {
      require FS::Record;
      require FS::part_export;
      my @part_export =
        map { qsearch( 'part_export', {exporttype => $_ } ) }
          keys %{FS::part_export::export_info('cust_location')};
      map { $_->exportnum => $_->exportname } @part_export;
    },
    'option_sub'  => sub {
      require FS::Record;
      require FS::part_export;
      my $part_export = FS::Record::qsearchs(
        'part_export', { 'exportnum' => shift }
      );
      $part_export
        ? $part_export->exportname
        : '';
    },
  },

  {
    'key'         => 'cust_tag-location',
    'section'     => 'UI',
    'description' => 'Location where customer tags are displayed.',
    'type'        => 'select',
    'select_enum' => [ 'misc_info', 'top' ],
  },

  {
    'key'         => 'cust_main-custom_link',
    'section'     => 'UI',
    'description' => 'URL to use as source for the "Custom" tab in the View Customer page.  The customer number will be appended, or you can insert "$custnum" to have it inserted elsewhere.  "$agentnum" will be replaced with the agent number, "$agent_custid" with be replaced with the agent customer ID (if any), and "$usernum" will be replaced with the employee number.',
    'type'        => 'textarea',
  },

  {
    'key'         => 'cust_main-custom_content',
    'section'     => 'UI',
    'description' => 'As an alternative to cust_main-custom_link (leave it blank), the contant to display on this customer page, one item per line.  Available iems are: small_custview, birthdate, spouse_birthdate, svc_acct, svc_phone and svc_external.',
    'type'        => 'textarea',
  },

  {
    'key'         => 'cust_main-custom_title',
    'section'     => 'UI',
    'description' => 'Title for the "Custom" tab in the View Customer page.',
    'type'        => 'text',
  },

  {
    'key'         => 'part_pkg-default_suspend_bill',
    'section'     => 'suspension',
    'description' => 'Default the "Continue recurring billing while suspended" flag to on for new package definitions.',
    'type'        => 'checkbox',
  },
  
  {
    'key'         => 'qual-alt_address_format',
    'section'     => 'addresses',
    'description' => 'Enable the alternate address format (location type, number, and kind) for qualifications.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'prospect_main-alt_address_format',
    'section'     => 'UI',
    'description' => 'Enable the alternate address format (location type, number, and kind) for prospects.  Recommended if qual-alt_address_format is set and the main use of propects is for qualifications.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'prospect_main-location_required',
    'section'     => 'UI',
    'description' => 'Require an address for prospects.  Recommended if the main use of propects is for qualifications.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'note-classes',
    'section'     => 'deprecated',
    'description' => 'Use customer note classes (now automatically used if classes are defined)',
    'type'        => 'select',
    'select_hash' => [
                       0 => 'Disabled',
		       1 => 'Enabled',
		       2 => 'Enabled, with tabs',
		     ],
  },

  {
    'key'         => 'svc_acct-cf_privatekey-message',
    'section'     => 'development',
    'description' => 'For internal use: HTML displayed when cf_privatekey field is set.',
    'type'        => 'textarea',
  },

  {
    'key'         => 'menu-prepend_links',
    'section'     => 'UI',
    'description' => 'Links to prepend to the main menu, one per line, with format "URL Link Label (optional ALT popup)".',
    'type'        => 'textarea',
  },

  {
    'key'         => 'cust_main-external_links',
    'section'     => 'UI',
    'description' => 'External links available in customer view, one per line, with format "URL Link Label (optional ALT popup)".  The URL will have custnum appended.',
    'type'        => 'textarea',
  },
  
  {
    'key'         => 'svc_phone-did-summary',
    'section'     => 'telephony',
    'description' => 'Experimental feature to enable DID activity summary on invoices, showing # DIDs activated/deactivated/ported-in/ported-out and total minutes usage, covering period since last invoice.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'svc_acct-usage_seconds',
    'section'     => 'RADIUS',
    'description' => 'Enable calculation of RADIUS usage time for invoices.  You must modify your template to display this information.',
    'type'        => 'checkbox',
  },
  
  {
    'key'         => 'opensips_gwlist',
    'section'     => 'telephony',
    'description' => 'For svc_phone OpenSIPS dr_rules export, gwlist column value, per-agent',
    'type'        => 'text',
    'per_agent'   => 1,
    'agentonly'   => 1,
  },

  {
    'key'         => 'opensips_description',
    'section'     => 'telephony',
    'description' => 'For svc_phone OpenSIPS dr_rules export, description column value, per-agent',
    'type'        => 'text',
    'per_agent'   => 1,
    'agentonly'   => 1,
  },
  
  {
    'key'         => 'opensips_route',
    'section'     => 'telephony',
    'description' => 'For svc_phone OpenSIPS dr_rules export, routeid column value, per-agent',
    'type'        => 'text',
    'per_agent'   => 1,
    'agentonly'   => 1,
  },

  {
    'key'         => 'cust_bill-no_recipients-error',
    'section'     => 'invoice_email',
    'description' => 'For customers with no invoice recipients, throw a job queue error rather than the default behavior of emailing the invoice to the invoice_from address.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_bill-latex_lineitem_maxlength',
    'section'     => 'deprecated',
    'description' => 'With old invoice_latex template, truncate long line items to this number of characters on typeset invoices, to avoid losing things off the right margin.  (With current invoice_latex template, this is handled internally in the template itself instead.)',
    'type'        => 'text',
  },

  {
    'key'         => 'invoice_payment_details',
    'section'     => 'invoicing',
    'description' => 'When displaying payments on an invoice, show the payment method used, including the check or credit card number.  Credit card numbers will be masked.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_main-status_module',
    'section'     => 'UI',
    'description' => 'Which module to use for customer status display.  The "Classic" module (the default) considers accounts with cancelled recurring packages but un-cancelled one-time charges Inactive.  The "Recurring" module considers those customers Cancelled.  Similarly for customers with suspended recurring packages but one-time charges.  Restart Apache after changing.', #other differences?
    'type'        => 'select',
    'select_enum' => [ 'Classic', 'Recurring' ],
  },

  { 
    'key'         => 'username-pound',
    'section'     => 'username',
    'description' => 'Allow the pound character (#) in usernames.',
    'type'        => 'checkbox',
  },

  { 
    'key'         => 'username-exclamation',
    'section'     => 'username',
    'description' => 'Allow the exclamation character (!) in usernames.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'disable_payauto_default',
    'section'     => 'payments',
    'description' => 'Disable the "Charge future payments to this (card|check) automatically" checkbox from defaulting to checked.',
    'type'        => 'checkbox',
  },
  
  {
    'key'         => 'payment-history-report',
    'section'     => 'deprecated',
    'description' => 'Show a link to the raw database payment history report in the Reports menu.  DO NOT ENABLE THIS for modern installations.',
    'type'        => 'checkbox',
  },
  
  {
    'key'         => 'cust-edit-alt-field-order',
    'section'     => 'customer_fields',
    'description' => 'An alternate ordering of fields for the New Customer and Edit Customer screens.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_bill-enable_promised_date',
    'section'     => 'UI',
    'description' => 'Enable display/editing of the "promised payment date" field on invoices.',
    'type'        => 'checkbox',
  },
  
  {
    'key'         => 'available-locales',
    'section'     => 'localization',
    'description' => 'Limit available locales (employee preferences, per-customer locale selection, etc.) to a particular set.',
    'type'        => 'select-sub',
    'multiple'    => 1,
    'options_sub' => sub { 
      map { $_ => FS::Locales->description($_) }
      FS::Locales->locales;
    },
    'option_sub'  => sub { FS::Locales->description(shift) },
  },

  {
    'key'         => 'cust_main-require_locale',
    'section'     => 'localization',
    'description' => 'Require an explicit locale to be chosen for new customers.',
    'type'        => 'checkbox',
  },
  
  {
    'key'         => 'translate-auto-insert',
    'section'     => 'localization',
    'description' => 'Auto-insert untranslated strings for selected non-en_US locales with their default/en_US values.  Do not turn this on unless translating the interface into a new language.  Restart Apache after changing.',
    'type'        => 'select',
    'multiple'    => 1,
    'select_enum' => [ grep { $_ ne 'en_US' } FS::Locales::locales ],
  },

  {
    'key'         => 'svc_acct-tower_sector',
    'section'     => 'services',
    'description' => 'Track tower and sector for svc_acct (account) services.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cdr-prerate',
    'section'     => 'telephony',
    'description' => 'Experimental feature to rate CDRs immediately, rather than waiting until invoice generation time.  Can reduce invoice generation time when processing lots of CDRs.  Currently works with "VoIP/telco CDR rating (standard)" price plans using "Phone numbers (svc_phone.phonenum)" CDR service matching, without any included minutes.  Restart Apache and Freeside daemons after changing.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cdr-prerate-cdrtypenums',
    'section'     => 'telephony',
    'description' => 'When using cdr-prerate to rate CDRs immediately, limit processing to these CDR types.  Restart Apache and Freeside daemons after changing.',
    'type'        => 'select-sub',
    'multiple'    => 1,
    'options_sub' => sub { require FS::Record;
                           require FS::cdr_type;
                           map { $_->cdrtypenum => $_->cdrtypename }
                               FS::Record::qsearch( 'cdr_type', 
			                            {} #{ 'disabled' => '' }
						  );
			 },
    'option_sub'  => sub { require FS::Record;
                           require FS::cdr_type;
                           my $cdr_type = FS::Record::qsearchs(
			     'cdr_type', { 'cdrtypenum'=>shift } );
                           $cdr_type ? $cdr_type->cdrtypename : '';
			 },
  },

  {
    'key'         => 'cdr-minutes_priority',
    'section'     => 'telephony',
    'description' => 'Priority rule for assigning included minutes to CDRs.',
    'type'        => 'select',
    'select_hash' => [
      ''          => 'No specific order',
      'time'      => 'Chronological',
      'rate_high' => 'Highest rate first',
      'rate_low'  => 'Lowest rate first',
    ],
  },

  {
    'key'         => 'cdr-lrn_lookup',
    'section'     => 'telephony',
    'description' => 'Look up LRNs of destination numbers for exact matching to the terminating carrier.  This feature requires a Freeside support contract for paid access to the central NPAC database; see <a href ="#support-key">support-key</a>.  Restart Apache and Freeside daemons after changing.',
    'type'        => 'checkbox',
  },
  
  {
    'key'         => 'brand-agent',
    'section'     => 'UI',
    'description' => 'Brand the backoffice interface (currently Help->About) using the company_name, company_url and logo.png configuration settings of the selected agent.  Typically used when selling or bundling hosted access to the backoffice interface.  NOTE: The AGPL software license has specific requirements for source code availability in this situation.',
    'type'        => 'select-agent',
  },

  {
    'key'         => 'cust_class-tax_exempt',
    'section'     => 'taxation',
    'description' => 'Control the tax exemption flag per customer class rather than per indivual customer.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'selfservice-billing_history-line_items',
    'section'     => 'self-service',
    'description' => 'Return line item billing detail for the self-service billing_history API call.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'selfservice-default_cdr_format',
    'section'     => 'self-service',
    'description' => 'Format for showing outbound CDRs in self-service.  The per-package option overrides this.',
    'type'        => 'select',
    'select_hash' => \@cdr_formats,
  },

  {
    'key'         => 'selfservice-default_inbound_cdr_format',
    'section'     => 'self-service',
    'description' => 'Format for showing inbound CDRs in self-service.  The per-package option overrides this.  Leave blank to avoid showing these CDRs.',
    'type'        => 'select',
    'select_hash' => \@cdr_formats,
  },

  {
    'key'         => 'selfservice-hide_cdr_price',
    'section'     => 'self-service',
    'description' => 'Don\'t show the "Price" column on CDRs in self-service.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'selfservice-enable_payment_without_balance',
    'section'     => 'self-service',
    'description' => 'Allow selfservice customers to make payments even if balance is zero or below (resulting in an unapplied payment and negative balance.)',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'selfservice-ACH_info_readonly',
    'section'     => 'self-service',
    'description' => 'make ACH on self service portal read only',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'selfservice-announcement',
    'section'     => 'self-service',
    'description' => 'HTML announcement to display to all authenticated users on account overview page',
    'type'        => 'textarea',
  },

  {
    'key'         => 'logout-timeout',
    'section'     => 'deprecated',
    'description' => 'Deprecated.  Used to automatically log users out of the backoffice after this many minutes.  Set session timeouts in employee groups instead.',
    'type'       => 'text',
  },
  
  {
    'key'         => 'spreadsheet_format',
    'section'     => 'reporting',
    'description' => 'Default format for spreadsheet download.',
    'type'        => 'select',
    'select_hash' => [
      'XLS' => 'XLS (Excel 97/2000/XP)',
      'XLSX' => 'XLSX (Excel 2007+)',
    ],
  },

  {
    'key'         => 'report-cust_pay-select_time',
    'section'     => 'reporting',
    'description' => 'Enable time selection on payment and refund reports.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'authentication_module',
    'section'     => 'UI',
    'description' => '"Internal" is the default , which authenticates against the internal database.  "Legacy" is similar, but matches passwords against a legacy htpasswd file.',
    'type'        => 'select',
    'select_enum' => [qw( Internal Legacy )],
  },

  {
    'key'         => 'external_auth-access_group-template_user',
    'section'     => 'UI',
    'description' => 'When using an external authentication module, specifies the default access groups for autocreated users, via a template user.',
    'type'        => 'text',
  },

  {
    'key'         => 'allow_invalid_cards',
    'section'     => 'development',
    'description' => 'Accept invalid credit card numbers.  Useful for testing with fictitious customers.  There is no good reason to enable this in production.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'default_credit_limit',
    'section'     => 'billing',
    'description' => 'Default customer credit limit',
    'type'        => 'text',
  },

  {
    'key'         => 'api_shared_secret',
    'section'     => 'API',
    'description' => 'Shared secret for back-office API authentication',
    'type'        => 'text',
  },

  {
    'key'         => 'xmlrpc_api',
    'section'     => 'API',
    'description' => 'Enable the back-office API XML-RPC server (on port 8008).',
    'type'        => 'checkbox',
  },

#  {
#    'key'         => 'jsonrpc_api',
#    'section'     => 'API',
#    'description' => 'Enable the back-office API JSON-RPC server (on port 8081).',
#    'type'        => 'checkbox',
#  },

  {
    'key'         => 'api_credit_reason',
    'section'     => 'API',
    'description' => 'Default reason for back-office API credits',
    'type'        => 'select-sub',
    #false laziness w/api_credit_reason
    'options_sub' => sub { require FS::Record;
                           require FS::reason;
                           my $type = qsearchs('reason_type', 
                             { class => 'R' }) 
                              or return ();
			   map { $_->reasonnum => $_->reason }
                               FS::Record::qsearch('reason', 
                                 { reason_type => $type->typenum } 
                               );
			 },
    'option_sub'  => sub { require FS::Record;
                           require FS::reason;
			   my $reason = FS::Record::qsearchs(
			     'reason', { 'reasonnum' => shift }
			   );
                           $reason ? $reason->reason : '';
			 },
  },

  {
    'key'         => 'part_pkg-term_discounts',
    'section'     => 'packages',
    'description' => 'Enable the term discounts feature.  Recommended to keep turned off unless actually using - not well optimized for large installations.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'prepaid-never_renew',
    'section'     => 'packages',
    'description' => 'Prepaid packages never renew.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'agent-disable_counts',
    'section'     => 'deprecated',
    'description' => 'On the agent browse page, disable the customer and package counts.  Typically used for very large installs when this page takes too long to render.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'config-disable_counts',
    'section'     => 'scalability',
    'description' => 'Disable the customer and package counts on the Agents, Packages, and Services pages. Use for very large installs where these pages take too long to render.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'tollfree-country',
    'section'     => 'telephony',
    'description' => 'Country / region for toll-free recognition.  Restart Apache and Freeside daemons after changing.',
    'type'        => 'select',
    'select_hash' => [ ''   => 'NANPA (US/Canada)',
                       'AU' => 'Australia',
                       'NZ' => 'New Zealand',
                     ],
  },

  {
    'key'         => 'old_fcc_report',
    'section'     => 'deprecated',
    'description' => 'Use the old (pre-2014) FCC Form 477 report format.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'cust_main-default_commercial',
    'section'     => 'customer_fields',
    'description' => 'Default for new customers is commercial rather than residential.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'default_appointment_length',
    'section'     => 'appointments',
    'description' => 'Default appointment length, in minutes (30 minute granularity).',
    'type'        => 'text',
  },

  {
    'key'         => 'selfservice-db_profile',
    'section'     => 'development',
    'description' => 'Enable collection and logging of database profiling information for self-service servers.  This has significant overhead, do not leave enabled in production beyond that necessary to collect profiling data.',
    'type'        => 'checkbox',
  },

  {
    'key'         => 'deposit_slip-bank_name',
    'section'     => 'payments', #XXX payment_deposit_slips
    'description' => 'Bank name to print on check deposit slips',
    'type'        => 'text',
  },

  {
    'key'         => 'deposit_slip-bank_address',
    'section'     => 'payments', #XXX payment_deposit_slips
    'description' => 'Bank address to print on check deposit slips',
    'type'        => 'textarea',
  },

  {
    'key'         => 'deposit_slip-bank_routingnumber',
    'section'     => 'payments', #XXX payment_deposit_slips
    'description' => '9 digit bank routing number to print on check deposit slips',
    'type'        => 'text',
  },

  {
    'key'         => 'deposit_slip-bank_accountnumber',
    'section'     => 'payments', #XXX payment_deposit_slips
    'description' => 'Bank account number to print on check deposit slips',
    'type'        => 'text',
  },


  # for internal use only; test databases should declare this option and
  # everyone else should pretend it doesn't exist
  #{
  #  'key'         => 'no_random_ids',
  #  'section'     => '',
  #  'description' => 'Replace random identifiers in UI code with a static string, for repeatable testing. Don\'t use in production.',
  #  'type'        => 'checkbox',
  #},

);

1;
