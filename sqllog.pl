#!/usr/bin/perl

use strict;
use warnings;
use Fcntl qw/SEEK_SET SEEK_CUR SEEK_END/;
use IO::Handle;

use DBI;
use Henzell::Crawl;
use Henzell::ServerConfig;

do 'game_parser.pl';

my @LOGFIELDS_DECORATED = qw/alpha v cv lv scI name uidI race crace cls char
  xlI sk sklevI title ktyp killer ckiller ikiller kpath kmod kaux ckaux place
  br lvlI ltyp hpI mhpI mmhpI damI strI intI dexI god pietyI penI wizI startD
  endD durI turnI uruneI nruneI tmsg vmsg splat map mapdesc tiles
  game_key/;

my %GAME_TYPE_NAMES = (zot => 'ZotDef',
                       spr => 'Sprint');

my %LOG2SQL = ( name => 'pname',
                char => 'charabbrev',
                str => 'sstr',
                dex => 'sdex',
                int => 'sint',
                map => 'mapname',
                start => 'tstart',
                end => 'tend',
                time => 'ttime',
                offset => 'file_offset');

sub strip_suffix {
  my $val = shift;
  $val =~ s/[ID]$//;
  $val
}

my @LOGFIELDS = map(strip_suffix($_), @LOGFIELDS_DECORATED);

my @MILEFIELDS_DECORATED =
    qw/alpha v cv name race crace cls char xlI sk sklevI title
       place br lvlI ltyp hpI mhpI mmhpI strI intI dexI god
       durI turnI uruneI nruneI timeD verb noun milestone oplace tiles
       game_key/;

my @INSERTFIELDS = ('file', 'src', 'offset', @LOGFIELDS_DECORATED,
                    'rstart', 'rend');

my @MILE_INSERTFIELDS_DECORATED =
  (qw/file src offsetI/, @MILEFIELDS_DECORATED, qw/rstart rtime/);

my @MILEFIELDS = map(strip_suffix($_), @MILEFIELDS_DECORATED);
my @MILE_INSERTFIELDS = @MILE_INSERTFIELDS_DECORATED;

my @SELECTFIELDS = ('id', @INSERTFIELDS);

my @INDEX_COLS = qw/src file game_key v cv sc name race crace cls char xl
ktyp killer ckiller ikiller kpath kmod kaux ckaux place god
start end dur turn urune nrune dam rstart map/;

my %MILE_EXCLUDED_INDEXES = map($_ => 1,
                                qw/alpha str int dex tiles milestone lvl
                                   hp mhp mmhp dur/);

my @MILE_INDEX_COLS = ('src',
                       grep(!$MILE_EXCLUDED_INDEXES{$_}, @MILEFIELDS));

my %MILESTONE_VERB =
(
 unique => 'uniq',
 enter => 'br.enter',
 'branch-finale' => 'br.end'
);

for (@LOGFIELDS, @INDEX_COLS, @SELECTFIELDS) {
  $LOG2SQL{$_} = $_ unless exists $LOG2SQL{$_};
}

my @INDEX_CASES = ( '' );

my $TLOGFILE   = 'logrecord';
my $TMILESTONE = 'milestone';

my $LOGFILE = "allgames.txt";
my $COMMIT_INTERVAL = 15000;

# Dump indexes if we need to add more than around 9000 lines of data.
my $INDEX_DISCARD_THRESHOLD = 300 * 9000;

my $need_indexes = 1;

my $standalone = not caller();

my $DBNAME = $ENV{HENZELL_DBNAME} || 'henzell';
my $DBUSER = 'henzell';
my $DBPASS = 'henzell';

my $dbh;
my $insert_st;
my $update_st;
my $milestone_insert_st;

my %INSERT_STATEMENTS;

sub initialize_sqllog(;$) {
  my $dbname = shift;
  $DBNAME = $dbname if $dbname;
  setup_db();
}

sub setup_db {
  $dbh = open_db();
  $insert_st = prepare_insert_st($dbh, 'logrecord');
  for my $game_type (keys %GAME_TYPE_NAMES) {
    $INSERT_STATEMENTS{$game_type} =
      prepare_insert_st($dbh, "${game_type}_logrecord");
    $INSERT_STATEMENTS{$game_type . "_milestone"} =
      prepare_milestone_insert_st($dbh, "${game_type}_milestone");
  }
  $milestone_insert_st = prepare_milestone_insert_st($dbh, 'milestone');
  $update_st = prepare_update_st($dbh);
}

sub reopen_db {
  cleanup_db();
  setup_db();
}

sub db_url {
  my $dbname = shift;
  "dbi:Pg:dbname=$dbname"
}

sub new_db_handle(;$$$) {
  my ($dbname, $dbuser, $dbpass) = @_;
  $dbname ||= $DBNAME;
  $dbuser ||= $DBUSER;
  $dbpass ||= $DBPASS;
  $DBNAME = $dbname;
  $DBUSER = $dbuser;
  $DBPASS = $dbpass;
  my $url = db_url($dbname);
  print "Connecting to $url as $dbuser\n";
  my $dbh = DBI->connect($url, $dbuser, $dbpass);
  $dbh->{mysql_auto_reconnect} = 1;
  $dbh
}

sub open_db {
  my $dbh = new_db_handle();
  check_indexes($dbh);
  return $dbh;
}

sub check_indexes {
  my $dbh = shift;
  $need_indexes = 1;
}

sub cleanup_db {
  undef $insert_st;
  %INSERT_STATEMENTS = ();
  undef $milestone_insert_st;
  undef $update_st;
  $dbh->disconnect();
}

sub prepare_st {
  my ($dbh, $query) = @_;
  my $st = $dbh->prepare($query) or die "Can't prepare $query: $!\n";
  return $st;
}

sub exec_query_st {
  my $query = shift;
  my $st = prepare_st($dbh, $query);
  $st->execute(@_) or die "Failed to execute query: $query\n";
  $st
}

sub query_one {
  my $st = exec_query_st(@_);
  my $row = $st->fetchrow_arrayref;
  $row && $row->[0]
}

sub query_row {
  my $st = exec_query_st(@_);
  $st->fetchrow_arrayref
}

sub query_all {
  my $st = exec_query_st(@_);
  $st->fetchall_arrayref
}

sub insert_field_name {
  my $fieldname = strip_suffix(shift());
  '"' . ($LOG2SQL{$fieldname} || $fieldname) . '"'
}

sub insert_field_placeholder {
  my $field = shift();
  if ($field =~ /D$/) {
    return "TO_TIMESTAMP(?, 'YYYYMMDDHH24MISS')";
  }
  '?'
}

sub prepare_insert_st {
  my ($dbh, $table) = @_;
  my @allfields = @INSERTFIELDS;
  my $text = "INSERT INTO $table ("
    . join(', ', map(insert_field_name($_), @allfields))
    . ") VALUES ("
    . join(', ', map(insert_field_placeholder($_), @allfields))
    . ")";
  return prepare_st($dbh, $text);
}

sub prepare_milestone_insert_st {
  my ($dbh, $table) = @_;
  my @fields = @MILE_INSERTFIELDS;
  my $text = "INSERT INTO $table ("
    . join(', ', map(insert_field_name($_), @fields))
    . ") VALUES ("
    . join(', ', map(insert_field_placeholder($_), @fields))
    . ")";
  return prepare_st($dbh, $text);
}

sub prepare_update_st {
  my $dbh = shift;
  my $text = <<QUERY;
    UPDATE logrecord
    SET @{ [ join(",", map("\"$LOG2SQL{$_}\" = ?", @LOGFIELDS)) ] }
    WHERE id = ?
QUERY
  return prepare_st($dbh, $text);
}

sub open_handles
{
  my (@files) = @_;
  my @handles;

  for my $file (@files) {
    my $path = $$file{path};
    open my $handle, '<', $path or do {
      warn "Unable to open $path for reading: $!";
      next;
    };

    seek($handle, 0, SEEK_END); # EOF
    push @handles, { file   => $$file{path},
                     fref   => $file,
                     handle => $handle,
                     pos    => tell($handle),
                     server => $$file{src},
                     src    => $$file{src},
                     alpha  => $$file{alpha} };
  }
  return @handles;
}

sub sql_register_files {
  my ($table, @files) = @_;
  $dbh->begin_work;
  $dbh->do("DELETE FROM $table;") or die "Couldn't delete $table records: $!\n";
  my $insert = "INSERT INTO $table VALUES (?);";
  my $st = $dbh->prepare($insert) or die "Can't prepare $insert: $!\n";
  for my $file (@files) {
    execute_st($st, $file) or
      die "Couldn't insert record into $table for $file with $insert: $!\n";
  }
  $dbh->commit;
}

sub sql_register_logfiles {
  sql_register_files("logfiles", @_)
}

sub sql_register_milestones {
  sql_register_files("milestone_files", @_)
}

sub index_cols {
  my @cols = ();
  for my $case (@INDEX_CASES) {
    my @fields = split /\+/, $case;
    for my $field (@INDEX_COLS) {
      next if grep($_ eq $field, @fields);
      push @cols, [ map($LOG2SQL{$_}, @fields, $field) ];
    }
  }
  @cols
}

sub index_name {
  my $cols = shift;
  "ind_" . join("_", @$cols)
}

sub create_indexes {
  my $op = shift;
  print "Creating indexes on logrecord...\n";
  for my $cols (index_cols()) {
    my $name = index_name($cols);
    print "Creating index $name...\n";
    my $ddl = ("CREATE INDEX " . index_name($cols) . " ON logrecord (" .
      join(", ", @$cols) . ");");
    $dbh->do($ddl);
  }
  $need_indexes = 0;


  for my $rcol (@MILE_INDEX_COLS) {
    my $col = $LOG2SQL{$rcol} || $rcol;
    my $name = "mile_index_$col";
    print "Creating index $name...\n";
    my $ddl = "CREATE INDEX $name ON milestone ($col);";
    $dbh->do($ddl);
  }
  reopen_db();
}

sub fixup_db {
  create_indexes() if $need_indexes;
}

sub find_start_offset_in {
  my ($table, $file) = @_;
  my $query = "SELECT MAX(file_offset) FROM $table WHERE file = ?";
  #print "Getting offset for $table with $file: $query\n";
  my $res = query_one($query, $file);
  defined($res)? $res : -1
}

sub truncate_table {
  my $table = shift;
  $dbh->do("DELETE FROM $table") or die "Can't truncate logrecord: $!\n";
}

sub go_to_offset {
  my ($table, $loghandle, $offset) = @_;

  if ($offset > 0) {
    # Seek to the newline.
    seek($loghandle, $offset - 1, SEEK_SET)
      or die "Failed to seek to @{ [ $offset - 1 ] }\n";

    my $nl;
    die "No NL where expected: '$nl'"
      unless read($loghandle, $nl, 1) == 1 && $nl eq "\n";
  }
  else {
    seek($loghandle, 0, SEEK_SET) or die "Failed to seek to start of file\n";
  }

  if ($offset != -1) {
    my $lastline = <$loghandle>;
    $lastline =~ /\n$/
      or die "Last line allegedly read ($lastline) at $offset not newline terminated.";
  }
  return 1;
}

sub filename_gametype($) {
  my $filename = shift;
  return 'zot' if $filename =~ /-zd/ || $filename =~ /-zotdef/;
  return 'spr' if $filename =~ /-spr/;
  return undef;
}

sub logfile_table($) {
  my $filename = shift;
  game_type_table_name(filename_gametype($filename), $TLOGFILE)
}

sub milefile_table($) {
  my $filename = shift;
  game_type_table_name(filename_gametype($filename), $TMILESTONE)
}

sub cat_xlog {
  my ($table, $lf, $fadd, $offset) = @_;

  my $loghandle = $lf->{handle};
  my $lfile = $lf->{file};
  $offset = find_start_offset_in($table, $lfile) unless defined $offset;
  die "No offset into $lfile ($table)" unless defined $offset;

  my $size = -s($lfile);
  my $outstanding_size = $size - $offset;

  eval {
    go_to_offset($table, $loghandle, $offset);
  };
  print "Error seeking in $lfile: $@\n" if $@;
  return if $@;

  my $linestart;
  my $rows = 0;
  $dbh->begin_work;
  while (1) {
    $linestart = tell($loghandle);
    my $line = <$loghandle>;
    last unless $line && $line =~ /\n$/;
    # Skip blank lines.
    next unless $line =~ /\S/;
    ++$rows;
    $fadd->($lf, $linestart, $line);
    if (!($rows % $COMMIT_INTERVAL)) {
      $dbh->commit;
      $dbh->begin_work;
      print "Committed $rows rows from $lfile.\r";
      STDOUT->flush;
    }
  }
  $dbh->commit;
  seek($loghandle, $linestart, SEEK_SET);
  print "Updated db with $rows records from $lfile.\n" if $rows;
  return 1;
}

sub game_type_table_name($$) {
  my ($game_type, $base_tablename) = @_;
  $game_type? "${game_type}_${base_tablename}" : $base_tablename
}

sub game_table_name($$) {
  my ($game, $base_tablename) = @_;
  my $game_type = game_type($game);
  game_type_table_name($game_type, $base_tablename)
}

sub cat_logfile {
  my ($lf, $offset) = @_;
  cat_xlog(logfile_table($$lf{file}), $lf, \&add_logline, $offset)
}

sub game_type($) {
  my $g = shift;
  my ($type) = ($$g{lv} || '') =~ /-(.*)/;
  $type = lc(substr($type, 0, 3)) if $type;
  $type
}

sub game_type_name($) {
  my $type = game_type(shift);
  $type && $GAME_TYPE_NAMES{$type}
}

sub game_is_sprint($) {
  (game_type(shift) || '') eq 'spr'
}

sub game_is_zotdef($) {
  (game_type(shift) || '') eq 'zot'
}

sub cat_stonefile {
  my ($lf, $offset) = @_;
  my $res = cat_xlog(milefile_table($$lf{file}),
                     $lf, \&add_milestone, $offset);
  $res
}

sub logfield_hash {
  my $line = shift;
  chomp $line;
  $line =~ s/::/\n/g;
  my @fields = split(/:/, $line);
  my %fieldh;
  for my $field (@fields) {
    s/\n/:/g for $field;
    my ($key, $val) = $field =~ /^(\w+)=(.*)/;
    next unless defined $key;
    $val =~ tr/_/ /;
    $fieldh{$key} = $val;
  }
  return \%fieldh;
}

sub execute_st {
  my $st = shift;
  while (1) {
    my $res = $st->execute(@_);
    return 1 if $res;
    my $reason = $!;
    # If SQLite wants us to retry, sleep one second and take another stab at it.
    return unless $reason =~ /temporarily unavail/i;
    sleep 1;
  }
}

=head2 fixup_logfields

Cleans up xlog dictionary for milestones and logfile entries.

=cut

sub fixup_logfields {
  my $g = shift;

  my $milestone = exists($g->{milestone});

  ($g->{cv} = $g->{v}) =~ s/^(\d+\.\d+).*/$1/;

  if ($g->{alpha}) {
    $g->{cv} .= "-a";
  }

  if ($g->{tiles}) {
    $g->{tiles} = "y";
  }

  my $game_type = game_type($g);
  if ($game_type) {
    $$g{game_type} = $game_type;
  }

  $g->{place} = Henzell::Crawl::canonical_place_name($g->{place});
  $g->{oplace} = Henzell::Crawl::canonical_place_name($g->{oplace});

  # Milestone may have oplace
  if ($milestone) {
    $g->{oplace} ||= $g->{place}
  }

  unless ($milestone) {
    $g->{vmsg} ||= $g->{tmsg};
    $g->{map} ||= '';
    $g->{mapdesc} ||= '';
    $g->{ikiller} ||= $g->{killer};
    $g->{ckiller} = $g->{killer} || $g->{ktyp} || '';
    for ($g->{ckiller}) {
      s/^an? \w+-headed (hydra.*)$/a $1/;
      s/^the \w+-headed ((?:Lernaean )?hydra.*)$/the $1/;
      s/^.*'s? ghost$/a player ghost/;
      s/^.*'s? illusion$/a player illusion/;
      s/^an? \w+ (draconian.*)/a $1/;
      s/^an? .* \(((?:glowing )?shapeshifter)\)$/a $1/;
      s/^the .* shaped (.*)$/the $1/;

      # If it's an actual kill, merge Pan lords together, polyed uniques with
      # their normal counterparts, and named orcs with their monster type.
      my $kill = $g->{killer};
      if ($kill && $kill =~ /^[A-Z]/) {
        my ($name) = /^([A-Z][\w']*(?: [A-Z][\w']*)*)/;
        if ($kill =~ / the /) {
          my ($mons) = / the (.*)$/;
          # Also takes care of Blork variants.
          if (Henzell::Crawl::crawl_unique($name)) {
            $_ = $name;
          } else {
            # Usually these will all be orcs.
            $mons = 'a ' . $mons;
            $mons =~ s/^a ([aeiou].*)$/an $1/;
            $_ = $mons;
          }
        } else {
          $_ = 'a pandemonium lord' if Henzell::Crawl::possible_pan_lord($name);
        }
      }
    }

    $g->{kmod} = $g->{killer} || '';
    for ($g->{kmod}) {
      if (/spectral (?!warrior)/) {
        $_ = 'a spectral thing';
      }
      elsif (/shapeshifter/) {
        $_ = 'shapeshifter';
      }
      elsif (!s/.*(zombie|skeleton|simulacrum)$/$1/) {
        $_ = '';
      }
    }

    $g->{ckaux} = $g->{kaux} || '';
    for ($g->{ckaux}) {
      s/\{.*?\}//g;
      s/\(.*?\)//g;
      s/[+-]\d+,?\s*//g;
      s/^an? //g;
      s/(?:elven|orcish|dwarven) //g;
      s/^Hit by (.*) thrown .*$/$1/;
      s/^Shot with (.*) by .*$/$1/;
      s/\b(?:un)?cursed //;
      s/\s+$//;
      s/  / /g;
    }

    $g->{rend} = $g->{end};
  }

  $g->{crace} = $g->{race};
  for ($g->{crace}) {
    s/.*(Draconian)$/$1/;
  }

  # Milestones will have start time.
  $g->{rstart} = $g->{start};
  if ($milestone) {
    $g->{rtime} = $g->{time};
  }

  for ($g->{start}, $g->{end}, $g->{time}) {
    if ($_) {
      s/^(\d{4})(\d{2})/$1 . sprintf("%02d", $2 + 1)/e;
      s/[SD]$//;
    }
  }

  if ($milestone) {
    milestone_mangle($g);
  }
  else {
    my $src = $g->{src};
    # Fixup src for interesting_game.
    $g->{src} = "http://" . Henzell::ServerConfig::source_hostname($src) . "/";
    $g->{splat} = '';
    $g->{src} = $src;
  }
  $g->{game_key} = "$$g{name}:$$g{src}:$$g{rstart}";

  $g
}

sub field_integer_val {
  my ($val) = @_;
  $val || 0
}

sub field_date_val {
  my $val = shift;
  $val =~ s/^(?<=\d{4})(\d{2})/$1 + 1/e;
  $val
}

my %FIELD_VALUE_PARSERS = ('I' => \&field_integer_val,
                           'D' => \&field_date_val);

sub field_val {
  my ($key, $g) = @_;
  my ($type) = $key =~ /([A-Z])$/;
  $key =~ s/[A-Z]$//;

  my $val = $g->{$key} || '';
  if ($type) {
    my $value_parser = $FIELD_VALUE_PARSERS{$type};
    $val = $value_parser->($val, $key, $type, $g) if $value_parser;
  }
  $val
}

sub milestone_mangle {
  my ($g) = shift;

  $g->{verb} = $MILESTONE_VERB{$g->{verb}} || $g->{verb};
  my ($verb, $noun) = @$g{qw/verb noun/};
  if ($verb eq 'uniq') {
    my ($action, $unique) = $noun =~ /^(\w+) (.*?)\.?$/;
    $verb = 'uniq.ban' if $action eq 'banished';
    $verb = 'uniq.pac' if $action eq 'pacified';
    $verb = 'uniq.ens' if $action eq 'enslaved';
    $noun = $unique;
  }
  elsif ($verb eq 'ghost') {
    my ($action, $ghost) = $noun =~ /(\w+) the ghost of (\S+)/;
    $verb = 'ghost.ban' if $action eq 'banished';
    $verb = 'ghost.pac' if $action eq 'pacified';
    $noun = $ghost;
  }
  elsif ($verb eq 'abyss.enter') {
    my ($cause) = $noun =~ /.*\((.*?)\)$/;
    $noun = $cause ? $cause : '?';
  }
  elsif ($verb eq 'br.enter' || $verb eq 'br.end' || $verb eq 'br.mid') {
    $noun = $g->{place};
    $noun =~ s/:.*//;
  }
  elsif ($verb eq 'br.exit') {
    $noun = $g->{oplace};
    $noun =~ s/:.*//;
  }
  elsif ($verb eq 'rune') {
    my ($rune) = $noun =~ /found an? (\S+)/;
    $noun = $rune if $rune;
  }
  elsif ($verb eq 'orb') {
    $noun = 'orb';
  }
  elsif ($verb eq 'god.mollify') {
    ($noun) = $noun =~ /^(?:partially )?mollified (.*)[.]$/;
  }
  elsif ($verb eq 'god.renounce') {
    ($noun) = $noun =~ /^abandoned (.*)[.]$/;
  }
  elsif ($verb eq 'god.worship') {
    ($noun) = $noun =~ /^became a worshipper of (.*)[.]$/;
  }
  elsif ($verb eq 'god.maxpiety') {
    ($noun) = $noun =~ /^became the Champion of (.*)[.]$/;
  }
  elsif ($verb eq 'monstrous') {
    $noun = 'demonspawn';
  }
  elsif ($verb eq 'shaft') {
    ($noun) = $noun =~ /fell down a shaft to (.*)[.]$/;
  }
  $g->{verb} = $verb;
  $g->{noun} = $noun || $$g{noun};
}

sub record_is_alpha_version {
  my ($lf, $g) = @_;
  # For older game versions, we already know whether it is alpha by knowing
  # which file the record is in.
  if ($$g{v} =~ /^0\.([0-9]+)/ && $1 < 9) {
    return 'y' if $$lf{alpha};
  }

  # Game version that mentions -rc, -a, or -b is automatically alpha.
  my $v = $$g{v};
  return 'y' if $v =~ /-(?:rc|a|b)/i;

  return '';
}

sub milestone_insert_st($) {
  my $m = shift;
  my $game_type = game_type($m);
  ($game_type? $INSERT_STATEMENTS{$game_type . "_milestone"}
   : $milestone_insert_st)
}

sub logfile_insert_st($) {
  my $g = shift;
  my $game_type = game_type($g);
  ($game_type? $INSERT_STATEMENTS{$game_type} : $insert_st)
}

sub broken_record {
  my $r = shift;
  !$r->{v} || !$r->{start}
}

sub add_milestone {
  my ($lf, $offset, $line) = @_;
  chomp $line;
  my $m = logfield_hash($line);

  return if broken_record($m);
  $m->{file} = $lf->{file};
  $m->{offset} = $offset;
  $m->{src} = $lf->{server};
  $m->{alpha} = record_is_alpha_version($lf, $m);
  $m->{verb} = $m->{type};
  return if $$m{type} eq 'orb' && game_is_zotdef($m);
  $m->{milestone} ||= '?';
  $m->{noun} = $m->{milestone};
  $m = fixup_logfields($m);

  my $game_type = $$m{game_type};
  my $st = milestone_insert_st($m);
  my @bindvals = map(field_val($_, $m), @MILE_INSERTFIELDS_DECORATED);
  execute_st($st, @bindvals) or
    die "Can't insert record for $line: $!\n";
}

sub add_logline {
  my ($lf, $offset, $line) = @_;
  chomp $line;
  my $fields = logfield_hash($line);
  return if broken_record($fields);
  $fields->{src} = $lf->{server};
  $fields->{alpha} = record_is_alpha_version($lf, $fields);
  $fields = fixup_logfields($fields);
  my $st = logfile_insert_st($fields);
  my @bindvalues = ($lf->{file}, $lf->{server}, $offset,
                    map(field_val($_, $fields), @LOGFIELDS_DECORATED),
                    field_val('rstart', $fields),
                    field_val('rend', $fields));

  #my @binds = map("$INSERTFIELDS[$_]=$bindvalues[$_]", 0..$#bindvalues);
  #print "Bindvalues are ", join(",", @binds), "\n";
  execute_st($st, @bindvalues) or
    die "Can't insert record for $line: $!\n";
}

sub xlog_escape {
  my $str = shift;
  $str =~ s/:/::/g;
  $str
}

sub xlog_str {
  my $g = shift;
  join(":", map("$_=" . xlog_escape($g->{$_}), keys %$g))
}

sub update_game {
  my $g = shift;
  my @bindvals = (map(field_val($_, $g), @LOGFIELDS_DECORATED), $g->{id});
  print "Updating game: ", pretty_print($g), "\n";
  execute_st($update_st, @bindvals) or
    die "Can't update record for game: " . pretty_print($g) . "\n";
}

sub game_from_row {
  my $row = shift;
  my %g;
  for my $i (0 .. $#SELECTFIELDS) {
    $g{$SELECTFIELDS[$i]} = $row->[$i];
  }
  \%g
}

sub games_differ {
  my ($a, $b) = @_;
  scalar(
         grep(($a->{$_} || '') ne ($b->{$_} || ''),
              @LOGFIELDS) )
}

1;
